//! Native single-writer config publication, expiring staging and exact revision RPC.

use super::{domain::*, environment_names, identity::SourceFingerprint, resolve};
use crate::{
    configuration::{
        RefreshGeneration,
        read::{ConfigurationPath, ConfigurationTimeout},
    },
    domain::{ByteLimit, ConfigRevision, SessionId},
    error::CoreError,
    ipc::protocol::Fault,
    providers::ProviderCatalog,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::Instant;
use zeroize::Zeroizing;

#[derive(Clone, Deserialize, Eq, PartialEq, serde::Serialize)]
#[serde(try_from = "String", into = "String")]
struct CaptureId(uuid::Uuid);
impl TryFrom<String> for CaptureId {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        uuid::Uuid::parse_str(value.strip_prefix("config_").ok_or(CoreError::StaleOwner)?)
            .map(Self)
            .map_err(|_| CoreError::StaleOwner)
    }
}
impl From<CaptureId> for String {
    fn from(id: CaptureId) -> Self {
        format!("config_{}", id.0)
    }
}
#[derive(Deserialize)]
#[serde(try_from = "String")]
struct SourceDigest(String);
impl TryFrom<String> for SourceDigest {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() != 64
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(CoreError::InvalidValue {
                field: "configuration_digest",
            });
        }
        Ok(Self(value))
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Prepare {
    generation: RefreshGeneration,
    path: ConfigurationPath,
    digest: Option<SourceDigest>,
    document: Option<ConfigurationDocument>,
    registry: RegistrySnapshot,
    #[serde(default)]
    timeout_ms: ConfigurationTimeout,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Commit {
    capture_id: CaptureId,
    context: PolicyContext,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Abort {
    capture_id: CaptureId,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Resolve {
    revision: ConfigRevision,
    target: TargetInput,
    context: Option<PolicyContext>,
    #[serde(default)]
    projection: ResolveProjection,
}
/// Who consumes a resolution: standalone API/catalog paths keep the private
/// key; a native run only needs its secret-free target.
#[derive(Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ResolveProjection {
    #[default]
    Private,
    Target,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Select {
    revision: ConfigRevision,
    provider: crate::providers::ApiProviderId,
    no_model: bool,
    batch: bool,
    cached_models: Vec<crate::configuration::domain::ConfigText>,
}
struct Staged {
    id: CaptureId,
    owner: SessionId,
    generation: RefreshGeneration,
    path: ConfigurationPath,
    digest: Option<SourceDigest>,
    document: ConfigurationDocument,
    expires: Instant,
    absent: bool,
}
struct Published {
    fingerprint: SourceFingerprint,
    document: ConfigurationDocument,
    context: PolicyContext,
    view: Zeroizing<String>,
}

#[derive(Default)]
pub(crate) struct ConfigurationService {
    revision: ConfigRevision,
    latest: Option<RefreshGeneration>,
    requested: Option<RefreshGeneration>,
    staged: Option<Staged>,
    published: Option<Published>,
}

/// Natively resolved run target at one exact published revision.
pub(crate) struct RunTarget {
    pub(crate) provider: String,
    pub(crate) model: Option<String>,
    pub(crate) endpoint: Option<String>,
    profile: resolve::ReadyProfile,
    app_url: Option<crate::configuration::domain::ConfigText>,
    headers: crate::api::HeaderTemplates,
    wire_headers: crate::api::HeaderTemplates,
}
impl RunTarget {
    pub(crate) fn interop_host(&self) -> Result<Option<&str>, CoreError> {
        self.profile.interop_host()
    }
    pub(crate) fn prepare_connection(
        &self,
        source: &str,
        session: &SessionId,
        interop: Option<crate::api::SecretString>,
    ) -> Result<crate::api::ChatConnection, CoreError> {
        crate::api::ChatConnection::capture_run(
            source,
            session,
            self.app_url.as_ref().map(|value| value.as_str()),
            self.profile.native_key(interop)?,
        )
        .map_err(|_| CoreError::InvalidValue {
            field: "NativeConnection",
        })
    }
    pub(crate) fn verify_headers(
        &self,
        supplied: &crate::api::HeaderTemplates,
        wire: &crate::api::HeaderTemplates,
    ) -> Result<(), CoreError> {
        if supplied == &self.headers && wire == &self.wire_headers {
            Ok(())
        } else {
            Err(CoreError::ConfigurationChanged)
        }
    }
    pub(crate) fn verify_credential(&self, supplied: Option<&str>) -> Result<(), CoreError> {
        if self.profile.credential_matches(supplied) {
            Ok(())
        } else {
            Err(CoreError::ConfigurationChanged)
        }
    }
}

/// How a native refresh request proceeds after admission.
pub(crate) enum RefreshStart {
    /// Read the native-ordered candidates for this generation on a worker.
    Read(RefreshGeneration),
    /// Stage built-in defaults now; no file is probed.
    Defaults(RefreshGeneration),
    /// A publication or a real refresh already owns the configuration.
    Observed,
}
impl ConfigurationService {
    /// Resolve the run target from the published document, its committed
    /// context and the conversation's native selection, never editor URLs.
    pub(crate) fn run_target(
        &self,
        revision: ConfigRevision,
        provider: Option<&crate::providers::ApiProviderId>,
        model: Option<&str>,
        catalog: &ProviderCatalog,
    ) -> Result<RunTarget, CoreError> {
        if !self.is_revision(revision) {
            return Err(CoreError::ConfigurationChanged);
        }
        let published = self.published.as_ref().ok_or(CoreError::Unavailable)?;
        let selection = SelectionInput {
            provider: provider.cloned(),
            model: model
                .map(|model| crate::configuration::domain::ConfigText::try_from(model.to_owned()))
                .transpose()
                .map_err(|_| CoreError::InvalidValue {
                    field: "selection_model",
                })?,
        };
        let target = resolve::target(
            &published.document,
            &published.context,
            TargetInput {
                provider: None,
                model: None,
                selection: Some(selection),
            },
            catalog,
        )?;
        let (provider, model, endpoint) = target.identity();
        Ok(RunTarget {
            provider: provider.as_str().to_owned(),
            model: model.filter(|model| !model.is_empty()).map(str::to_owned),
            endpoint: endpoint.map(str::to_owned),
            headers: published
                .context
                .registry
                .get(provider)
                .map(|entry| entry.headers.clone())
                .unwrap_or_default(),
            wire_headers: match published.context.registry.get(provider) {
                Some(entry) => entry.wire_headers.clone(),
                None => serde_json::from_value(
                    catalog
                        .wire_value(provider)
                        .and_then(|wire| wire.get("default-headers"))
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                )
                .map_err(|_| CoreError::Unavailable)?,
            },
            profile: target,
            app_url: published.context.app_url.clone(),
        })
    }
    /// Current committed publication revision.
    pub(crate) fn revision(&self) -> ConfigRevision {
        self.revision
    }
    fn newest(&self) -> RefreshGeneration {
        self.latest
            .max(self.requested)
            .unwrap_or(RefreshGeneration::ZERO)
    }
    /// Order a refresh natively.  A defaults bootstrap never supersedes a
    /// publication, a staged capture or a real refresh still being read.
    pub(crate) fn begin_refresh(&mut self, defaults_only: bool) -> Result<RefreshStart, CoreError> {
        if defaults_only {
            let pending = self
                .requested
                .is_some_and(|requested| Some(requested) > self.latest);
            if self.published.is_some() || self.staged.is_some() || pending {
                return Ok(RefreshStart::Observed);
            }
            return Ok(RefreshStart::Defaults(self.newest().next()?));
        }
        let generation = self.newest().next()?;
        self.requested = Some(generation);
        Ok(RefreshStart::Read(generation))
    }
    /// Release a failed or cancelled read so a later bootstrap is not blocked.
    pub(crate) fn abandon_refresh(&mut self, generation: RefreshGeneration) {
        if self.requested == Some(generation) {
            self.requested = None;
        }
    }
    /// Stage a native read result for its own generation, or report it stale.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn stage_refresh(
        &mut self,
        session: &SessionId,
        generation: RefreshGeneration,
        output: Value,
        registry: RegistrySnapshot,
        timeout: ConfigurationTimeout,
        catalog: &ProviderCatalog,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, CoreError> {
        self.sweep(now);
        if self
            .requested
            .is_some_and(|requested| requested > generation)
        {
            return Err(CoreError::StaleOwner);
        }
        let status = output.get("status").and_then(Value::as_str);
        let path: ConfigurationPath = output
            .get("path")
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(|_| CoreError::Limit)?
            .ok_or(CoreError::Limit)?;
        let (digest, document) = match status {
            Some("absent") => (None, None),
            Some("ok") => {
                let digest: SourceDigest = output
                    .get("digest")
                    .cloned()
                    .map(serde_json::from_value)
                    .transpose()
                    .map_err(|_| CoreError::Limit)?
                    .ok_or(CoreError::Limit)?;
                let document: ConfigurationDocument = output
                    .get("config")
                    .cloned()
                    .map(serde_json::from_value)
                    .transpose()
                    .map_err(|_| CoreError::Limit)?
                    .ok_or(CoreError::Limit)?;
                (Some(digest), Some(document))
            }
            Some("invalid") => {
                let reply = json!({"status":"invalid","generation":generation,
                    "path":path.as_path(),"line":output.get("line")});
                check_frame(&reply, frame)?;
                return Ok(reply);
            }
            _ => return Err(CoreError::Limit),
        };
        let mut reply = self.stage(
            session,
            Prepare {
                generation,
                path,
                digest,
                document,
                registry,
                timeout_ms: timeout,
            },
            catalog,
            frame,
            now,
        )?;
        reply
            .as_object_mut()
            .ok_or(CoreError::Limit)?
            .insert("status".into(), json!("prepared"));
        Ok(reply)
    }
    fn stage(
        &mut self,
        session: &SessionId,
        input: Prepare,
        catalog: &ProviderCatalog,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, CoreError> {
        if input.document.is_some() != input.digest.is_some() {
            return Err(CoreError::InvalidValue {
                field: "configuration_capture",
            });
        }
        if self.latest.is_some_and(|latest| input.generation <= latest) {
            return Err(CoreError::StaleOwner);
        }
        let absent = input.document.is_none();
        let document = input.document.unwrap_or_else(ConfigurationDocument::empty);
        let names = environment_names(&document, &input.registry, catalog)?;
        let path = input.path.as_path().to_owned();
        let staged = Staged {
            id: CaptureId(uuid::Uuid::new_v4()),
            owner: session.clone(),
            generation: input.generation,
            path: input.path,
            digest: input.digest,
            document,
            expires: now
                .checked_add(input.timeout_ms.duration())
                .ok_or(CoreError::ArithmeticOverflow)?,
            absent,
        };
        let reply = json!({"capture_id":staged.id,"generation":staged.generation,"revision":self.revision,
            "environment_names":names,"path":path,"absent":absent});
        check_frame(&reply, frame)?;
        self.latest = Some(staged.generation);
        self.staged = Some(staged);
        Ok(reply)
    }
    pub(crate) fn is_revision(&self, revision: ConfigRevision) -> bool {
        self.published.is_some() && self.revision == revision
    }
    pub(crate) fn prepare_catalog(
        &self,
        revision: ConfigRevision,
        provider: crate::providers::ApiProviderId,
        session: &SessionId,
        catalog: &ProviderCatalog,
    ) -> Result<crate::api::HttpRequest, CoreError> {
        if !self.is_revision(revision) {
            return Err(CoreError::StaleOwner);
        }
        let published = self.published.as_ref().ok_or(CoreError::Unavailable)?;
        super::prepare_catalog_request(
            &published.document,
            &published.context,
            provider,
            session,
            catalog,
        )
    }
    pub(crate) fn sweep(&mut self, now: Instant) {
        if self
            .staged
            .as_ref()
            .is_some_and(|staged| now >= staged.expires)
        {
            self.staged = None;
        }
    }
    pub(crate) fn close_session(&mut self, session: &SessionId) {
        if self
            .staged
            .as_ref()
            .is_some_and(|staged| &staged.owner == session)
        {
            self.staged = None;
        }
    }
    pub(crate) fn revoke(&mut self) {
        self.staged = None;
        self.published = None;
    }
    pub(crate) fn published_view(&self) -> Option<Value> {
        let p = self.published.as_ref()?;
        serde_json::from_str(&p.view).ok()
    }
    pub(crate) fn rpc(
        &mut self,
        session: &SessionId,
        method: &str,
        arguments: Value,
        catalog: &ProviderCatalog,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, Fault> {
        self.call(session, method, arguments, catalog, frame, now)
            .map_err(fault)
    }
    fn call(
        &mut self,
        session: &SessionId,
        method: &str,
        arguments: Value,
        catalog: &ProviderCatalog,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, CoreError> {
        self.sweep(now);
        match method {
            "configuration/select" => {
                let input: Select = decode(arguments)?;
                if input.revision != self.revision {
                    return Err(CoreError::StaleOwner);
                }
                if input.cached_models.len() > 4096 {
                    return Err(CoreError::Limit);
                }
                let published = self.published.as_ref().ok_or(CoreError::Unavailable)?;
                let configured = published
                    .document
                    .provider(&input.provider)
                    .and_then(|fields| fields.model.as_ref())
                    .filter(|model| !model.as_str().is_empty());
                let model = if input.no_model {
                    None
                } else {
                    configured.or_else(|| {
                        if input.batch {
                            input.cached_models.first()
                        } else {
                            None
                        }
                    })
                };
                let model = model
                    .map(|model| crate::api::ModelId::try_from(model.as_str().to_owned()))
                    .transpose()
                    .map_err(|_| CoreError::InvalidValue {
                        field: "configuration_model",
                    })?;
                let value =
                    json!({"revision":self.revision,"provider":input.provider,"model":model});
                check_frame(&value, frame)?;
                Ok(value)
            }
            "configuration/prepare" => {
                let input: Prepare = decode(arguments)?;
                self.stage(session, input, catalog, frame, now)
            }
            "configuration/commit" => {
                let input: Commit = decode(arguments)?;
                let staged = self
                    .staged
                    .as_ref()
                    .filter(|staged| staged.id == input.capture_id && &staged.owner == session)
                    .ok_or(CoreError::StaleOwner)?;
                let mut ids = std::collections::BTreeSet::new();
                ids.extend(
                    staged
                        .document
                        .providers
                        .iter()
                        .map(|provider| provider.name.clone()),
                );
                ids.extend(
                    input
                        .context
                        .registry
                        .entries()
                        .iter()
                        .map(|entry| entry.id.clone()),
                );
                ids.extend(catalog.definitions().map(|entry| entry.id().clone()));
                ids.insert(super::default_provider(
                    &staged.document,
                    input.context.selected_provider.as_ref(),
                )?);
                ids.insert(super::default_provider(&staged.document, None)?);
                let default = resolve::profile(
                    &staged.document,
                    &input.context,
                    TargetInput {
                        provider: None,
                        model: None,
                        selection: None,
                    },
                    catalog,
                )?;
                let mut profiles = Vec::new();
                let mut connected = Vec::new();
                for id in ids {
                    let profile = resolve::profile(
                        &staged.document,
                        &input.context,
                        TargetInput {
                            provider: Some(id.clone()),
                            model: None,
                            selection: None,
                        },
                        catalog,
                    )?;
                    if profile.authenticated() {
                        connected.push(id);
                    }
                    profiles.push(profile.into_editor_value());
                }
                let fallback = resolve::profile(
                    &staged.document,
                    &input.context,
                    TargetInput {
                        provider: None,
                        model: None,
                        selection: Some(SelectionInput {
                            provider: None,
                            model: None,
                        }),
                    },
                    catalog,
                )?;
                let names = environment_names(&staged.document, &input.context.registry, catalog)?;
                let mut view = json!({"status":"committed","path":staged.path.as_path(),"digest":staged.digest.as_ref().map(|digest|&digest.0),
                    "absent":staged.absent,"config":staged.document.editor_value(),"default":default.into_editor_value(),"fallback":fallback.into_editor_value(),"profiles":profiles,"connected":connected,"environment_names":names});
                let fingerprint = SourceFingerprint::capture(
                    &staged.document,
                    &input.context,
                    &staged.path,
                    staged.digest.as_ref().map(|digest| digest.0.as_str()),
                )?;
                let same = self
                    .published
                    .as_ref()
                    .is_some_and(|published| published.fingerprint == fingerprint);
                let revision = if same {
                    self.revision
                } else {
                    self.revision.next()?
                };
                let object = view.as_object_mut().ok_or(CoreError::Limit)?;
                object.insert("revision".into(), json!(revision));
                object.insert("generation".into(), json!(staged.generation));
                check_frame(&view, frame)?;
                let encoded = Zeroizing::new(view.to_string());
                let staged = self.staged.take().ok_or(CoreError::StaleOwner)?;
                self.published = Some(Published {
                    fingerprint,
                    document: staged.document,
                    context: input.context,
                    view: encoded,
                });
                self.revision = revision;
                Ok(view)
            }
            "configuration/abort" => {
                let input: Abort = decode(arguments)?;
                if self
                    .staged
                    .as_ref()
                    .is_some_and(|staged| staged.id == input.capture_id && &staged.owner == session)
                {
                    self.staged = None;
                }
                Ok(json!({"status":"aborted"}))
            }
            "configuration/snapshot" => {
                let empty: std::collections::BTreeMap<String, Value> = decode(arguments)?;
                if !empty.is_empty() {
                    return Err(CoreError::InvalidValue {
                        field: "configuration_snapshot",
                    });
                }
                let published = self.published.as_ref().ok_or(CoreError::Unavailable)?;
                let view = serde_json::from_str(&published.view).map_err(|_| CoreError::Limit)?;
                check_frame(&view, frame)?;
                Ok(view)
            }
            "configuration/resolve" => {
                let input: Resolve = decode(arguments)?;
                if input.revision != self.revision {
                    return Err(CoreError::StaleOwner);
                }
                let published = self.published.as_ref().ok_or(CoreError::Unavailable)?;
                let resolved = resolve::target(
                    &published.document,
                    input.context.as_ref().unwrap_or(&published.context),
                    input.target,
                    catalog,
                )?;
                let mut value = match input.projection {
                    ResolveProjection::Private => resolved.into_editor_value(),
                    ResolveProjection::Target => resolved.into_target_value(),
                };
                value
                    .as_object_mut()
                    .ok_or(CoreError::Limit)?
                    .insert("revision".into(), json!(self.revision));
                check_frame(&value, frame)?;
                Ok(value)
            }
            _ => Err(CoreError::Unavailable),
        }
    }
}
fn decode<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, CoreError> {
    serde_json::from_value(value).map_err(|_| CoreError::InvalidValue {
        field: "configuration_rpc",
    })
}
fn check_frame(value: &Value, frame: ByteLimit) -> Result<(), CoreError> {
    if Zeroizing::new(value.to_string()).len()
        > frame.as_usize().saturating_sub(512).min(768 * 1024)
    {
        return Err(CoreError::Limit);
    }
    Ok(())
}
pub(crate) fn fault(error: CoreError) -> Fault {
    use crate::constants::protocol::error_codes as codes;
    let (code, status) = match error {
        CoreError::StaleOwner => (codes::STALE_OWNER, "stale_configuration"),
        CoreError::Deadline => (codes::TIMEOUT, "timeout"),
        CoreError::Limit | CoreError::ArithmeticOverflow => {
            (codes::RESOURCE_LIMIT, "resource_limit")
        }
        CoreError::Unavailable => (codes::INVALID_STATE, "configuration_unavailable"),
        _ => (codes::INVALID_PARAMS, "invalid_configuration"),
    };
    Fault {
        code,
        status,
        message: "Native configuration operation rejected",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;

    fn context() -> Value {
        json!({"api_base":"https://fixture.invalid/v1","environment":{},"registry":[]})
    }

    #[test]
    fn defaults_wait_for_a_pending_read_until_it_is_abandoned() -> TestResult {
        let mut service = ConfigurationService::default();
        let RefreshStart::Read(first) = service.begin_refresh(false)? else {
            return Err("expected a read".into());
        };
        assert!(matches!(
            service.begin_refresh(true)?,
            RefreshStart::Observed
        ));
        let RefreshStart::Read(second) = service.begin_refresh(false)? else {
            return Err("expected a read".into());
        };
        assert!(second > first);
        service.abandon_refresh(first);
        assert!(matches!(
            service.begin_refresh(true)?,
            RefreshStart::Observed
        ));
        service.abandon_refresh(second);
        assert!(matches!(
            service.begin_refresh(true)?,
            RefreshStart::Defaults(_)
        ));
        Ok(())
    }
    fn prepare(generation: u64, timeout: u64) -> Value {
        json!({"generation":generation,"path":"/synthetic/config","document":null,"digest":null,"registry":[],"timeout_ms":timeout})
    }
    #[test]
    fn elapsed_ticket_is_drained_without_sleep_and_cannot_commit() -> TestResult {
        let mut service = ConfigurationService::default();
        let catalog = ProviderCatalog::embedded()?;
        let session = SessionId::new();
        let frame = ByteLimit::WIRE_MAX;
        let now = Instant::now();
        let ticket = service.call(
            &session,
            "configuration/prepare",
            prepare(1, 1),
            &catalog,
            frame,
            now,
        )?;
        let later = now
            .checked_add(std::time::Duration::from_millis(2))
            .ok_or("clock")?;
        assert!(
            service
                .call(
                    &session,
                    "configuration/commit",
                    json!({"capture_id":ticket["capture_id"],"context":context()}),
                    &catalog,
                    frame,
                    later
                )
                .is_err()
        );
        assert!(service.staged.is_none());
        assert!(service.published.is_none());
        service.call(
            &session,
            "configuration/prepare",
            prepare(2, 100),
            &catalog,
            frame,
            later,
        )?;
        Ok(())
    }
    #[test]
    fn failed_frame_never_advances_generation_or_publishes_partial_state() -> TestResult {
        let mut service = ConfigurationService::default();
        let catalog = ProviderCatalog::embedded()?;
        let session = SessionId::new();
        let now = Instant::now();
        let tiny = ByteLimit::try_from(512)?;
        assert!(
            service
                .call(
                    &session,
                    "configuration/prepare",
                    prepare(1, 100),
                    &catalog,
                    tiny,
                    now
                )
                .is_err()
        );
        assert!(service.latest.is_none());
        let ticket = service.call(
            &session,
            "configuration/prepare",
            prepare(1, 100),
            &catalog,
            ByteLimit::WIRE_MAX,
            now,
        )?;
        let commit = json!({"capture_id":ticket["capture_id"],"context":context()});
        assert!(
            service
                .call(
                    &session,
                    "configuration/commit",
                    commit.clone(),
                    &catalog,
                    tiny,
                    now
                )
                .is_err()
        );
        assert!(service.published.is_none());
        let view = service.call(
            &session,
            "configuration/commit",
            commit,
            &catalog,
            ByteLimit::WIRE_MAX,
            now,
        )?;
        assert_eq!(view["revision"], 1);
        Ok(())
    }
}
