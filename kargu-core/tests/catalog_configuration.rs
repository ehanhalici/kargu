//! Native configuration selects discovery target, wire and credentials.
use kargu_core::{
    api::execute,
    configuration::{
        ParseInput,
        policy::{ConfigurationDocument, PolicyContext, prepare_catalog_request},
    },
    domain::SessionId,
    providers::{ApiProviderId, ProviderCatalog},
};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::TcpListener,
    time::Duration,
};
use tokio_util::sync::CancellationToken;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn document(source: &str) -> Result<ConfigurationDocument, Box<dyn std::error::Error>> {
    let parsed: ParseInput = serde_json::from_value(json!({"source":source,"generation":0}))?;
    let value = parsed.resolve();
    assert_eq!(value["status"], "ok");
    Ok(serde_json::from_value(value["config"].clone())?)
}
fn context() -> Value {
    json!({"api_base":"https://fallback.invalid/v1","environment":{},"registry":[]})
}

#[tokio::test]
async fn config_and_environment_select_exact_custom_target_and_credential() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let base = format!("http://{}/tenant/v1/?account=a%2Fb", listener.local_addr()?);
    let document = document(&format!(
        "provider='custom'\n[providers.custom]\napi='{base}'\napikey='${{KEY}}'"
    ))?;
    let mut ctx = context();
    ctx["environment"] = json!({"KEY":"synthetic-config-secret"});
    let request = prepare_catalog_request(
        &document,
        &serde_json::from_value(ctx)?,
        ApiProviderId::try_from("custom".to_owned())?,
        &SessionId::new(),
        &ProviderCatalog::embedded()?,
    )?;
    let server = std::thread::spawn(move || -> Result<String, std::io::Error> {
        let (mut socket, _) = listener.accept()?;
        socket.set_read_timeout(Some(Duration::from_secs(3)))?;
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            let mut chunk = [0; 1];
            if socket.read(&mut chunk)? == 0 {
                break;
            }
            bytes.extend_from_slice(&chunk);
        }
        let body = r#"{"data":[{"id":"native-model","pricing":{"prompt":"0.00000001"}}]}"#;
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )?;
        Ok(String::from_utf8_lossy(&bytes).to_string())
    });
    let result = execute(request, |_| async { Ok(()) }, CancellationToken::new()).await?;
    let captured = server.join().map_err(|_| "server panicked")??;
    assert!(
        captured.starts_with("GET /tenant/v1/models?account=a%2Fb HTTP/1.1\r\n"),
        "{captured}"
    );
    assert!(
        captured
            .to_lowercase()
            .contains("authorization: bearer synthetic-config-secret\r\n")
    );
    assert_eq!(result["models"][0]["id"], "native-model");
    assert_eq!(result["models"][0]["pricing"]["prompt"], "0.00000001");
    Ok(())
}

#[tokio::test]
async fn anthropic_discovery_uses_native_wire_auth_and_version_headers() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let base = format!("http://{}/v1", listener.local_addr()?);
    let request = prepare_catalog_request(
        &document(&format!(
            "[providers.anthropic]\napi='{base}'\napikey='synthetic-anthropic'"
        ))?,
        &serde_json::from_value(context())?,
        ApiProviderId::try_from("anthropic".to_owned())?,
        &SessionId::new(),
        &ProviderCatalog::embedded()?,
    )?;
    let server = std::thread::spawn(move || -> Result<String, std::io::Error> {
        let (mut socket, _) = listener.accept()?;
        socket.set_read_timeout(Some(Duration::from_secs(3)))?;
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            let mut chunk = [0; 1];
            if socket.read(&mut chunk)? == 0 {
                break;
            }
            bytes.extend_from_slice(&chunk);
        }
        socket.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"data\":[]}",
        )?;
        Ok(String::from_utf8_lossy(&bytes).to_lowercase())
    });
    execute(request, |_| async { Ok(()) }, CancellationToken::new()).await?;
    let captured = server.join().map_err(|_| "server panicked")??;
    assert!(captured.starts_with("get /v1/models http/1.1\r\n"));
    assert!(captured.contains("x-api-key: synthetic-anthropic\r\n"));
    assert!(captured.contains("anthropic-version: 2023-06-01\r\n"));
    assert!(!captured.contains("authorization:"));
    Ok(())
}

#[test]
fn public_discovery_needs_no_credential_but_private_override_does() -> TestResult {
    let catalog = ProviderCatalog::embedded()?;
    let ctx: PolicyContext = serde_json::from_value(context())?;
    let provider = ApiProviderId::try_from("opencode".to_owned())?;
    let session = SessionId::new();
    prepare_catalog_request(&document("")?, &ctx, provider.clone(), &session, &catalog)?;
    assert!(
        prepare_catalog_request(
            &document("[providers.opencode]\napi='http://localhost:1/v1'")?,
            &ctx,
            provider,
            &session,
            &catalog
        )
        .is_err()
    );
    Ok(())
}

#[test]
fn placeholder_secrets_and_invalid_headers_never_enter_http() -> TestResult {
    let catalog = ProviderCatalog::embedded()?;
    let ctx: PolicyContext = serde_json::from_value(context())?;
    for secret in ["placeholder...", "bad\\r\\nheader"] {
        let source =
            format!("[providers.custom]\napi='http://localhost:1/v1'\napikey=\"{secret}\"");
        assert!(
            prepare_catalog_request(
                &document(&source)?,
                &ctx,
                ApiProviderId::try_from("custom".to_owned())?,
                &SessionId::new(),
                &catalog
            )
            .is_err()
        );
    }
    Ok(())
}
