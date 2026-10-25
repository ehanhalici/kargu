//! Nonblocking application-actor metadata RPC, with bounded owned staging.

mod domain;
use crate::{
    constants::{limits, protocol::methods},
    domain::{ByteLimit, SessionId},
    ipc::protocol::Fault,
    models::{
        metadata::EffortSpecs,
        store::{MetadataRevision, ModelStore, ModelUpdate},
    },
    providers::ApiProviderId,
};
use domain::{ServiceError, UploadId, UploadOffset};
use serde::{Deserialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

struct Staging {
    id: UploadId,
    session: SessionId,
    provider: ApiProviderId,
    specs: EffortSpecs,
    base: MetadataRevision,
    source: String,
    offset: UploadOffset,
    expires: Instant,
}
#[derive(Default)]
pub(crate) struct ModelService {
    store: ModelStore,
    staging: Option<Staging>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Empty {}
fn decode<T: DeserializeOwned>(value: Value) -> Result<T, ServiceError> {
    serde_json::from_value(value).map_err(|_| ServiceError::Invalid)
}
fn page_bytes(frame: ByteLimit) -> usize {
    limits::MODEL_PAGE_BYTES.min(frame.as_usize().saturating_sub(512) / 6)
}
impl ModelService {
    pub(crate) fn close_session(&mut self, session: &SessionId) {
        if self
            .staging
            .as_ref()
            .is_some_and(|upload| &upload.session == session)
        {
            self.staging = None;
        }
    }
    pub(crate) fn revoke(&mut self) {
        self.staging = None;
    }
    pub(crate) fn rpc(
        &mut self,
        session: &SessionId,
        method: &str,
        arguments: Value,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, Fault> {
        self.call(session, method, arguments, frame, now)
            .map_err(Fault::from)
    }
    fn call(
        &mut self,
        session: &SessionId,
        method: &str,
        arguments: Value,
        frame: ByteLimit,
        now: Instant,
    ) -> Result<Value, ServiceError> {
        let expired = self
            .staging
            .as_ref()
            .is_some_and(|upload| now >= upload.expires);
        if expired {
            self.staging = None;
        }
        match method {
            methods::MODEL_BEGIN => {
                let input: domain::Begin = decode(arguments)?;
                if self.staging.is_some() {
                    return Err(ServiceError::Busy);
                }
                if input.revision != self.store.revision() {
                    return Err(ServiceError::Stale);
                }
                let upload = Staging {
                    id: UploadId::new(),
                    session: session.clone(),
                    provider: input.provider,
                    specs: input.effort_specs,
                    base: input.revision,
                    source: String::new(),
                    offset: UploadOffset::default(),
                    expires: now
                        .checked_add(Duration::from_secs(limits::MODEL_UPLOAD_SECONDS))
                        .ok_or(ServiceError::Deadline)?,
                };
                let result = json!({"upload_id":upload.id,"revision":upload.base,"offset":upload.offset,"max_chunk_bytes":page_bytes(frame)});
                self.staging = Some(upload);
                Ok(result)
            }
            methods::MODEL_APPEND => {
                let input: domain::Append = decode(arguments)?;
                let upload = self.upload(session, &input.upload_id, expired)?;
                if input.offset != upload.offset
                    || input.chunk.is_empty()
                    || input.chunk.len() > limits::MODEL_PAGE_BYTES
                {
                    return Err(ServiceError::Invalid);
                }
                let offset = UploadOffset::try_from(
                    upload
                        .offset
                        .get()
                        .checked_add(input.chunk.len())
                        .ok_or(ServiceError::Limit)?,
                )?;
                upload.source.push_str(&input.chunk);
                upload.offset = offset;
                Ok(json!({"upload_id":upload.id,"offset":offset}))
            }
            methods::MODEL_COMMIT => {
                let input: domain::Upload = decode(arguments)?;
                self.upload(session, &input.upload_id, expired)?;
                let upload = self.staging.take().ok_or(ServiceError::Stale)?;
                if upload.base != self.store.revision() {
                    return Err(ServiceError::Stale);
                }
                let update = ModelUpdate::try_from(upload.source.as_str())?;
                let prepared = self.store.prepare(upload.provider, update, upload.specs)?;
                self.store.commit(prepared)?;
                Ok(self.descriptor())
            }
            methods::MODEL_ABORT => {
                let input: domain::Upload = decode(arguments)?;
                self.upload(session, &input.upload_id, expired)?;
                self.staging = None;
                Ok(json!({"status":"aborted"}))
            }
            methods::MODEL_SNAPSHOT => {
                let _: Empty = decode(arguments)?;
                Ok(self.descriptor())
            }
            methods::MODEL_READ => {
                let input: domain::Read = decode(arguments)?;
                if input.revision != self.store.revision() {
                    return Err(ServiceError::Stale);
                }
                let source = self.store.snapshot_json();
                let start = input.offset.get();
                if start > source.len() || !source.is_char_boundary(start) {
                    return Err(ServiceError::Invalid);
                }
                // Worst-case JSON escaping is six bytes per source byte. Leave
                // room for correlation/envelope even at the 1 KiB handshake floor.
                let page = page_bytes(frame);
                let mut end = start.saturating_add(page).min(source.len());
                while end > start && !source.is_char_boundary(end) {
                    end = end.saturating_sub(1);
                }
                let chunk = source.get(start..end).ok_or(ServiceError::Invalid)?;
                Ok(
                    json!({"revision":input.revision,"offset":start,"next_offset":end,"total_bytes":source.len(),"chunk":chunk,"done":end == source.len()}),
                )
            }
            _ => Err(ServiceError::Invalid),
        }
    }
    fn upload(
        &mut self,
        session: &SessionId,
        id: &UploadId,
        expired: bool,
    ) -> Result<&mut Staging, ServiceError> {
        let upload = self.staging.as_mut().ok_or(if expired {
            ServiceError::Deadline
        } else {
            ServiceError::Stale
        })?;
        if &upload.session != session || &upload.id != id {
            return Err(ServiceError::Stale);
        }
        Ok(upload)
    }
    fn descriptor(&self) -> Value {
        json!({"revision":self.store.revision(),"total_bytes":self.store.snapshot_json().len()})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn absolute_upload_deadline_expires_without_publishing_or_blocking_the_next_owner() -> TestResult
    {
        let mut service = ModelService::default();
        let owner = SessionId::new();
        let now = Instant::now();
        let upload = service.rpc(
            &owner,
            methods::MODEL_BEGIN,
            json!({"provider":"a","revision":0}),
            ByteLimit::WIRE_MAX,
            now,
        )?;
        let later = now
            .checked_add(Duration::from_secs(
                limits::MODEL_UPLOAD_SECONDS.saturating_add(1),
            ))
            .ok_or("test clock overflow")?;
        let failure = service
            .rpc(
                &owner,
                methods::MODEL_APPEND,
                json!({"upload_id":upload.get("upload_id"),"offset":0,"chunk":"{}"}),
                ByteLimit::WIRE_MAX,
                later,
            )
            .err()
            .ok_or("expired upload accepted")?;
        assert_eq!(failure.status, "timeout");
        assert_eq!(service.store.revision(), MetadataRevision::default());
        assert!(service.staging.is_none());
        service.rpc(
            &owner,
            methods::MODEL_BEGIN,
            json!({"provider":"a","revision":0}),
            ByteLimit::WIRE_MAX,
            later,
        )?;
        service.revoke();
        assert!(service.staging.is_none());
        Ok(())
    }

    #[test]
    fn upload_byte_limit_and_exact_offset_fail_without_appending_or_publishing() -> TestResult {
        let mut service = ModelService::default();
        let owner = SessionId::new();
        let now = Instant::now();
        let upload = service.rpc(
            &owner,
            methods::MODEL_BEGIN,
            json!({"provider":"a","revision":0}),
            ByteLimit::WIRE_MAX,
            now,
        )?;
        let chunk = " ".repeat(limits::MODEL_PAGE_BYTES);
        for offset in (0..limits::MODEL_CATALOG_BYTES).step_by(limits::MODEL_PAGE_BYTES) {
            service.rpc(
                &owner,
                methods::MODEL_APPEND,
                json!({"upload_id":upload.get("upload_id"),"offset":offset,"chunk":chunk}),
                ByteLimit::WIRE_MAX,
                now,
            )?;
        }
        let failure = service.rpc(&owner, methods::MODEL_APPEND, json!({"upload_id":upload.get("upload_id"),"offset":limits::MODEL_CATALOG_BYTES,"chunk":"x"}), ByteLimit::WIRE_MAX, now).err().ok_or("oversize accepted")?;
        assert_eq!(failure.status, "resource_limit");
        assert_eq!(
            service
                .staging
                .as_ref()
                .ok_or("upload missing")?
                .source
                .len(),
            limits::MODEL_CATALOG_BYTES
        );
        assert_eq!(service.store.revision(), MetadataRevision::default());
        service.rpc(
            &owner,
            methods::MODEL_ABORT,
            json!({"upload_id":upload.get("upload_id")}),
            ByteLimit::WIRE_MAX,
            now,
        )?;
        assert!(service.staging.is_none());
        Ok(())
    }
}
