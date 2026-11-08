//! Single native bounded prompt cache with revision and TTL invalidation.

use super::{
    context::{ToolsPolicy, WorkspaceRootPath},
    instruction::{InstructionRevision, InstructionText, ModeOverlay},
};
use crate::{
    domain::{ConfigRevision, SessionId},
    models::store::MetadataRevision,
};
use std::time::{Duration, Instant};

/// Context revision commitment.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextRevision(String);

impl ContextRevision {
    /// Create new context revision.
    pub fn new(rev: String) -> Self {
        Self(rev)
    }

    /// Access revision as string slice.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Session-bound identity components for prompt caching.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CacheSessionScope {
    session: SessionId,
    root: WorkspaceRootPath,
    mode: ModeOverlay,
}

impl CacheSessionScope {
    /// Construct cache session scope.
    pub fn new(session: SessionId, root: WorkspaceRootPath, mode: ModeOverlay) -> Self {
        Self {
            session,
            root,
            mode,
        }
    }

    /// Session identity.
    pub fn session(&self) -> &SessionId {
        &self.session
    }

    /// Workspace root.
    pub fn root(&self) -> &WorkspaceRootPath {
        &self.root
    }

    /// Active mode.
    pub fn mode(&self) -> ModeOverlay {
        self.mode
    }
}

/// Instruction and context content revision tracking.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContentRevisions {
    instruction: InstructionRevision,
    context: ContextRevision,
}

impl ContentRevisions {
    /// Construct content revisions pair.
    pub fn new(instruction: InstructionRevision, context: ContextRevision) -> Self {
        Self {
            instruction,
            context,
        }
    }

    /// Instruction revision.
    pub fn instruction(&self) -> &InstructionRevision {
        &self.instruction
    }

    /// Context revision.
    pub fn context(&self) -> &ContextRevision {
        &self.context
    }
}

/// Revision tracking components for prompt caching.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CacheRevisions {
    config: ConfigRevision,
    model: MetadataRevision,
    content: ContentRevisions,
}

impl CacheRevisions {
    /// Construct cache revisions set.
    pub fn new(config: ConfigRevision, model: MetadataRevision, content: ContentRevisions) -> Self {
        Self {
            config,
            model,
            content,
        }
    }

    /// Configuration revision.
    pub fn config(&self) -> ConfigRevision {
        self.config
    }

    /// Model metadata revision.
    pub fn model(&self) -> MetadataRevision {
        self.model
    }

    /// Content revisions.
    pub fn content(&self) -> &ContentRevisions {
        &self.content
    }
}

/// Composite prompt cache key.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptCacheKey {
    scope: CacheSessionScope,
    revisions: CacheRevisions,
    tools_policy: ToolsPolicy,
}

impl PromptCacheKey {
    /// Construct composite cache key.
    pub fn new(
        scope: CacheSessionScope,
        revisions: CacheRevisions,
        tools_policy: ToolsPolicy,
    ) -> Self {
        Self {
            scope,
            revisions,
            tools_policy,
        }
    }

    /// Scope components.
    pub fn scope(&self) -> &CacheSessionScope {
        &self.scope
    }

    /// Revisions components.
    pub fn revisions(&self) -> &CacheRevisions {
        &self.revisions
    }

    /// Tools policy.
    pub fn tools_policy(&self) -> ToolsPolicy {
        self.tools_policy
    }
}

/// Newtype for cache entry limit.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CacheEntryLimit(usize);

impl CacheEntryLimit {
    /// Create entry limit.
    pub const fn new(limit: usize) -> Self {
        Self(limit)
    }

    /// Inner limit value.
    pub const fn get(self) -> usize {
        self.0
    }
}

/// Newtype for cache byte limit.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CacheByteLimit(usize);

impl CacheByteLimit {
    /// Create byte limit.
    pub const fn new(limit: usize) -> Self {
        Self(limit)
    }

    /// Inner limit value.
    pub const fn get(self) -> usize {
        self.0
    }
}

/// Bounded capacity and TTL configuration.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PromptCacheLimits {
    max_entries: CacheEntryLimit,
    max_bytes: CacheByteLimit,
    ttl: Duration,
}

impl PromptCacheLimits {
    /// Default production cache limits (32 entries, 1MB, 5s TTL).
    pub const DEFAULT: Self = Self {
        max_entries: CacheEntryLimit::new(32),
        max_bytes: CacheByteLimit::new(1024 * 1024),
        ttl: Duration::from_secs(5),
    };

    /// Custom cache limits.
    pub const fn new(
        max_entries: CacheEntryLimit,
        max_bytes: CacheByteLimit,
        ttl: Duration,
    ) -> Self {
        Self {
            max_entries,
            max_bytes,
            ttl,
        }
    }

    /// Maximum entries allowed.
    pub fn max_entries(&self) -> CacheEntryLimit {
        self.max_entries
    }

    /// Maximum aggregate bytes allowed.
    pub fn max_bytes(&self) -> CacheByteLimit {
        self.max_bytes
    }

    /// Time-to-live duration.
    pub fn ttl(&self) -> Duration {
        self.ttl
    }
}

/// Newtype for cache entry count.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CacheEntryCount(usize);

impl CacheEntryCount {
    /// Create entry count.
    pub const fn new(count: usize) -> Self {
        Self(count)
    }

    /// Inner count value.
    pub const fn get(self) -> usize {
        self.0
    }
}

/// Newtype for cache byte size.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CacheByteSize(usize);

impl CacheByteSize {
    /// Create byte size.
    pub const fn new(size: usize) -> Self {
        Self(size)
    }

    /// Inner byte size.
    pub const fn get(self) -> usize {
        self.0
    }
}

/// Cache insertion pair (key and prompt text).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CacheInsertion {
    key: PromptCacheKey,
    prompt: InstructionText,
}

impl CacheInsertion {
    /// Create new cache insertion item.
    pub fn new(key: PromptCacheKey, prompt: InstructionText) -> Self {
        Self { key, prompt }
    }

    /// Borrow key.
    pub fn key(&self) -> &PromptCacheKey {
        &self.key
    }

    /// Borrow prompt.
    pub fn prompt(&self) -> &InstructionText {
        &self.prompt
    }
}

#[derive(Clone, Debug)]
struct CacheEntry {
    key: PromptCacheKey,
    prompt: InstructionText,
    created_at: Instant,
    size_bytes: usize,
}

/// Single native bounded prompt cache.
#[derive(Clone, Debug)]
pub struct NativePromptCache {
    entries: Vec<CacheEntry>,
    limits: PromptCacheLimits,
    total_bytes: usize,
}

impl NativePromptCache {
    /// Create empty prompt cache with limits.
    pub fn new(limits: PromptCacheLimits) -> Self {
        Self {
            entries: Vec::new(),
            limits,
            total_bytes: 0,
        }
    }

    /// Query cached prompt at `now`, returning None if missing or expired.
    pub fn get(&mut self, key: &PromptCacheKey, now: Instant) -> Option<InstructionText> {
        self.evict_expired(now);
        let pos = self.entries.iter().position(|e| &e.key == key)?;
        let entry = self.entries.get(pos)?;
        Some(entry.prompt.clone())
    }

    /// Insert or update prompt entry at `now`, evicting expired or excess entries.
    pub fn insert(&mut self, item: CacheInsertion, now: Instant) {
        self.evict_expired(now);
        let item_bytes = item.prompt().len();
        self.evict_for_capacity(item_bytes);
        self.total_bytes = self.total_bytes.saturating_add(item_bytes);
        self.entries.push(CacheEntry {
            key: item.key,
            prompt: item.prompt,
            created_at: now,
            size_bytes: item_bytes,
        });
    }

    fn evict_for_capacity(&mut self, needed_bytes: usize) {
        while !self.entries.is_empty()
            && (self.entries.len() >= self.limits.max_entries().get()
                || self.total_bytes.saturating_add(needed_bytes) > self.limits.max_bytes().get())
        {
            if let Some(removed) = self.entries.first().cloned() {
                self.entries.remove(0);
                self.total_bytes = self.total_bytes.saturating_sub(removed.size_bytes);
            }
        }
    }

    fn evict_expired(&mut self, now: Instant) {
        let ttl = self.limits.ttl();
        let mut expired_bytes: usize = 0;
        self.entries.retain(|e| {
            let elapsed = now.saturating_duration_since(e.created_at);
            if elapsed > ttl {
                expired_bytes = expired_bytes.saturating_add(e.size_bytes);
                false
            } else {
                true
            }
        });
        self.total_bytes = self.total_bytes.saturating_sub(expired_bytes);
    }

    /// Invalidate all entries for a specific session.
    pub fn invalidate_session(&mut self, session: &SessionId) {
        let mut removed_bytes: usize = 0;
        self.entries.retain(|e| {
            if e.key.scope().session() == session {
                removed_bytes = removed_bytes.saturating_add(e.size_bytes);
                false
            } else {
                true
            }
        });
        self.total_bytes = self.total_bytes.saturating_sub(removed_bytes);
    }

    /// Invalidate all entries for a workspace root.
    pub fn invalidate_workspace(&mut self, root: &WorkspaceRootPath) {
        let mut removed_bytes: usize = 0;
        self.entries.retain(|e| {
            if e.key.scope().root() == root {
                removed_bytes = removed_bytes.saturating_add(e.size_bytes);
                false
            } else {
                true
            }
        });
        self.total_bytes = self.total_bytes.saturating_sub(removed_bytes);
    }

    /// Clear all cached entries.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.total_bytes = 0;
    }

    /// Total entries currently retained.
    pub fn entry_count(&self) -> CacheEntryCount {
        CacheEntryCount::new(self.entries.len())
    }

    /// Total bytes currently occupied.
    pub fn byte_size(&self) -> CacheByteSize {
        CacheByteSize::new(self.total_bytes)
    }
}
