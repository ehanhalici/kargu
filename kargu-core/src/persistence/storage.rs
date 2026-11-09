//! Imperative session storage engine, per-session stable locking, and snapshot IO.
//!
//! Enforces:
//! - Stable per-session locks held on independent lock files in `.locks/`, completely
//!   isolated from journal or snapshot inode unlinks/recreation.
//! - Save, load, recovery, import, and delete all share the same session lock.
//! - Strict filesystem permissions (0o700 dirs, 0o600 files, EUID match, symlink rejection).
//! - Foreign owner rejection before taking locks or reading/writing files.
//! - Journal-only session awareness during import collision detection.

use crate::{
    constants::limits,
    error::CoreError,
    persistence::{
        domain::{
            CleanedTempCount, ListTruncation, PersistenceError, PrunedByteCount,
            PrunedSessionCount, RetainedSessionCount, RetentionReport, SessionListResult,
            SessionRecord, SessionRetentionPolicy, SessionSummary, StorageRoot, StorageSessionId,
        },
        layout::StorageLocation,
        migration::SessionCandidate,
        recovery::{TailTruncation, recover_session_view},
    },
};
use nix::{
    fcntl::{Flock, FlockArg, OFlag, open},
    sys::stat::Mode,
};
use std::{
    collections::BTreeSet,
    fs::File,
    io::Write,
    os::unix::fs::{DirBuilderExt, MetadataExt},
    path::{Path, PathBuf},
};

fn os_err(error: nix::errno::Errno) -> CoreError {
    std::io::Error::from(error).into()
}

/// An exclusive, inode-independent per-session lock guard.
pub struct SessionLock {
    _held: Flock<File>,
    id: StorageSessionId,
}

impl SessionLock {
    /// Return the session identity protected by this lock.
    pub fn id(&self) -> &StorageSessionId {
        &self.id
    }
}

/// Imperative session storage provider.
pub struct SessionStorage {
    root: StorageRoot,
    locks_dir: PathBuf,
}

impl SessionStorage {
    /// Initialize storage rooted at `root`, creating required directories with 0o700 permissions.
    pub fn new(root: StorageRoot) -> Result<Self, CoreError> {
        validate_or_create_dir(root.path())?;
        let locks_dir = root.path().join(".locks");
        validate_or_create_dir(&locks_dir)?;
        Ok(Self { root, locks_dir })
    }

    /// Borrow the storage root.
    pub fn root(&self) -> &StorageRoot {
        &self.root
    }

    /// Acquire an exclusive, non-blocking stable session lock.
    pub fn lock(&self, id: &StorageSessionId) -> Result<SessionLock, CoreError> {
        validate_dir(&self.locks_dir)?;
        let lock_path = self.locks_dir.join(format!("{}.lock", id.as_str()));
        let file = open_lock_file(&lock_path)?;
        let held = Flock::lock(file, FlockArg::LockExclusiveNonblock).map_err(|(_, err)| {
            if err == nix::errno::Errno::EWOULDBLOCK {
                CoreError::Busy
            } else {
                os_err(err)
            }
        })?;
        Ok(SessionLock {
            _held: held,
            id: id.clone(),
        })
    }

    /// Check if a journal file exists for this session.
    fn has_journal(&self, id: &StorageSessionId) -> bool {
        let path = self.root.path().join(format!("{}.journal", id.as_str()));
        path.exists()
    }

    /// Save a snapshot atomically. Requires the session lock.
    pub fn save_snapshot(
        &self,
        lock: &SessionLock,
        record: &SessionRecord,
    ) -> Result<(), CoreError> {
        if lock.id() != record.id() {
            return Err(CoreError::Rejected);
        }
        validate_dir(self.root.path())?;
        let json_str = serde_json::to_string(record)
            .map_err(|_| CoreError::from(PersistenceError::Validation("serialization failed")))?;
        let final_path = self.root.session_file(record.id())?;
        write_atomic_snapshot(self.root.path(), &final_path, json_str.as_bytes())
    }

    /// Load and recover session state from journal and snapshot. Requires session lock.
    pub fn load_session(&self, lock: &SessionLock) -> Result<Option<SessionRecord>, CoreError> {
        recover_session_view(self, lock.id(), TailTruncation::AllowTruncate)
    }

    /// Load a snapshot. Requires the session lock.
    pub fn load_snapshot(&self, lock: &SessionLock) -> Result<Option<SessionRecord>, CoreError> {
        self.load_session(lock)
    }

    /// List metadata summaries for all stored sessions up to bounded limits.
    pub fn list_sessions(&self) -> Result<SessionListResult, CoreError> {
        validate_dir(self.root.path())?;
        let ids = collect_session_ids(self.root.path())?;
        let mut infos = collect_session_file_infos(self.root.path(), &ids);
        // Newest files are read first so a truncated listing keeps the recent ones.
        infos.sort_by(|a, b| {
            b.mtime_secs
                .cmp(&a.mtime_secs)
                .then_with(|| b.id.cmp(&a.id))
        });
        let mut summaries = Vec::new();
        let mut truncation = ListTruncation::Complete;
        let mut total_bytes: usize = 0;
        for id in infos.into_iter().map(|info| info.id) {
            if summaries.len() >= limits::SESSION_LIST_MAX_FILES
                || total_bytes >= limits::SESSION_LIST_MAX_TOTAL_BYTES
            {
                truncation = ListTruncation::Truncated;
                break;
            }
            if let Ok(Some(rec)) = recover_session_view(self, &id, TailTruncation::ReadOnly) {
                total_bytes = total_bytes.saturating_add(rec.messages().len().saturating_mul(128));
                summaries.push(SessionSummary::from_record(&rec));
            }
        }
        summaries.sort_by(newest_summary_first);
        Ok(SessionListResult::new(summaries, truncation))
    }

    /// Delete session snapshot and journal files. The session lock remains held.
    pub fn delete_session(&self, lock: &SessionLock) -> Result<(), CoreError> {
        validate_dir(self.root.path())?;
        let snapshot = self.root.session_file(lock.id())?;
        if snapshot.exists() {
            std::fs::remove_file(&snapshot)?;
        }
        let journal = self
            .root
            .path()
            .join(format!("{}.journal", lock.id().as_str()));
        if journal.exists() {
            std::fs::remove_file(&journal)?;
        }
        Ok(())
    }

    /// Import a session candidate. Fails with Collision if snapshot or journal exists.
    pub fn import_candidate(
        &self,
        lock: &SessionLock,
        candidate: &SessionCandidate,
    ) -> Result<(), CoreError> {
        if lock.id() != candidate.id() {
            return Err(CoreError::Rejected);
        }
        let snapshot_exists = self.root.session_file(candidate.id())?.exists();
        let journal_exists = self.has_journal(candidate.id());
        if snapshot_exists || journal_exists {
            return Err(CoreError::Persistence(PersistenceError::Collision));
        }
        self.save_snapshot(lock, candidate.record())
    }

    /// Clean orphaned temporary files left by interrupted atomic snapshot writes.
    pub fn cleanup_temp_files(&self) -> Result<CleanedTempCount, CoreError> {
        validate_dir(self.root.path())?;
        let mut cleaned = 0usize;
        for entry in std::fs::read_dir(self.root.path())? {
            let Ok(entry) = entry else {
                continue;
            };
            if is_orphan_temp_file(&entry) && std::fs::remove_file(entry.path()).is_ok() {
                cleaned = cleaned.saturating_add(1);
            }
        }
        Ok(CleanedTempCount::from_usize(cleaned))
    }

    /// Prune sessions matching retention criteria and clean orphaned temp files.
    pub fn prune_sessions(
        &self,
        policy: &SessionRetentionPolicy,
        active_sessions: &BTreeSet<StorageSessionId>,
    ) -> Result<RetentionReport, CoreError> {
        validate_dir(self.root.path())?;
        let cleaned_temp = self.cleanup_temp_files().unwrap_or_default();
        let ids = collect_session_ids(self.root.path())?;
        let infos = collect_session_file_infos(self.root.path(), &ids);
        let prunable = collect_prunable_infos(&infos, active_sessions);
        let mut state = init_prune_state(&infos, policy);
        self.apply_prune_to_items(&prunable, &mut state);
        Ok(RetentionReport::empty()
            .with_pruned(
                PrunedSessionCount::from_usize(state.pruned_count),
                PrunedByteCount::from_u64(state.pruned_bytes),
            )
            .with_retained(
                RetainedSessionCount::from_usize(state.retained_count),
                cleaned_temp,
            ))
    }

    fn apply_prune_to_items(&self, prunable: &[SessionFileInfo], state: &mut PruneState<'_>) {
        for item in prunable {
            if !should_prune_item(item, state) {
                continue;
            }
            let Ok(lock) = self.lock(&item.id) else {
                continue;
            };
            if self.delete_session(&lock).is_ok() {
                state.pruned_count = state.pruned_count.saturating_add(1);
                state.pruned_bytes = state.pruned_bytes.saturating_add(item.bytes);
                state.retained_count = state.retained_count.saturating_sub(1);
                state.retained_bytes = state.retained_bytes.saturating_sub(item.bytes);
            }
        }
    }
}

/// Resolve a storage choice to its directory, refusing links beneath the anchor.
pub fn resolve_location(location: &StorageLocation) -> Result<StorageRoot, CoreError> {
    let project = std::fs::canonicalize(location.project_root())?;
    if !project.is_dir() {
        return Err(CoreError::Rejected);
    }
    let layout = location.layout(&project)?;
    for step in layout.steps() {
        reject_link(step)?;
    }
    let directory = layout.steps().last().ok_or(CoreError::Rejected)?;
    StorageRoot::try_from(directory.clone()).map_err(CoreError::from)
}

fn reject_link(path: &Path) -> Result<(), CoreError> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() || !meta.is_dir() => Err(CoreError::Rejected),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn validate_or_create_dir(path: &Path) -> Result<(), CoreError> {
    if !path.exists() {
        let mut builder = std::fs::DirBuilder::new();
        builder.mode(0o700);
        builder.recursive(true);
        builder.create(path)?;
    } else {
        let _ = std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o700));
    }
    validate_dir(path)
}

fn validate_dir(path: &Path) -> Result<(), CoreError> {
    let meta = std::fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(CoreError::Rejected);
    }
    if meta.uid() != nix::unistd::geteuid().as_raw() {
        return Err(CoreError::StaleOwner);
    }
    if meta.mode() & 0o7777 != 0o700 {
        return Err(CoreError::Rejected);
    }
    Ok(())
}

fn open_lock_file(path: &Path) -> Result<File, CoreError> {
    let raw = open(
        path,
        OFlag::O_RDWR | OFlag::O_CREAT | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW,
        Mode::from_bits_truncate(0o600),
    )
    .map_err(os_err)?;
    let file = File::from(raw);
    let _ = file.set_permissions(std::os::unix::fs::PermissionsExt::from_mode(0o600));
    let meta = file.metadata()?;
    if meta.uid() != nix::unistd::geteuid().as_raw() {
        return Err(CoreError::StaleOwner);
    }
    if meta.mode() & 0o7777 != 0o600 {
        return Err(CoreError::Rejected);
    }
    Ok(file)
}

fn write_atomic_snapshot(dir: &Path, target: &Path, data: &[u8]) -> Result<(), CoreError> {
    if data.len() > limits::SESSION_MAX_FILE_BYTES {
        return Err(CoreError::Limit);
    }
    let temp_name = format!(".tmp.{}", uuid::Uuid::new_v4());
    let temp_path = dir.join(temp_name);
    let raw = open(
        &temp_path,
        OFlag::O_WRONLY | OFlag::O_CREAT | OFlag::O_EXCL | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW,
        Mode::from_bits_truncate(0o600),
    )
    .map_err(os_err)?;
    let mut file = File::from(raw);
    file.write_all(data)?;
    file.sync_all()?;
    std::fs::rename(&temp_path, target)?;
    let dir_file = File::open(dir)?;
    dir_file.sync_all()?;
    Ok(())
}

/// Most recently updated first; identical timestamps order by descending id.
fn newest_summary_first(a: &SessionSummary, b: &SessionSummary) -> std::cmp::Ordering {
    let newer = b.updated_at().map(|t| t.as_str());
    newer
        .cmp(&a.updated_at().map(|t| t.as_str()))
        .then_with(|| b.id().cmp(a.id()))
}

fn collect_session_ids(dir: &Path) -> Result<BTreeSet<StorageSessionId>, CoreError> {
    let mut ids = BTreeSet::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let meta = entry.metadata()?;
        if meta.file_type().is_symlink() || !meta.file_type().is_file() {
            continue;
        }
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if let Some(id) = name_str
            .strip_suffix(".json")
            .or_else(|| name_str.strip_suffix(".journal"))
            .and_then(|id_str| StorageSessionId::try_from(id_str).ok())
        {
            ids.insert(id);
        }
    }
    Ok(ids)
}

#[derive(Clone)]
struct SessionFileInfo {
    id: StorageSessionId,
    bytes: u64,
    mtime_secs: u64,
}

fn is_orphan_temp_file(entry: &std::fs::DirEntry) -> bool {
    let Ok(meta) = entry.metadata() else {
        return false;
    };
    if meta.file_type().is_symlink() || !meta.file_type().is_file() {
        return false;
    }
    if meta.uid() != nix::unistd::geteuid().as_raw() {
        return false;
    }
    let name = entry.file_name();
    let name_str = name.to_string_lossy();
    name_str.starts_with(".tmp.")
}

fn inspect_session_file(root: &Path, id: &StorageSessionId) -> Option<SessionFileInfo> {
    let snap_path = root.join(format!("{}.json", id.as_str()));
    let jour_path = root.join(format!("{}.journal", id.as_str()));
    let snap_meta = std::fs::symlink_metadata(&snap_path).ok();
    let jour_meta = std::fs::symlink_metadata(&jour_path).ok();
    if snap_meta.is_none() && jour_meta.is_none() {
        return None;
    }
    let bytes = snap_meta
        .as_ref()
        .map_or(0, |m| m.len())
        .saturating_add(jour_meta.as_ref().map_or(0, |m| m.len()));
    let snap_mtime = snap_meta
        .and_then(|m| m.modified().ok())
        .and_then(duration_since_epoch);
    let jour_mtime = jour_meta
        .and_then(|m| m.modified().ok())
        .and_then(duration_since_epoch);
    let mtime_secs = snap_mtime.unwrap_or(0).max(jour_mtime.unwrap_or(0));
    Some(SessionFileInfo {
        id: id.clone(),
        bytes,
        mtime_secs,
    })
}

fn duration_since_epoch(time: std::time::SystemTime) -> Option<u64> {
    time.duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

fn current_time_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map_or(0, |d| d.as_secs())
}

fn collect_session_file_infos(
    root: &Path,
    ids: &BTreeSet<StorageSessionId>,
) -> Vec<SessionFileInfo> {
    let mut infos = Vec::new();
    for id in ids {
        if let Some(info) = inspect_session_file(root, id) {
            infos.push(info);
        }
    }
    infos
}

struct PruneState<'a> {
    policy: &'a SessionRetentionPolicy,
    pruned_count: usize,
    pruned_bytes: u64,
    retained_count: usize,
    retained_bytes: u64,
}

fn init_prune_state<'a>(
    infos: &[SessionFileInfo],
    policy: &'a SessionRetentionPolicy,
) -> PruneState<'a> {
    let total_bytes: u64 = infos.iter().map(|i| i.bytes).sum();
    PruneState {
        policy,
        pruned_count: 0,
        pruned_bytes: 0,
        retained_count: infos.len(),
        retained_bytes: total_bytes,
    }
}

fn collect_prunable_infos(
    infos: &[SessionFileInfo],
    active_sessions: &BTreeSet<StorageSessionId>,
) -> Vec<SessionFileInfo> {
    let mut prunable = Vec::new();
    for info in infos {
        if !active_sessions.contains(&info.id) {
            prunable.push(info.clone());
        }
    }
    prunable.sort_by(|a, b| {
        a.mtime_secs
            .cmp(&b.mtime_secs)
            .then_with(|| a.id.cmp(&b.id))
    });
    prunable
}

fn should_prune_item(item: &SessionFileInfo, state: &PruneState<'_>) -> bool {
    let now = current_time_secs();
    let age_exceeded = state
        .policy
        .max_age_secs()
        .is_some_and(|ma| now.saturating_sub(item.mtime_secs) > ma.as_secs());
    let count_exceeded = state
        .policy
        .max_count()
        .is_some_and(|mc| state.retained_count > mc.as_usize());
    let bytes_exceeded = state
        .policy
        .max_bytes()
        .is_some_and(|mb| state.retained_bytes > mb.as_u64());
    age_exceeded || count_exceeded || bytes_exceeded
}
