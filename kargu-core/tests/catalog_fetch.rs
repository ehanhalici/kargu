//! Remote catalog ingress is bounded before JSON parsing and uses one deadline.
use kargu_core::{
    api::catalog::{CatalogFetchError, fetch_remote_models},
    models::metadata::EffortSpecs,
};
use std::{
    io::{Read, Write},
    net::TcpListener,
    time::Duration,
};
type TestResult = Result<(), Box<dyn std::error::Error>>;

#[tokio::test]
async fn oversized_declared_body_is_rejected_before_reading_it() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let url = format!("http://{}", listener.local_addr()?);
    let server = std::thread::spawn(move || -> std::io::Result<()> {
        let (mut socket, _) = listener.accept()?;
        let mut request = [0; 4096];
        let count = socket.read(&mut request)?;
        assert!(count > 0);
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\nConnection: close\r\n\r\n")
    });
    let result = fetch_remote_models(
        &url,
        None,
        &[],
        &EffortSpecs::default(),
        Duration::from_secs(2),
    )
    .await;
    assert!(matches!(result, Err(CatalogFetchError::Limit)));
    server.join().map_err(|_| "server panicked")??;
    Ok(())
}

#[tokio::test]
async fn unsafe_auth_is_rejected_before_opening_a_connection() {
    let result = fetch_remote_models(
        "http://127.0.0.1:1",
        Some("secret\r\ninjected: header"),
        &[],
        &EffortSpecs::default(),
        Duration::from_secs(1),
    )
    .await;
    assert!(matches!(result, Err(CatalogFetchError::Shape)));
}

#[tokio::test]
async fn headers_and_body_share_one_total_deadline() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let url = format!("http://{}", listener.local_addr()?);
    let server = std::thread::spawn(move || -> std::io::Result<()> {
        let (mut socket, _) = listener.accept()?;
        let mut request = [0; 4096];
        let count = socket.read(&mut request)?;
        assert!(count > 0);
        std::thread::sleep(Duration::from_millis(150));
        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n")?;
        std::thread::sleep(Duration::from_millis(150));
        let _ = socket.write_all(b"{\"data\":[]}");
        Ok(())
    });
    let result = fetch_remote_models(
        &url,
        None,
        &[],
        &EffortSpecs::default(),
        Duration::from_millis(230),
    )
    .await;
    assert!(matches!(result, Err(CatalogFetchError::Timeout)));
    server.join().map_err(|_| "server panicked")??;
    Ok(())
}
