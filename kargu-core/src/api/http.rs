use super::{ApiError, HttpRequest, stream::StreamDecoder};
use futures_util::StreamExt;
use serde_json::Value;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;

/// Execute one captured attempt, dropping all network IO before returning.
/// The bounded event port backpressures body reads and cancellation interrupts it.
/// Retries are deliberately not hidden inside an attempt or charged implicitly.
pub async fn execute<F, Fut>(
    request: HttpRequest,
    events: F,
    cancel: CancellationToken,
) -> Result<Value, ApiError>
where
    F: Fn(Value) -> Fut,
    Fut: std::future::Future<Output = Result<(), ApiError>>,
{
    execute_captured(&request, events, cancel).await
}

/// Execute one attempt against an immutable, already parsed request snapshot.
/// A logical owner may retain this snapshot without cloning secret-bearing
/// request policy or retargeting it. Each call still needs its own admission.
pub async fn execute_captured<F, Fut>(
    request: &HttpRequest,
    events: F,
    cancel: CancellationToken,
) -> Result<Value, ApiError>
where
    F: Fn(Value) -> Fut,
    Fut: std::future::Future<Output = Result<(), ApiError>>,
{
    let deadline = request.deadline();
    let run = exchange(request, events, &cancel);
    tokio::pin!(run);
    tokio::select! {
        biased;
        _ = cancel.cancelled() => Err(ApiError::Cancelled),
        result = async {
            if let Some(deadline) = deadline { timeout(deadline, run).await.map_err(|_| ApiError::Deadline)? }
            else { run.await }
        } => result,
    }
}

async fn exchange<F, Fut>(
    request: &HttpRequest,
    events: F,
    _cancel: &CancellationToken,
) -> Result<Value, ApiError>
where
    F: Fn(Value) -> Fut,
    Fut: std::future::Future<Output = Result<(), ApiError>>,
{
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        // Every physical exchange needs its own actor admission and observer
        // barrier. Do not let dependency feature unification enable a second
        // protocol-NACK replay policy beneath that authority.
        .retry(reqwest::retry::never())
        .connect_timeout(request.connect_timeout())
        .referer(false)
        .build()
        .map_err(|_| ApiError::Connection)?;
    let first_byte = request.first_byte_timeout();
    let idle = request.idle_timeout();
    let mut call = client
        .request(request.method.clone(), request.url.as_url().clone())
        .headers(request.headers.clone());
    if let Some(body) = request.body.as_ref() {
        call = call.body(body.as_bytes().to_vec());
    }
    let mut response = timeout(first_byte, call.send())
        .await
        .map_err(|_| ApiError::FirstByteTimeout)?
        .map_err(|_| ApiError::Connection)?;
    let status = response.status();
    if status.is_redirection() {
        return Err(ApiError::Redirect);
    }
    if !status.is_success() {
        let retry_after = response
            .headers()
            .get(reqwest::header::RETRY_AFTER)
            .map(super::resilience::RetryAfter::from);
        if matches!(status.as_u16(), 400 | 413 | 422) && context_overflow(&mut response).await {
            return Err(ApiError::ContextOverflow { status });
        }
        return Err(ApiError::Http {
            status,
            retry_after,
        });
    }
    let explicit_sse = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| {
            value
                .split(';')
                .next()
                .is_some_and(|value| value.trim().eq_ignore_ascii_case("text/event-stream"))
        });
    let catalog = matches!(
        request.response_profile,
        super::domain::ResponseProfile::ModelCatalog
    );
    if catalog && explicit_sse {
        return Err(ApiError::Protocol);
    }
    let mut stream = response.bytes_stream();
    let mut decoder = if explicit_sse {
        Some(StreamDecoder::new(request.limits))
    } else {
        None
    };
    let mut json = Vec::new();
    let mut bytes_read = 0usize;
    let mut sniffed = explicit_sse;
    loop {
        let next = if let Some(idle) = idle {
            timeout(idle, stream.next())
                .await
                .map_err(|_| ApiError::IdleTimeout)?
        } else {
            stream.next().await
        };
        let Some(chunk) = next else {
            break;
        };
        let chunk = chunk.map_err(|_| ApiError::Connection)?;
        bytes_read = bytes_read.checked_add(chunk.len()).ok_or(ApiError::Limit)?;
        if bytes_read > request.limits.raw() {
            return Err(ApiError::Limit);
        }
        if !sniffed && let Some(first) = chunk.iter().find(|byte| !byte.is_ascii_whitespace()) {
            sniffed = true;
            if *first != b'{' && *first != b'[' {
                if catalog {
                    return Err(ApiError::Protocol);
                }
                decoder = Some(StreamDecoder::new(request.limits));
                json.clear();
            }
        }
        if let Some(decoder) = decoder.as_mut() {
            publish(decoder.feed(&chunk)?, &events).await?;
        } else {
            json.extend_from_slice(&chunk);
        }
    }
    if let Some(decoder) = decoder {
        let (deltas, result) = decoder.finish()?;
        publish(deltas, &events).await?;
        request.wire.decode(result)
    } else {
        if catalog {
            let source = std::str::from_utf8(&json).map_err(|_| ApiError::Protocol)?;
            return crate::models::catalog::ModelCatalog::try_from(source)
                .map(crate::models::catalog::ModelCatalog::into_snapshot)
                .map_err(|error| match error {
                    crate::models::catalog::CatalogError::Limit => ApiError::Limit,
                    crate::models::catalog::CatalogError::Shape
                    | crate::models::catalog::CatalogError::Identity => ApiError::Protocol,
                });
        }
        let value: Value = serde_json::from_slice(&json).map_err(|_| ApiError::Protocol)?;
        if value
            .get("error")
            .is_some_and(|error| !error.is_null() && error != false)
        {
            if is_context_overflow(&value) {
                return Err(ApiError::ContextOverflow {
                    status: reqwest::StatusCode::BAD_REQUEST,
                });
            }
            return Err(
                match value
                    .pointer("/error/code")
                    .or_else(|| value.pointer("/error/type"))
                    .and_then(Value::as_str)
                {
                    Some(
                        "context_length_exceeded"
                        | "context_window_exceeded"
                        | "prompt_too_long"
                        | "input_too_long",
                    ) => ApiError::ContextOverflow {
                        status: reqwest::StatusCode::BAD_REQUEST,
                    },
                    Some("rate_limit_exceeded") => ApiError::Http {
                        status: reqwest::StatusCode::TOO_MANY_REQUESTS,
                        retry_after: None,
                    },
                    Some("overloaded" | "overloaded_error" | "internal_server_error") => {
                        ApiError::Http {
                            status: reqwest::StatusCode::SERVICE_UNAVAILABLE,
                            retry_after: None,
                        }
                    }
                    _ => ApiError::Protocol,
                },
            );
        }
        request.wire.decode(value)
    }
}

async fn context_overflow(response: &mut reqwest::Response) -> bool {
    let read = async {
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.ok()? {
            if bytes.len().saturating_add(chunk.len()) > 64 * 1024 {
                return None;
            }
            bytes.extend_from_slice(&chunk);
        }
        let value: Value = serde_json::from_slice(&bytes).ok()?;
        Some(is_context_overflow(&value))
    };
    timeout(std::time::Duration::from_secs(1), read)
        .await
        .ok()
        .flatten()
        .unwrap_or(false)
}

fn is_context_overflow(value: &Value) -> bool {
    if value
        .pointer("/error/code")
        .or_else(|| value.pointer("/error/type"))
        .and_then(Value::as_str)
        .is_some_and(|code| {
            matches!(
                code,
                "context_length_exceeded"
                    | "context_window_exceeded"
                    | "prompt_too_long"
                    | "input_too_long"
            )
        })
    {
        return true;
    }
    // Some Messages/compatible APIs expose input overflow only as an error
    // message. Classify it here without ever forwarding/logging the source text;
    // token-rate/output-token limits are intentionally not context overflow.
    value
        .pointer("/error/message")
        .or_else(|| value.get("error"))
        .and_then(Value::as_str)
        .is_some_and(|message| {
            let message = message.to_lowercase();
            [
                "context_length",
                "context length",
                "maximum context",
                "context window",
                "prompt is too long",
                "input is too long",
                "exceed the context",
                "exceeds the context",
            ]
            .into_iter()
            .any(|pattern| message.contains(pattern))
        })
}
async fn publish<F, Fut>(values: Vec<Value>, events: &F) -> Result<(), ApiError>
where
    F: Fn(Value) -> Fut,
    Fut: std::future::Future<Output = Result<(), ApiError>>,
{
    for value in values {
        events(value).await?;
    }
    Ok(())
}
