//! Unauthenticated public GET; manual redirects and numeric pinning on every hop.
mod policy;
use crate::{error::CoreError, security::file::checkpoint};
use futures_util::StreamExt;
use policy::Target;
use serde::{Deserialize, Serialize};
use std::{
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;

const MAX_CHARACTERS: usize = 128 * 1024;
const MAX_DURATION_MS: u64 = 30_000;
const MAX_ADDRESSES: usize = 64;
const MAX_REDIRECTS: usize = 5;
const MAX_BODY_BYTES: usize = 5_000_000;
const MAX_URL_BYTES: usize = 8192;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Deserialize)]
#[serde(try_from = "FetchDto")]
pub(crate) struct FetchInput {
    target: Target,
    timeout: Duration,
    resolve_timeout: Duration,
    max_chars: CharacterLimit,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FetchDto {
    url: String,
    timeout_ms: u64,
    resolve_timeout_ms: u64,
    max_chars: CharacterLimit,
}
#[derive(Deserialize)]
#[serde(try_from = "usize")]
struct CharacterLimit(usize);
impl TryFrom<usize> for CharacterLimit {
    type Error = CoreError;
    fn try_from(n: usize) -> Result<Self, CoreError> {
        if n > MAX_CHARACTERS {
            return Err(CoreError::Limit);
        }
        Ok(Self(n))
    }
}
impl TryFrom<FetchDto> for FetchInput {
    type Error = CoreError;
    fn try_from(d: FetchDto) -> Result<Self, CoreError> {
        if !(1..=MAX_DURATION_MS).contains(&d.timeout_ms)
            || !(1..=MAX_DURATION_MS).contains(&d.resolve_timeout_ms)
        {
            return Err(CoreError::InvalidValue {
                field: "WebfetchTimeout",
            });
        }
        Ok(Self {
            target: Target::try_from(url::Url::parse(&d.url).map_err(|_| CoreError::Rejected)?)?,
            timeout: Duration::from_millis(d.timeout_ms),
            resolve_timeout: Duration::from_millis(d.resolve_timeout_ms),
            max_chars: d.max_chars,
        })
    }
}
#[derive(Serialize)]
pub(crate) struct FetchResult {
    outcome: FetchOutcome,
    text: String,
    status: u16,
    truncated: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum FetchOutcome {
    Ok,
    HttpError,
}
impl FetchInput {
    pub(crate) fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<FetchResult, CoreError> {
        checkpoint(cancel, deadline)?;
        let deadline = deadline.min(
            Instant::now()
                .checked_add(self.timeout)
                .ok_or(CoreError::ArithmeticOverflow)?,
        );
        tokio::runtime::Handle::current().block_on(fetch(self, cancel, deadline, &Network))
    }
}
trait Transport: Sync {
    fn resolve(
        &self,
        host: String,
        port: u16,
    ) -> impl std::future::Future<Output = Result<Vec<SocketAddr>, CoreError>> + Send;
    fn destination(&self, approved: SocketAddr) -> SocketAddr {
        approved
    }
}
struct Network;
impl Transport for Network {
    async fn resolve(&self, host: String, port: u16) -> Result<Vec<SocketAddr>, CoreError> {
        // The join is retained even on cancellation/deadline. OS resolver calls
        // are cooperative; a stalled NSS call cannot be safely killed in-process.
        tokio::task::spawn_blocking(move || {
            let mut addresses = Vec::new();
            for address in (host.as_str(), port)
                .to_socket_addrs()
                .map_err(|_| CoreError::Unavailable)?
            {
                if addresses.len() >= MAX_ADDRESSES {
                    return Err(CoreError::Limit);
                }
                addresses.push(address);
            }
            Ok(addresses)
        })
        .await
        .map_err(|_| CoreError::CleanupFailed)?
    }
}
async fn resolve<T: Transport>(
    target: &Target,
    network: &T,
    cancel: &CancellationToken,
    deadline: Instant,
    duration: Duration,
) -> Result<SocketAddr, CoreError> {
    if let Ok(ip) = target.host.parse::<IpAddr>() {
        return if policy::public(ip) {
            Ok(SocketAddr::new(ip, target.port))
        } else {
            Err(CoreError::Rejected)
        };
    }
    let stop = deadline.min(
        Instant::now()
            .checked_add(duration)
            .ok_or(CoreError::ArithmeticOverflow)?,
    );
    // Do not drop an owned blocking DNS join: let it drain, then reject late data.
    let addresses = network.resolve(target.host.clone(), target.port).await?;
    checkpoint(cancel, stop)?;
    if addresses.len() > MAX_ADDRESSES {
        return Err(CoreError::Limit);
    }
    addresses
        .into_iter()
        .find(|a| a.port() == target.port && policy::public(a.ip()))
        .ok_or(CoreError::Rejected)
}
async fn fetch<T: Transport>(
    input: FetchInput,
    cancel: &CancellationToken,
    deadline: Instant,
    network: &T,
) -> Result<FetchResult, CoreError> {
    let mut target = input.target;
    for hop in 0..=MAX_REDIRECTS {
        checkpoint(cancel, deadline)?;
        let approved = resolve(&target, network, cancel, deadline, input.resolve_timeout).await?;
        checkpoint(cancel, deadline)?;
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(CONNECT_TIMEOUT)
            .user_agent("kargu")
            .resolve_to_addrs(&target.host, &[network.destination(approved)])
            .build()
            .map_err(|_| CoreError::Unavailable)?;
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(CoreError::Deadline)?;
        let response = tokio::select! {
            _=cancel.cancelled()=>return Err(CoreError::Cancelled),
            result=tokio::time::timeout(remaining,client.get(target.url.clone()).send())=>result.map_err(|_|CoreError::Deadline)?.map_err(|_|CoreError::Unavailable)?,
        };
        let status = response.status();
        if status.is_redirection() {
            if hop == MAX_REDIRECTS {
                return Err(CoreError::Limit);
            }
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or(CoreError::InvalidToolOutput)?;
            if location.len() > MAX_URL_BYTES {
                return Err(CoreError::Limit);
            }
            target = Target::try_from(target.url.join(location).map_err(|_| CoreError::Rejected)?)?;
            continue;
        }
        if !status.is_success() {
            return Ok(FetchResult {
                outcome: FetchOutcome::HttpError,
                text: format!("Webfetch HTTP {}", status.as_u16()),
                status: status.as_u16(),
                truncated: false,
            });
        }
        if response
            .content_length()
            .is_some_and(|n| n > MAX_BODY_BYTES as u64)
        {
            return Err(CoreError::Limit);
        }
        let mut stream = response.bytes_stream();
        let mut bytes = Vec::new();
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .ok_or(CoreError::Deadline)?;
            let next = tokio::select! {
                _=cancel.cancelled()=>return Err(CoreError::Cancelled),
                chunk=tokio::time::timeout(remaining,stream.next())=>chunk.map_err(|_|CoreError::Deadline)?,
            };
            let Some(chunk) = next else { break };
            let chunk = chunk.map_err(|_| CoreError::Unavailable)?;
            if bytes.len().saturating_add(chunk.len()) > MAX_BODY_BYTES {
                return Err(CoreError::Limit);
            }
            bytes.extend_from_slice(&chunk);
        }
        checkpoint(cancel, deadline)?;
        let body = std::str::from_utf8(&bytes).map_err(|_| CoreError::InvalidToolOutput)?;
        if body.contains('\0') {
            return Err(CoreError::InvalidToolOutput);
        }
        let truncated = body.chars().count() > input.max_chars.0;
        let mut text: String = body.chars().take(input.max_chars.0).collect();
        if truncated {
            text.push_str("\n... (body truncated)");
        } else if text.is_empty() {
            text.push_str("(empty body)");
        }
        return Ok(FetchResult {
            outcome: FetchOutcome::Ok,
            text,
            status: status.as_u16(),
            truncated,
        });
    }
    Err(CoreError::Limit)
}

#[cfg(test)]
mod tests;
