//! Native single-writer config publication, expiring staging and exact revision RPC.

use super::{domain::*, environment_names, resolve};
use crate::{
    configuration::{RefreshGeneration, read::ConfigurationPath},
    domain::{ByteLimit, ConfigRevision, SessionId},
    error::CoreError,
    ipc::protocol::Fault,
    providers::ProviderCatalog,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::{Duration, Instant};
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
    document: ConfigurationDocument,
    context: PolicyContext,
    view: Zeroizing<String>,
}

#[derive(Default)]
pub(crate) struct ConfigurationService {
    revision: ConfigRevision,
    latest: Option<RefreshGeneration>,
    staged: Option<Staged>,
    published: Option<Published>,
}
impl ConfigurationService {
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
            "configuration/prepare" => {
                let input: Prepare = decode(arguments)?;
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
                let staged = Staged {
                    id: CaptureId(uuid::Uuid::new_v4()),
                    owner: session.clone(),
                    generation: input.generation,
                    path: input.path,
                    digest: input.digest,
                    document,
                    expires: now
                        .checked_add(Duration::from_secs(5))
                        .ok_or(CoreError::ArithmeticOverflow)?,
                    absent,
                };
                let reply = json!({"capture_id":staged.id,"generation":staged.generation,"revision":self.revision,"environment_names":names});
                check_frame(&reply, frame)?;
                self.latest = Some(staged.generation);
                self.staged = Some(staged);
                Ok(reply)
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
                let default = resolve::profile(
                    &staged.document,
                    &input.context,
                    TargetInput {
                        provider: None,
                        model: None,
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
                        },
                        catalog,
                    )?;
                    if profile.get("authenticated").and_then(Value::as_bool) == Some(true) {
                        connected.push(id);
                    }
                    profiles.push(profile);
                }
                let mut view = json!({"status":"committed","path":staged.path.as_path(),"digest":staged.digest.as_ref().map(|digest|&digest.0),
                    "absent":staged.absent,"config":staged.document.editor_value(),"default":default,"profiles":profiles,"connected":connected});
                let same = self
                    .published
                    .as_ref()
                    .and_then(|published| serde_json::from_str::<Value>(&published.view).ok())
                    .is_some_and(|mut previous| {
                        if let Some(object) = previous.as_object_mut() {
                            object.remove("revision");
                            object.remove("generation");
                        }
                        previous == view
                    });
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
                let mut value = resolve::target(
                    &published.document,
                    &published.context,
                    input.target,
                    catalog,
                )?;
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
fn fault(error: CoreError) -> Fault {
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
