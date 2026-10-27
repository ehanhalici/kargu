use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
struct Fixture {
    address: SocketAddr,
}
impl Transport for Fixture {
    async fn resolve(&self, _host: String, port: u16) -> Result<Vec<SocketAddr>, CoreError> {
        Ok(vec![SocketAddr::new(
            "8.8.8.8".parse().map_err(|_| CoreError::Rejected)?,
            port,
        )])
    }
    fn destination(&self, _approved: SocketAddr) -> SocketAddr {
        self.address
    }
}
#[tokio::test]
async fn controlled_http_pinning_relative_redirect_utf8_and_private_redirect_denial()
-> Result<(), Box<dyn std::error::Error>> {
    for private in [false, true] {
        let server = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = server.local_addr()?;
        let worker = tokio::spawn(async move {
            for hop in 0..if private { 1 } else { 2 } {
                let (mut socket, _) = server.accept().await?;
                let mut bytes = [0; 4096];
                let size = socket.read(&mut bytes).await?;
                let request = std::str::from_utf8(bytes.get(..size).ok_or("request")?)?;
                assert!(request.contains("host: fixture.example"));
                let response = if hop == 0 {
                    format!(
                        "HTTP/1.1 302 Found\r\nLocation: {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        if private {
                            "http://127.0.0.1/private"
                        } else {
                            "/second?tenant=a%2Fb/"
                        }
                    )
                } else {
                    assert!(request.contains("/second?tenant=a%2Fb/"));
                    "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nα😀text"
                        .into()
                };
                socket.write_all(response.as_bytes()).await?;
            }
            Ok::<_, Box<dyn std::error::Error + Send + Sync>>(())
        });
        let input = FetchInput::try_from(FetchDto {
            url: "http://fixture.example/first".into(),
            timeout_ms: 5000,
            resolve_timeout_ms: 1000,
            max_chars: CharacterLimit(2),
        })?;
        let result = fetch(
            input,
            &CancellationToken::new(),
            Instant::now() + Duration::from_secs(5),
            &Fixture { address },
        )
        .await;
        if private {
            assert!(matches!(result, Err(CoreError::Rejected)));
        } else {
            let result = result?;
            assert_eq!(result.text, "α😀\n... (body truncated)");
        }
        worker.await?.map_err(|e| e.to_string())?;
    }
    Ok(())
}
#[tokio::test]
async fn bounded_body_cancel_timeout_and_non_utf8_are_not_successful_prefixes()
-> Result<(), Box<dyn std::error::Error>> {
    for mode in ["oversize", "invalid", "cancel", "timeout"] {
        let server = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = server.local_addr()?;
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let selected = mode.to_owned();
        let worker = tokio::spawn(async move {
            let (mut socket, _) = server.accept().await?;
            let mut bytes = [0; 4096];
            let _ = socket.read(&mut bytes).await?;
            if selected == "cancel" {
                token.cancel();
                return Ok::<_, std::io::Error>(());
            }
            if selected == "timeout" {
                tokio::time::sleep(Duration::from_millis(100)).await;
                return Ok(());
            }
            socket
                .write_all(if selected == "oversize" {
                    b"HTTP/1.1 200 OK\r\nContent-Length: 5000001\r\n\r\n"
                } else {
                    b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n\xff"
                })
                .await
        });
        let input = FetchInput::try_from(FetchDto {
            url: "http://fixture.example/".into(),
            timeout_ms: 5000,
            resolve_timeout_ms: 1000,
            max_chars: CharacterLimit(50),
        })?;
        assert!(
            fetch(
                input,
                &cancel,
                Instant::now() + Duration::from_millis(30),
                &Fixture { address }
            )
            .await
            .is_err()
        );
        worker.await??;
    }
    Ok(())
}

fn input() -> Result<FetchInput, CoreError> {
    FetchInput::try_from(FetchDto {
        url: "http://fixture.example./".into(),
        timeout_ms: 5000,
        resolve_timeout_ms: 1000,
        max_chars: CharacterLimit(200),
    })
}

#[tokio::test]
async fn statuses_informational_headers_empty_body_and_redirect_limit_use_http_semantics()
-> Result<(), Box<dyn std::error::Error>> {
    for (mode, response, connections) in [
        (
            "error",
            "HTTP/1.1 404 Missing\r\nContent-Length: 6\r\n\r\nsecret",
            1,
        ),
        ("empty", "HTTP/1.1 204 No Content\r\n\r\n", 1),
        (
            "hints",
            "HTTP/1.1 103 Early Hints\r\nLink: </hint>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\nHTTP/1.1 is body",
            1,
        ),
        (
            "missing",
            "HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n",
            1,
        ),
        (
            "loop",
            "HTTP/1.1 302 Found\r\nLocation: /again\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            6,
        ),
    ] {
        let server = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = server.local_addr()?;
        let worker = tokio::spawn(async move {
            for _ in 0..connections {
                let (mut socket, _) = server.accept().await?;
                let mut bytes = [0; 4096];
                let count = socket.read(&mut bytes).await?;
                assert!(
                    String::from_utf8_lossy(
                        bytes.get(..count).ok_or(std::io::ErrorKind::InvalidData)?
                    )
                    .contains("host: fixture.example")
                );
                socket.write_all(response.as_bytes()).await?;
            }
            Ok::<_, std::io::Error>(())
        });
        let result = fetch(
            input()?,
            &CancellationToken::new(),
            Instant::now() + Duration::from_secs(5),
            &Fixture { address },
        )
        .await;
        match mode {
            "error" => {
                let result = result?;
                assert!(matches!(result.outcome, FetchOutcome::HttpError));
                assert_eq!(result.text, "Webfetch HTTP 404");
            }
            "empty" => assert_eq!(result?.text, "(empty body)"),
            "hints" => assert_eq!(result?.text, "HTTP/1.1 is body"),
            "missing" => assert!(matches!(result, Err(CoreError::InvalidToolOutput))),
            _ => assert!(matches!(result, Err(CoreError::Limit))),
        }
        worker.await??;
    }
    Ok(())
}

struct DnsFixture {
    answers: Vec<SocketAddr>,
    cancelled: bool,
}
impl Transport for DnsFixture {
    async fn resolve(&self, _host: String, _port: u16) -> Result<Vec<SocketAddr>, CoreError> {
        if self.cancelled {
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
        Ok(self.answers.clone())
    }
}
#[tokio::test]
async fn dns_private_mixed_numeric_deadline_and_cancellation_are_checked_after_owned_join()
-> Result<(), Box<dyn std::error::Error>> {
    let target = input()?.target;
    let deadline = Instant::now() + Duration::from_secs(5);
    let cancel = CancellationToken::new();
    let private = "127.0.0.1:80".parse()?;
    let public = "8.8.8.8:80".parse()?;
    for answers in [
        vec![],
        vec![private],
        vec!["[::ffff:127.0.0.1]:80".parse()?],
        vec!["8.8.8.8:81".parse()?],
    ] {
        assert!(matches!(
            resolve(
                &target,
                &DnsFixture {
                    answers,
                    cancelled: false
                },
                &cancel,
                deadline,
                Duration::from_secs(1)
            )
            .await,
            Err(CoreError::Rejected)
        ));
    }
    assert_eq!(
        resolve(
            &target,
            &DnsFixture {
                answers: vec![private, public],
                cancelled: false
            },
            &cancel,
            deadline,
            Duration::from_secs(1)
        )
        .await?,
        public
    );
    let numeric = Target::try_from(url::Url::parse("http://8.8.8.8/")?)?;
    // Empty resolver answers prove numeric hosts bypass DNS.
    assert_eq!(
        resolve(
            &numeric,
            &DnsFixture {
                answers: vec![],
                cancelled: false
            },
            &cancel,
            deadline,
            Duration::from_secs(1)
        )
        .await?,
        public
    );
    let delayed = DnsFixture {
        answers: vec![public],
        cancelled: true,
    };
    let start = Instant::now();
    assert!(matches!(
        resolve(
            &target,
            &delayed,
            &cancel,
            deadline,
            Duration::from_millis(1)
        )
        .await,
        Err(CoreError::Deadline)
    ));
    assert!(start.elapsed() >= Duration::from_millis(30));
    let token = cancel.clone();
    let worker = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(1)).await;
        token.cancel();
    });
    let start = Instant::now();
    assert!(matches!(
        resolve(&target, &delayed, &cancel, deadline, Duration::from_secs(1)).await,
        Err(CoreError::Cancelled)
    ));
    assert!(start.elapsed() >= Duration::from_millis(30));
    worker.await?;
    Ok(())
}

#[tokio::test]
async fn same_host_redirect_resolves_again_and_rebinding_never_dials_private_address()
-> Result<(), Box<dyn std::error::Error>> {
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct Rebinding {
        address: SocketAddr,
        calls: AtomicUsize,
    }
    impl Transport for Rebinding {
        async fn resolve(&self, _host: String, port: u16) -> Result<Vec<SocketAddr>, CoreError> {
            let ip = if self.calls.fetch_add(1, Ordering::SeqCst) == 0 {
                "8.8.8.8"
            } else {
                "127.0.0.1"
            };
            Ok(vec![SocketAddr::new(
                ip.parse().map_err(|_| CoreError::Rejected)?,
                port,
            )])
        }
        fn destination(&self, approved: SocketAddr) -> SocketAddr {
            assert!(policy::public(approved.ip()));
            self.address
        }
    }
    let server = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let network = Rebinding {
        address: server.local_addr()?,
        calls: AtomicUsize::new(0),
    };
    let worker = tokio::spawn(async move {
        let (mut socket, _) = server.accept().await?;
        let mut bytes = [0; 4096];
        let _ = socket.read(&mut bytes).await?;
        socket
            .write_all(b"HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n")
            .await
    });
    assert!(matches!(
        fetch(
            input()?,
            &CancellationToken::new(),
            Instant::now() + Duration::from_secs(5),
            &network
        )
        .await,
        Err(CoreError::Rejected)
    ));
    assert_eq!(network.calls.load(Ordering::SeqCst), 2);
    worker.await??;
    Ok(())
}
