//! Real local HTTP sockets: no credentials, accounts or remote model calls.

use kargu_core::api::{ApiError, HttpRequest, SecretString, execute, execute_captured};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio_util::sync::CancellationToken;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn server(
    reply: impl FnOnce(TcpStream) + Send + 'static,
) -> Result<(String, std::thread::JoinHandle<()>), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let url = format!("http://{}/chat/completions", listener.local_addr()?);
    let thread = std::thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
            let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
            let mut request = Vec::new();
            let mut byte = [0u8; 1];
            while request.len() < 16384 && !request.ends_with(b"\r\n\r\n") {
                if stream.read_exact(&mut byte).is_err() {
                    return;
                }
                request.extend_from_slice(&byte);
            }
            let headers = String::from_utf8_lossy(&request);
            let length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    if name.eq_ignore_ascii_case("content-length") {
                        value.trim().parse::<usize>().ok()
                    } else {
                        None
                    }
                })
                .unwrap_or(0);
            if length > 16384 {
                return;
            }
            let mut body = vec![0; length];
            if stream.read_exact(&mut body).is_err() {
                return;
            }
            reply(stream);
        }
    });
    Ok((url, thread))
}
fn request(url: &str, stream: bool, timers: Value) -> Result<HttpRequest, serde_json::Error> {
    serde_json::from_value(
        json!({"url":url,"method":"post","headers":{"Authorization":"Bearer synthetic-private-key","Content-Type":"application/json"},
        "body":json!({"model":"local-fixture","messages":[],"stream":stream}).to_string(),"stream":stream,"timeouts":timers}),
    )
}
fn timers() -> Value {
    json!({"connect_ms":500,"first_byte_ms":1000,"idle_ms":1000,"deadline_ms":2000})
}

#[tokio::test]
async fn real_http_body_and_model_discovery_get_work_without_elisp_io() -> TestResult {
    for method in ["get", "post"] {
        let (url, thread) = server(|mut socket| {
            let _ = socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 25\r\nConnection: close\r\n\r\n{\"data\":[{\"id\":\"local\"}]}");
        })?;
        let input = if method == "get" {
            serde_json::from_value(
                json!({"url":url,"method":"get","headers":{},"body":null,"stream":false,"timeouts":timers()}),
            )?
        } else {
            request(&url, false, timers())?
        };
        let result = execute(input, |_| async { Ok(()) }, CancellationToken::new()).await?;
        assert_eq!(result["data"][0]["id"], "local");
        thread.join().map_err(|_| "fixture failed")?;
    }
    Ok(())
}

#[tokio::test]
async fn shared_captured_request_reuses_exact_authority_without_cloning_the_snapshot() -> TestResult
{
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let url = format!("http://{}/frozen", listener.local_addr()?);
    let thread = std::thread::spawn(move || -> std::io::Result<Vec<Vec<u8>>> {
        let mut observed = Vec::new();
        for _ in 0..2 {
            let (mut socket, _) = listener.accept()?;
            socket.set_read_timeout(Some(Duration::from_secs(2)))?;
            let mut request = Vec::new();
            while request.len() < 16384 && !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                socket.read_exact(&mut byte)?;
                request.extend_from_slice(&byte);
            }
            observed.push(request);
            socket.write_all(
                b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}",
            )?;
        }
        Ok(observed)
    });
    let snapshot: HttpRequest = serde_json::from_value(
        json!({"url":url,"method":"get","headers":{
        "Authorization":"Bearer synthetic-frozen-key"},"body":null,"stream":false,"timeouts":timers()}),
    )?;
    let snapshot = Arc::new(snapshot);
    for _ in 0..2 {
        let result = execute_captured(
            snapshot.as_ref(),
            |_| async { Ok(()) },
            CancellationToken::new(),
        )
        .await?;
        assert_eq!(result["ok"], true);
        assert_eq!(Arc::strong_count(&snapshot), 1);
    }
    let observed = thread.join().map_err(|_| "fixture failed")??;
    let first = observed.first().ok_or("missing first request")?;
    assert_eq!(Some(first), observed.get(1));
    let text = String::from_utf8(first.clone())?;
    assert!(text.starts_with("GET /frozen HTTP/1.1\r\n"));
    assert!(
        text.to_ascii_lowercase()
            .contains("authorization: bearer synthetic-frozen-key\r\n")
    );
    Ok(())
}

#[tokio::test]
async fn real_fragmented_sse_produces_ui_events_but_only_completed_calls() -> TestResult {
    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"dünya 🦀\"}}]}\n\ndata: [DONE]\n\n";
    let (url, thread) = server(move |mut socket| {
        let header = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        let _ = socket.write_all(header.as_bytes());
        for byte in body.as_bytes() {
            let _ = socket.write_all(std::slice::from_ref(byte));
        }
    })?;
    let events = Arc::new(Mutex::new(Vec::new()));
    let saved = events.clone();
    let result = execute(
        request(&url, true, timers())?,
        move |value| {
            let saved = saved.clone();
            async move {
                saved.lock().map_err(|_| ApiError::Protocol)?.push(value);
                Ok(())
            }
        },
        CancellationToken::new(),
    )
    .await?;
    assert_eq!(result["choices"][0]["message"]["content"], "dünya 🦀");
    assert_eq!(events.lock().map_err(|_| "events lock")?.len(), 1);
    thread.join().map_err(|_| "fixture failed")?;
    Ok(())
}

#[tokio::test]
async fn redirects_and_http_failures_never_echo_credentials_or_upstream_body() -> TestResult {
    for status in [302, 429, 500] {
        let (url, thread) = server(move |mut socket| {
            let reply = format!(
                "HTTP/1.1 {status} Failure\r\nLocation: http://127.0.0.1:1/credential-target\r\nRetry-After: 7\r\nContent-Length: 21\r\nConnection: close\r\n\r\nsynthetic-private-key"
            );
            let _ = socket.write_all(reply.as_bytes());
        })?;
        let error = execute(
            request(&url, false, timers())?,
            |_| async { Ok(()) },
            CancellationToken::new(),
        )
        .await
        .err()
        .ok_or("unexpected success")?;
        let safe = error.snapshot().to_string();
        assert!(!safe.contains("synthetic-private-key"));
        assert!(!safe.contains("credential-target"));
        if status == 302 {
            assert!(matches!(error, ApiError::Redirect));
        } else {
            assert_eq!(error.snapshot()["retry_after"], "7");
        }
        thread.join().map_err(|_| "fixture failed")?;
    }
    Ok(())
}

#[tokio::test]
async fn oversized_or_invalid_retry_after_is_typed_and_never_echoes_header_text() -> TestResult {
    for (header, exceeded) in [
        ("9".repeat(129), true),
        ("18446744073709551616".to_owned(), true),
        ("synthetic-private-key".to_owned(), false),
    ] {
        let (url, thread) = server(move |mut socket| {
            let reply = format!(
                "HTTP/1.1 503 Failure\r\nRetry-After: {header}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
            let _ = socket.write_all(reply.as_bytes());
        })?;
        let error = execute(
            request(&url, false, timers())?,
            |_| async { Ok(()) },
            CancellationToken::new(),
        )
        .await
        .err()
        .ok_or("expected HTTP failure")?;
        let snapshot = error.snapshot();
        assert_eq!(snapshot["status"], 503);
        assert!(snapshot["retry_after"].is_null());
        assert_eq!(snapshot.get("retry_after_exceeded").is_some(), exceeded);
        assert!(!snapshot.to_string().contains("synthetic-private-key"));
        thread.join().map_err(|_| "fixture failed")?;
    }
    Ok(())
}

#[tokio::test]
async fn independent_timeouts_and_cancellation_drop_socket_before_returning() -> TestResult {
    for case in ["first", "idle", "deadline", "cancel"] {
        let (url, thread) = server(move |mut socket| {
            if case != "first" {
                let _ =
                    socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n");
            }
            std::thread::sleep(Duration::from_millis(150));
        })?;
        let mut timeouts = timers();
        match case {
            "first" => timeouts["first_byte_ms"] = json!(20),
            "idle" => timeouts["idle_ms"] = json!(20),
            "deadline" => timeouts["deadline_ms"] = json!(20),
            _ => {}
        }
        let cancel = CancellationToken::new();
        let trigger = cancel.clone();
        let task = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(20)).await;
            if case == "cancel" {
                trigger.cancel();
            }
        });
        let error = execute(request(&url, true, timeouts)?, |_| async { Ok(()) }, cancel)
            .await
            .err()
            .ok_or("unexpected success")?;
        assert!(match case {
            "first" => matches!(error, ApiError::FirstByteTimeout),
            "idle" => matches!(error, ApiError::IdleTimeout),
            "deadline" => matches!(error, ApiError::Deadline),
            _ => matches!(error, ApiError::Cancelled),
        });
        task.await?;
        thread.join().map_err(|_| "fixture failed")?;
    }
    Ok(())
}

#[test]
fn malformed_authority_headers_limits_and_secret_diagnostics_fail_closed() -> TestResult {
    let secret = SecretString::try_from("synthetic-private-key".to_owned())?;
    assert_eq!(format!("{secret:?}/{secret}"), "***/***");
    for headers in [
        json!({"Host":"other"}),
        json!({"Authorization":"injected\r\nx-secret: x"}),
        json!({"Authorization":"a","authorization":"b"}),
    ] {
        let dto = json!({"url":"http://127.0.0.1:1","method":"get","headers":headers,"body":null,"stream":false,"timeouts":timers()});
        assert!(serde_json::from_value::<HttpRequest>(dto).is_err());
    }
    assert!(request("https://user:secret@example.invalid/v1", false, timers()).is_err());
    assert!(request("https://${HOST}/v1", false, timers()).is_err());
    assert!(
        request(
            "http://localhost",
            true,
            json!({"connect_ms":0,"first_byte_ms":1,"idle_ms":null,"deadline_ms":null})
        )
        .is_err()
    );
    Ok(())
}

#[tokio::test]
async fn typed_upstream_codes_preserve_context_and_retry_without_error_text() -> TestResult {
    for (status, code) in [
        (400, "context_length_exceeded"),
        (200, "context_length_exceeded"),
        (200, "overloaded_error"),
        (400, "invalid_request_error"),
    ] {
        let (url, thread) = server(move |mut socket| {
            let message = if code == "invalid_request_error" {
                "Prompt is too long: synthetic-private-key"
            } else {
                "synthetic-private-key"
            };
            let body = json!({"error":{"type":code,"message":message}}).to_string();
            let header = format!(
                "HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = socket.write_all(header.as_bytes());
        })?;
        let error = execute(
            request(&url, false, timers())?,
            |_| async { Ok(()) },
            CancellationToken::new(),
        )
        .await
        .err()
        .ok_or("unexpected success")?;
        if code == "overloaded_error" {
            assert_eq!(error.snapshot()["status"], 503);
        } else {
            assert!(matches!(error, ApiError::ContextOverflow { .. }));
        }
        assert!(
            !error
                .snapshot()
                .to_string()
                .contains("synthetic-private-key")
        );
        thread.join().map_err(|_| "fixture failed")?;
    }
    Ok(())
}

#[tokio::test]
async fn stalled_ui_backpressure_is_interrupted_by_the_absolute_deadline() -> TestResult {
    let (url, thread) = server(|mut socket| {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\ndata: [DONE]\n\n";
        let header = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = socket.write_all(header.as_bytes());
    })?;
    let mut timeouts = timers();
    timeouts["deadline_ms"] = json!(50);
    let result = execute(
        request(&url, true, timeouts)?,
        |_| std::future::pending::<Result<(), ApiError>>(),
        CancellationToken::new(),
    )
    .await;
    assert!(matches!(result, Err(ApiError::Deadline)));
    thread.join().map_err(|_| "fixture failed")?;
    Ok(())
}
