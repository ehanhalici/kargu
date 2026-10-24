//! Credential-free catalog admission and stable projection contracts.

use kargu_core::providers::{ApiEndpoint, ApiProviderId, EMBEDDED_MANIFEST, ProviderCatalog};
use serde_json::{Value, json};

#[test]
fn embedded_catalog_preserves_supported_and_unsupported_providers()
-> Result<(), Box<dyn std::error::Error>> {
    let catalog = ProviderCatalog::embedded()?;
    let snapshot = catalog.snapshot();
    assert_eq!(snapshot["providers"].as_array().map(Vec::len), Some(162));
    assert_eq!(snapshot["source_date"], "2026-10-24");
    assert_eq!(snapshot["revision"].as_str().map(str::len), Some(64));
    assert_eq!(snapshot, ProviderCatalog::embedded()?.snapshot());
    let openai = ApiProviderId::try_from(" OpenAI ".to_owned())?;
    assert!(
        catalog
            .get(&openai)
            .is_some_and(|provider| provider.family().is_some())
    );
    assert!(
        catalog
            .get(&ApiProviderId::try_from("my-private-service".to_owned())?)
            .is_none()
    );
    assert!(!EMBEDDED_MANIFEST.contains("sk-test-secret"));
    Ok(())
}

#[test]
fn malformed_catalogs_fail_closed() -> Result<(), Box<dyn std::error::Error>> {
    let baseline: Value = serde_json::from_str(EMBEDDED_MANIFEST)?;
    for invalid in [json!(0), json!(2), json!(null)] {
        let mut manifest = baseline.clone();
        manifest["schema_version"] = invalid;
        assert!(ProviderCatalog::try_from(serde_json::to_string(&manifest)?.as_str()).is_err());
    }
    for date in [
        "2026-02-29",
        "0000-01-01",
        "2026-13-01",
        "2026-01-00",
        "2026-01-01-extra",
    ] {
        let mut manifest = baseline.clone();
        manifest["source_date"] = json!(date);
        assert!(ProviderCatalog::try_from(serde_json::to_string(&manifest)?.as_str()).is_err());
    }
    let mut manifest = baseline;
    let duplicate = manifest["providers"]
        .get(0)
        .cloned()
        .ok_or("missing provider")?;
    manifest["providers"]
        .as_array_mut()
        .ok_or("providers not array")?
        .push(duplicate);
    assert!(ProviderCatalog::try_from(serde_json::to_string(&manifest)?.as_str()).is_err());
    assert!(ProviderCatalog::try_from(" ".repeat(512 * 1024 + 1).as_str()).is_err());
    Ok(())
}

#[test]
fn endpoint_is_model_authority_not_a_general_url() {
    for endpoint in [
        "file:///tmp/secret",
        "ftp://example.org",
        "https://user:secret@example.org/v1",
        "https://example.org/v1#secret",
        "https://example.org/\n",
    ] {
        assert!(ApiEndpoint::try_from(endpoint.to_owned()).is_err());
    }
    assert!(ApiEndpoint::try_from("http://127.0.0.1:11434/v1".to_owned()).is_ok());
}
