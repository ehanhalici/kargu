//! Shared protocol names, resource bounds and deadlines. Wire fixtures remain literal.

/// Resource limits used by admission, transport and process supervision.
pub mod limits {
    /// Maximum UTF-8 source for the pure mention parse port.
    pub const MENTION_SOURCE_BYTES: usize = 64 * 1024;
    /// Maximum complete mention result; overflow never returns a prefix.
    pub const MENTION_TARGETS: usize = 256;
    /// Stored protocol messages in one conversation, including reserved tool results.
    pub const HISTORY_MESSAGES: usize = 4096;
    /// Serialized message bytes in one conversation, including repair reservations.
    pub const HISTORY_BYTES: usize = 32 * 1024 * 1024;
    /// Aggregate serialized conversation bytes owned by one application.
    pub const APPLICATION_HISTORY_BYTES: usize = 64 * 1024 * 1024;
    /// Bytes in one canonical history message before any native admission.
    pub const HISTORY_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
    /// Committed provider calls retained in one conversation ledger.
    pub const HISTORY_CALLS: usize = 8192;
    /// Bytes reserved before committing each call for an eventual synthetic result.
    pub const HISTORY_REPAIR_BYTES: usize = 1024;
    /// Default number of trailing messages preserved during history compaction.
    pub const HISTORY_COMPACT_KEEP: usize = 8;
    /// Explicit model-turn ceiling, independent of charged HTTP retry attempts.
    pub const AGENT_MODEL_TURNS: u32 = 4096;
    /// Consecutive semantic duplicate calls requiring a separate decision.
    pub const AGENT_REPETITIONS: u8 = 3;
    /// Maximum automatic self-healing rounds per agent run for new diagnostic errors.
    pub const AGENT_HEALING_ROUNDS: u8 = 2;
    /// Canonical and provider-encoded request body bytes accepted by HTTP.
    pub const API_REQUEST_BYTES: usize = 768 * 1024;
    /// Concurrent staged history imports; aggregate source bytes remain bounded separately.
    pub const HISTORY_UPLOADS: usize = 4;
    /// Canonical definitions and aliases accepted by one native tool catalog.
    pub const TOOL_DEFINITIONS: usize = 256;
    /// Serialized bytes in the trusted built-in tool manifest.
    pub const TOOL_MANIFEST_BYTES: usize = 512 * 1024;
    /// Bytes in one tool description or schema field description.
    pub const TOOL_DESCRIPTION_BYTES: usize = 16 * 1024;
    /// Nodes in one bounded parameter schema.
    pub const TOOL_SCHEMA_NODES: usize = 1024;
    /// Nested object/array schema depth, independently of JSON codec recursion.
    pub const TOOL_SCHEMA_DEPTH: usize = 16;
    /// Metadata/expressions in one delegated editor tool; file bodies use edit uploads.
    pub const EDITOR_TOOL_ARGUMENT_BYTES: usize = 64 * 1024;
    /// Maximum plan content UTF-8 bytes accepted by the native plan domain.
    pub const PLAN_TEXT_BYTES: usize = 1024 * 1024;
    /// Bounded retained plan records per conversation.
    pub const SESSION_PLANS: usize = 16;
    /// Decoded text/patch bytes accepted by the native edit domain.
    pub const EDIT_TEXT_BYTES: usize = 4 * 1024 * 1024;
    /// Maximum encoded metadata-only record in an edit issuance journal.
    pub const EDIT_JOURNAL_RECORD_BYTES: usize = 4 * 1024 * 1024;
    /// Issue, optional uncertainty marker, and consuming terminal record.
    pub const EDIT_JOURNAL_RECORDS: u8 = 3;
    /// Total edit journal bytes, including newline framing.
    pub const EDIT_JOURNAL_BYTES: usize =
        (EDIT_JOURNAL_RECORD_BYTES + 1) * EDIT_JOURNAL_RECORDS as usize;
    /// Unread metadata-only receipt streams, including reserved active edits.
    pub const EDIT_RECEIPT_STREAMS: usize = 8;
    /// Maximum serialized credential-free provider projection bytes.
    pub const PROVIDER_CATALOG_BYTES: usize = 1024 * 1024;
    /// Retained resolved edit journal files per journal directory.
    pub const EDIT_JOURNAL_FILES: usize = 64;
    /// Unresolved/corrupt private journals preserved before refusing new issuance.
    pub const EDIT_JOURNAL_UNRESOLVED_FILES: usize = 64;
    /// Native disk bytes before strict decoding into bounded edit text.
    pub const EDIT_DISK_BYTES: usize = 16 * 1024 * 1024;
    /// Bounded Git diagnostics, never returned as edit source or success prose.
    pub const EDIT_PATCH_OUTPUT_BYTES: usize = 64 * 1024;
    /// Retained upload/prepare byte reservations per application.
    pub const EDIT_BUFFER_BYTES: usize = 16 * 1024 * 1024;
    /// Written and final editor observations for the single globally issued writer.
    pub const EDIT_RECEIPT_BYTES: usize = 32 * 1024 * 1024;
    /// Upload/prepare/ready records per application, including draining work.
    pub const EDIT_PREPARATIONS: usize = 2;
    /// Open and retired service identities retained until their session closes.
    pub const EDIT_SERVICES: usize = 256;
    /// UTF-8 source bytes per edit upload or immutable read page.
    pub const EDIT_PAGE_BYTES: usize = 32 * 1024;
    /// File operations in one fully preflighted edit transaction.
    pub const EDIT_FILES: usize = 256;
    /// Hunk records in one edit transaction.
    pub const EDIT_HUNKS: usize = 4096;
    /// Framing lines accepted before any Git preparation or editor effect.
    pub const EDIT_PATCH_LINES: usize = 200_000;
    /// Retained applied rollback snapshots per application.
    pub const EDIT_SNAPSHOTS: usize = 16;
    /// Diagnostics accepted in one detached live-editor observation.
    pub const SENSOR_DIAGNOSTICS: usize = 4096;
    /// Total diagnostic payload bytes, independent of the transport frame size.
    pub const SENSOR_DIAGNOSTIC_BYTES: usize = 256 * 1024;
    /// UTF-8 bytes in a single sensor message or symbol description.
    pub const SENSOR_TEXT_BYTES: usize = 16 * 1024;
    /// Nodes retained in one document symbol tree.
    pub const SENSOR_SYMBOLS: usize = 2048;
    /// Maximum symbol hierarchy depth, counting roots as depth zero.
    pub const SENSOR_SYMBOL_DEPTH: usize = 16;
    /// Serialized document symbol metadata, independent of IPC frame size.
    pub const SENSOR_SYMBOL_BYTES: usize = 128 * 1024;
    /// One symbol identifier or qualified query, before rendering.
    pub const SENSOR_SYMBOL_NAME_BYTES: usize = 1024;
    /// Independently observed checker identities on one document.
    pub const SENSOR_BACKENDS: usize = 64;
    /// Original and final text in the bounded application rollback history.
    pub const EDIT_HISTORY_BYTES: usize = EDIT_BUFFER_BYTES + EDIT_RECEIPT_BYTES;
    /// UTF-8 bytes per wire frame, excluding LF.
    pub const MAX_FRAME_BYTES: usize = 1024 * 1024;
    /// Minimum frame size accepted by negotiation.
    pub const MIN_FRAME_BYTES: usize = 1024;
    /// Pending calls or approvals per owner.
    pub const MAX_PENDING: usize = 128;
    /// Control queue message capacity.
    pub const CONTROL_CAPACITY: usize = 128;
    /// Retained control queue bytes.
    pub const CONTROL_BYTES: usize = 1024 * 1024;
    /// Applications in one host.
    pub const MAX_APPLICATIONS: usize = 64;
    /// Sessions in one host.
    pub const MAX_SESSIONS: usize = 256;
    /// Maximum serialized session file size accepted for reading and writing.
    /// A record holds a full history plus its transcript presentation, so it is
    /// sized from the history bound rather than chosen independently.
    pub const SESSION_MAX_FILE_BYTES: usize = 2 * HISTORY_BYTES;
    /// Maximum session files inspected during one listing.
    pub const SESSION_LIST_MAX_FILES: usize = 500;
    /// Maximum cumulative bytes read across session files during one listing (64 MiB).
    pub const SESSION_LIST_MAX_TOTAL_BYTES: usize = 64 * 1024 * 1024;
    /// Maximum session schema depth inspected before rejecting.
    pub const SESSION_VALIDATE_MAX_DEPTH: usize = 32;
    /// Maximum session nodes inspected before rejecting.
    pub const SESSION_VALIDATE_MAX_NODES: usize = 100_000;
    /// Maximum messages in one persisted session record: exactly what a
    /// restored history can hold, so every saved session can be restored.
    pub const SESSION_MAX_MESSAGES: usize = HISTORY_MESSAGES;
    const _: () = assert!(SESSION_MAX_FILE_BYTES >= HISTORY_BYTES);
    /// Maximum client version length.
    pub const CLIENT_VERSION_BYTES: usize = 128;
    /// Maximum advertised client capabilities.
    pub const CLIENT_CAPABILITIES: usize = 64;
    /// Maximum tool name length.
    pub const TOOL_NAME_BYTES: usize = 64;
    /// Maximum provider tool-call identity bytes.
    pub const PROVIDER_CALL_ID_BYTES: usize = 256;
    /// Maximum opaque request owner length.
    pub const REQUEST_SCOPE_BYTES: usize = 256;
    /// Default run tool call limit.
    pub const TOOL_CALLS: u64 = 25;
    /// Concrete preparation/execution actions within a single model invocation.
    pub const TOOL_EXECUTION_STEPS: usize = 16;
    /// Concurrent subprocesses per run.
    pub const RUN_PROCESSES: usize = 4;
    /// Persistent/draining process-job scopes per application, independent of its turn.
    pub const APPLICATION_JOBS: usize = 4;
    /// Concurrent subprocesses across the supervisor.
    pub const HOST_PROCESSES: usize = 16;
    /// Retained stdout or stderr per job.
    pub const PROCESS_OUTPUT_BYTES: usize = 1024 * 1024;
    /// Configurable retained bytes per stream for persistent logs (zero is allowed).
    pub const PROCESS_OUTPUT_MAX_BYTES: usize = 4 * 1024 * 1024;
    /// Retained process output across a run.
    pub const RUN_OUTPUT_BYTES: usize = 8 * 1024 * 1024;
    /// Maximum character budget for a single tool result presented to the model/history.
    pub const MODEL_TOOL_OUTPUT_CHARS: usize = 30000;
    /// Input or output page length.
    pub const PROCESS_PAGE_BYTES: usize = 32 * 1024;
    /// Bounded record capture, including a possible adapter lookahead record.
    pub const PROCESS_RECORDS: u64 = 1_000_001;
    /// Queued stdin commands per job.
    pub const PROCESS_INPUT_QUEUE: usize = 8;
    /// Aggregate argv bytes before spawning a program.
    pub const COMMAND_BYTES: usize = 64 * 1024;
    /// Maximum command argument count.
    pub const COMMAND_ARGUMENTS: usize = 256;
    /// Explicit environment entries; Nix/dev shells commonly exceed 128.
    /// Aggregate environment bytes remain bounded by COMMAND_BYTES.
    pub const COMMAND_ENVIRONMENT_ENTRIES: usize = 512;
    /// Tracked jobs, including terminal but uncollected jobs.
    pub const JOBS: usize = 64;
    /// Concurrent native read workers on one connection, including draining work.
    pub const READ_WORKERS: usize = 4;
    /// Files/directories qualified by one Git mutation approval.
    pub const GIT_ACTION_ENTRIES: usize = 4096;
    /// Live/draining HTTP attempts on one connection.
    pub const API_REQUESTS: usize = 8;
    /// Network events waiting for the mailbox; a completion batch adds one barrier.
    pub const API_EVENTS: usize = 16;
    /// Automatic physical retries per logical API operation.
    pub const API_RETRIES: u64 = 10;
    /// Largest captured exponential jitter window.
    pub const API_BACKOFF_MS: u64 = 60_000;
    /// Maximum supported server wait or circuit cooldown.
    pub const API_SERVER_WAIT_MS: u64 = 86_400_000;
    /// Largest accepted circuit failure threshold.
    pub const API_CIRCUIT_FAILURES: u64 = 1_000;
    /// Captured provider circuits per connection; unhealthy entries are not evicted.
    pub const API_CIRCUITS: usize = 256;
    /// Bounded entropy rejection attempts; failure never becomes zero jitter.
    pub const API_RANDOM_DRAWS: usize = 32;
    /// Maximum raw discovery response accepted by the model envelope boundary.
    pub const MODEL_CATALOG_BYTES: usize = 8 * 1024 * 1024;
    /// Maximum explicit model records in one complete discovery response.
    pub const MODEL_CATALOG_RECORDS: usize = 20_000;
    /// Complete canonical projection, transferred through bounded byte pages.
    pub const MODEL_SNAPSHOT_BYTES: usize = 16 * 1024 * 1024;
    /// UTF-8 upload fragment and maximum unescaped snapshot page.
    pub const MODEL_PAGE_BYTES: usize = 16 * 1024;
    /// Pending model upload lifetime; unrelated to an agent turn's lifetime.
    pub const MODEL_UPLOAD_SECONDS: u64 = 60;
    /// Retained charges in one API accounting lifetime.
    pub const API_BUDGET_ATTEMPTS: u64 = 10_000;
    /// Accepted logical compactions per accounting lifetime.
    pub const API_BUDGET_COMPACTIONS: u64 = 10_000;
    /// Maximum file discoveries accepted from a client configuration.
    pub const SEARCH_FILES: usize = 20_000;
    /// Maximum directory visits accepted from a client configuration.
    pub const SEARCH_DIRECTORIES: usize = 20_000;
    /// Hard bound on all inspected directory entries, including non-files.
    pub const SEARCH_ENTRIES: usize = 100_000;
    /// Open directory iterator depth; directory symlinks are never followed.
    pub const SEARCH_DEPTH: usize = 128;
    /// File paths in one result.
    pub const SEARCH_RESULTS: usize = 200;
    /// Unescaped result text; transport also checks the negotiated frame size.
    pub const SEARCH_RESULT_BYTES: usize = 64 * 1024;
    /// Bytes in one glob expression.
    pub const SEARCH_PATTERN_BYTES: usize = 1024;
    /// Bytes in a client-supplied path.
    pub const SEARCH_PATH_BYTES: usize = 4096;
    /// Skill metadata records in one catalog.
    pub const SKILL_RECORDS: usize = 128;
    /// Largest individual SKILL.md input.
    pub const SKILL_FILE_BYTES: usize = 1024 * 1024;
    /// Aggregate skill source bytes captured by one request.
    pub const SKILL_SOURCE_BYTES: usize = 4 * 1024 * 1024;
    /// Unescaped catalog or loaded body presentation.
    pub const SKILL_OUTPUT_BYTES: usize = 128 * 1024;
    /// Maximum loaded body character budget.
    pub const SKILL_BODY_CHARS: usize = 32768;
    /// UTF-8 bytes in a parsed skill name.
    pub const SKILL_NAME_BYTES: usize = 1024;
    /// UTF-8 bytes in one skill description.
    pub const SKILL_DESCRIPTION_BYTES: usize = 8192;
    /// Ordinary project asset files before declining deeper traversal.
    pub const SKILL_PROJECT_ASSETS: usize = 400;
    /// Ordinary user asset files before declining deeper traversal.
    pub const SKILL_USER_ASSETS: usize = 100;
}

/// Timeouts are typed durations, never shared unlabelled numbers.
pub mod timeouts {
    use std::time::Duration;
    /// Absolute staging and validation lifetime of a canonical history import.
    pub const HISTORY_IMPORT: Duration = Duration::from_secs(30);
    /// Bounded journal IO worker lifetime; slots survive cancellation until join.
    pub const EDIT_JOURNAL: Duration = Duration::from_secs(30);
    /// Issued editor confirmation interval; expiry revokes but does not prove quiescence.
    pub const EDIT_RECEIPT: Duration = Duration::from_secs(30);
    /// Credential observation cap; expiry revokes while actual quiescence still drains.
    pub const CREDENTIAL_RECEIPT: Duration = Duration::from_secs(5);
    /// Bounded native all-file edit preflight worker lifetime.
    pub const EDIT_PREFLIGHT: Duration = Duration::from_secs(30);
    /// Stalled transport writer deadline.
    pub const WRITE: Duration = Duration::from_secs(5);
    /// Pending-request expiry sweep.
    pub const PENDING_SWEEP: Duration = Duration::from_millis(50);
    /// Non-reaping process-state observation interval.
    pub const PROCESS_POLL: Duration = Duration::from_millis(20);
    /// Maximum wait for stdin acceptance or a contended output page.
    pub const INPUT_ACK: Duration = Duration::from_secs(10);
    /// Receipt-to-client ownership handoff before an unclaimed job is revoked.
    pub const JOB_CLAIM: Duration = Duration::from_secs(5);
    /// Human approval lifetime.
    pub const APPROVAL: Duration = Duration::from_secs(300);
    /// TERM before KILL grace.
    pub const PROCESS_GRACE: Duration = Duration::from_secs(5);
    /// Pipe and reap cleanup deadline after forced termination.
    pub const PROCESS_DRAIN: Duration = Duration::from_secs(5);
    /// Read-only native workspace operation lifetime.
    pub const WORKSPACE_READ: Duration = Duration::from_secs(30);
}

/// Negotiated wire version and method identifiers.
pub mod protocol {
    /// JSON-RPC envelope version.
    pub const JSONRPC: &str = "2.0";
    /// Kargu protocol major version.
    pub const MAJOR: u16 = 1;
    /// Kargu protocol minor version.
    pub const MINOR: u16 = 0;
    /// Canonical generic process tool; all subprocesses require approval.
    pub const BASH_TOOL: &str = "bash";
    /// Implemented standalone wire services, not yet a full agent backend.
    pub const LIFECYCLE_CAPABILITIES: &[&str] = &[
        "edit_preparation",
        "edit_history",
        "history_snapshot",
        "history_store",
        "edit_patch_preparation",
        "workspace_probe",
        "workspace_webfetch",
        "git_mutation",
        "workspace_skills",
        "git_worktree_read",
        "workspace_read_file",
        "git_read",
        "configuration_policy",
        "configuration_read",
        "configuration_parse",
        "api_request",
        "api_chat_target",
        "api_wire",
        "api_request_policy",
        "api_auth",
        "api_budget",
        "api_retry",
        "api_circuit",
        "api_failure",
        "api_model_catalog",
        "model_metadata",
        "model_metadata_projection",
        "application_lifecycle",
        "application_close",
        "session_lifecycle",
        methods::PING,
        "workspace_find_files",
        "workspace_mention_candidates",
        "workspace_list_files_ls",
        "workspace_grep",
        "git_status",
        "provider_catalog",
        "provider_catalog_pages",
        "provider_catalog_target",
        "command_execute",
        "process_jobs",
        "process_idle_timeout",
        "capabilities_list",
        "session_persistence",
    ];

    /// Items per capability page to fit well under minimum frame limit (1024 bytes).
    pub const CAPABILITY_PAGE_ITEMS: usize = 16;
    /// Minimal capabilities returned during initialize handshake at minimum frame limit.
    pub const HANDSHAKE_CAPABILITIES: &[&str] = &[
        "capabilities_list",
        "application_lifecycle",
        "session_lifecycle",
        methods::PING,
        "provider_catalog",
        "provider_catalog_pages",
        "model_metadata",
    ];

    /// JSON-RPC and host error codes, kept separate from human error messages.
    pub mod error_codes {
        /// Invalid JSON syntax or duplicate keys.
        pub const PARSE: i64 = -32700;
        /// Invalid envelope.
        pub const INVALID_REQUEST: i64 = -32600;
        /// Missing method or capability.
        pub const METHOD_NOT_FOUND: i64 = -32601;
        /// Invalid method arguments.
        pub const INVALID_PARAMS: i64 = -32602;
        /// Incompatible handshake.
        pub const INCOMPATIBLE_VERSION: i64 = -32001;
        /// Invalid lifecycle phase.
        pub const INVALID_STATE: i64 = -32002;
        /// Foreign or obsolete scope.
        pub const STALE_OWNER: i64 = -32003;
        /// Host resource capacity.
        pub const RESOURCE_LIMIT: i64 = -32004;
        /// Workspace policy rejected a read target.
        pub const REJECTED: i64 = -32005;
        /// An operation was cancelled before publication.
        pub const CANCELLED: i64 = -32006;
        /// Operation deadline expired.
        pub const TIMEOUT: i64 = -32007;
        /// Captured filesystem identity changed.
        pub const WORKSPACE_CHANGED: i64 = -32008;
        /// Sanitized filesystem failure.
        pub const IO: i64 = -32009;
        /// A side-effecting continuation may already have been accepted.
        pub const OUTCOME_UNKNOWN: i64 = -32010;
    }
    /// Canonical method names.
    pub mod methods {
        /// Reserve an exact-revision private conversation import.
        pub const HISTORY_BEGIN: &str = "history/begin";
        /// Append one exact-offset UTF-8 history fragment.
        pub const HISTORY_APPEND: &str = "history/append";
        /// Validate an import on a bounded worker, then atomically adopt it.
        pub const HISTORY_COMMIT: &str = "history/commit";
        /// Revoke one import without replacing conversation state.
        pub const HISTORY_ABORT: &str = "history/abort";
        /// Read canonical conversation message metadata at one exact native revision.
        pub const HISTORY_MESSAGES: &str = "history/messages";
        /// Read a bounded UTF-8 slice of a canonical message without serializing the whole store.
        pub const HISTORY_READ: &str = "history/read";
        /// Consume a prepared artifact into the shared editor permission ledger.
        pub const EDIT_AUTHORIZE: &str = "edit/authorize";
        /// Revoke one issued editor token without asserting quiescence.
        pub const EDITOR_REVOKE_EDIT: &str = "editor/revoke_edit";
        /// Consume a complete preflight and journal before returning one issuance token.
        pub const EDIT_ISSUE: &str = "edit/issue";
        /// Settle an issued token after actual editor quiescence, including retired owners.
        pub const EDIT_QUIESCENT: &str = "edit/quiescent";
        /// Revise proposed text during review, publishing an incremented review revision.
        pub const EDIT_REVISE: &str = "edit/revise";
        /// Prepare an inverse native proposal from a committed editor transaction.
        pub const EDIT_ROLLBACK: &str = "edit/rollback";
        /// Inspect a durable edit journal without creating a run or write capability.
        pub const EDIT_RECOVER: &str = "edit/recover";
        /// Read session-owned rollback metadata without granting execution rights.
        pub const EDIT_HISTORY: &str = "edit/history";
        /// Record raw editor observations and verify the final transaction outcome.
        pub const EDIT_RECEIPT: &str = "edit/receipt";
        /// Add one live preflight witness; the complete set is revalidated off-actor.
        pub const EDIT_PREFLIGHT: &str = "edit/preflight";
        /// Decide exactly one native editor review revision.
        pub const EDIT_DECISION: &str = "edit/decision";
        /// Parse an uploaded patch before requesting live document captures.
        pub const EDIT_INSPECT: &str = "edit/inspect";
        /// Read bounded native patch target pages.
        pub const EDIT_TARGETS: &str = "edit/targets";
        /// Attach one exact live document to an inspected patch target.
        pub const EDIT_DOCUMENT: &str = "edit/document";
        /// Read bounded immutable batch file descriptors.
        pub const EDIT_FILES: &str = "edit/files";
        /// Reserve a bounded source-owned proposal upload.
        pub const EDIT_BEGIN: &str = "edit/begin";
        /// Append one exact-offset source part, never an executable expression.
        pub const EDIT_APPEND: &str = "edit/append";
        /// Consume complete upload parts on an owned native I/O worker.
        pub const EDIT_PREPARE: &str = "edit/prepare";
        /// Read one immutable base/proposed UTF-8 page.
        pub const EDIT_READ: &str = "edit/read";
        /// Abort one preparation without affecting foreign sources.
        pub const EDIT_ABORT: &str = "edit/abort";
        /// Revoke only one editor source's preparations.
        pub const EDIT_CLOSE: &str = "edit/close";
        /// Readonly epoch-bound parsing of one captured configuration source.
        pub const CONFIGURATION_PARSE: &str = "configuration/parse";
        /// Pure bounded mention parsing, with no source/egress authority.
        pub const MENTIONS_PARSE: &str = "mentions/parse";
        /// Bounded readonly editor config file capture and parsing.
        pub const CONFIGURATION_READ: &str = "configuration/read";
        /// Natively ordered config discovery, read, parse and staging for one session.
        pub const CONFIGURATION_REFRESH: &str = "configuration/refresh";
        /// Start a revision-bound, session-owned bounded metadata upload.
        pub const MODEL_BEGIN: &str = "models/begin";
        /// Append one exact-offset UTF-8 fragment, without publication.
        pub const MODEL_APPEND: &str = "models/append";
        /// Parse and atomically publish a complete metadata update.
        pub const MODEL_COMMIT: &str = "models/commit";
        /// Discard only the caller's exact pending upload.
        pub const MODEL_ABORT: &str = "models/abort";
        /// Read the current committed revision/byte descriptor.
        pub const MODEL_SNAPSHOT: &str = "models/snapshot";
        /// Read one immutable committed-revision UTF-8 page.
        pub const MODEL_READ: &str = "models/read";
        /// Credential-free embedded provider definitions for editor projection.
        pub const PROVIDER_CATALOG: &str = "provider/catalog";
        /// Pure epoch-bound catalog target projection before credential discovery.
        pub const PROVIDER_CATALOG_TARGET: &str = "provider/catalogTarget";
        /// Configured and embedded provider list for UI presentation.
        pub const PROVIDER_LIST: &str = "provider/list";
        /// List models for a provider with reasoning capabilities.
        pub const MODEL_LIST: &str = "model/list";
        /// Fetch remote model catalog and refresh store asynchronously.
        pub const MODEL_REFRESH: &str = "model/refresh";
        /// Owned HTTP attempt with bounded SSE deltas and explicit cancellation.
        pub const API_REQUEST: &str = "api/request";
        /// Allocate one shared, application-bound accounting lifetime.
        pub const API_BUDGET_OPEN: &str = "api/budget/open";
        /// Detached authoritative accounting observation.
        pub const API_BUDGET_SNAPSHOT: &str = "api/budget/snapshot";
        /// Revoke admission and cancel/drain all charged attempts before replying.
        pub const API_BUDGET_CLOSE: &str = "api/budget/close";
        /// Read only the caller application's captured circuit projections.
        pub const API_CIRCUIT_SNAPSHOT: &str = "api/circuit/snapshot";
        /// Explicitly reset owned circuit revisions without replaying requests.
        pub const API_CIRCUIT_RESET: &str = "api/circuit/reset";
        /// Approved persistent process startup; returns identity, not completion.
        pub const JOB_START: &str = "job/start";
        /// Confirm that the client installed its owner-close cleanup after startup.
        pub const JOB_CLAIM: &str = "job/claim";
        /// Owner/project-scoped job snapshots.
        pub const JOB_LIST: &str = "job/list";
        /// Inspect startup/running/terminal state.
        pub const JOB_STATUS: &str = "job/status";
        /// Lossless bounded stdout/stderr byte page.
        pub const JOB_READ: &str = "job/read";
        /// Bounded UTF-8 stdin, acknowledged after actual acceptance.
        pub const JOB_WRITE: &str = "job/write";
        /// Close stdin once and retain drain ownership.
        pub const JOB_EOF: &str = "job/eof";
        /// Cancel one owned process group.
        pub const JOB_CANCEL: &str = "job/cancel";
        /// Release only a drained terminal archive.
        pub const JOB_FORGET: &str = "job/forget";
        /// Standalone approved program/argv execution during the migration.
        pub const EXECUTE: &str = "tool/execute";
        /// Exact-action asynchronous command approval presenter.
        pub const REQUEST_APPROVAL: &str = "editor/request_approval";
        /// Initialize connection.
        pub const INITIALIZE: &str = "initialize";
        /// Complete negotiation.
        pub const INITIALIZED: &str = "initialized";
        /// Paged capabilities listing.
        pub const CAPABILITIES_LIST: &str = "capabilities/list";
        /// Health request.
        pub const PING: &str = "ping";
        /// Create application.
        pub const APPLICATION_CREATE: &str = "application/create";
        /// Revoke application ownership, then reply only after service drain.
        pub const APPLICATION_CLOSE: &str = "application/close";
        /// Create session.
        pub const SESSION_CREATE: &str = "session/create";
        /// Get lifecycle projection.
        pub const SESSION_SNAPSHOT: &str = "session/snapshot";
        /// Read one conversation's committed provider/model/effort selection.
        pub const SESSION_SELECTION: &str = "session/selection";
        /// Replace a conversation's selection from its expected revision.
        pub const SESSION_SELECTION_COMMIT: &str = "session/selection/commit";
        /// Read one conversation's committed mode and available tools.
        pub const SESSION_MODE: &str = "session/mode";
        /// Replace a conversation's mode from its expected revision.
        pub const SESSION_MODE_COMMIT: &str = "session/mode/commit";
        /// Read one conversation's current plan record.
        pub const SESSION_PLAN: &str = "session/plan";
        /// Create or replace an implementation plan for one conversation.
        pub const SESSION_PLAN_CREATE: &str = "session/plan/create";
        /// Revise plan content and bump monotonic revision.
        pub const SESSION_PLAN_REVISE: &str = "session/plan/revise";
        /// Claim a plan for execution with expected revision and hash (single-use accept).
        pub const SESSION_PLAN_CLAIM: &str = "session/plan/claim";
        /// Settle plan dispatch completion.
        pub const SESSION_PLAN_COMPLETE: &str = "session/plan/complete";
        /// Reject a pending plan.
        pub const SESSION_PLAN_REJECT: &str = "session/plan/reject";
        /// Claim and run a native conversation turn through actual provider services.
        pub const SESSION_PROMPT: &str = "session/prompt";
        /// Revoke an exact native run; terminal acknowledgement follows actual drain.
        pub const SESSION_ABORT: &str = "session/abort";
        /// Continue an exact native run after a captured length/turn-cap decision.
        pub const SESSION_CONTINUE: &str = "session/continue";
        /// Close session.
        pub const SESSION_CLOSE: &str = "session/close";
        /// Persist session with single-writer lock, journal commit, and atomic snapshot.
        pub const SESSION_SAVE: &str = "session/save";
        /// Restore session with journal/snapshot recovery and outcome_unknown repair.
        pub const SESSION_LOAD: &str = "session/load";
        /// Bounded session metadata listing for a project.
        pub const SESSION_LIST: &str = "session/list";
        /// Delete persisted session snapshot and journal files.
        pub const SESSION_DELETE: &str = "session/delete";
        /// Prune persisted sessions and clean orphaned temp files according to retention policy.
        pub const SESSION_PRUNE: &str = "session/prune";
        /// Import and migrate legacy or v2 session without overwriting source.
        pub const SESSION_IMPORT: &str = "session/import";
        /// Atomically restore validated candidate session into live actor state.
        pub const SESSION_RESTORE: &str = "session/restore";
        /// Bounded, read-only native file discovery.
        pub const FIND_FILES: &str = "workspace/findFiles";
        /// Bounded regular-file or revision-bound editor text excerpt.
        pub const READ_FILE: &str = "workspace/readFile";
        /// Bounded skill discovery and named instruction loading.
        pub const SKILLS: &str = "workspace/skills";
        /// Public unauthenticated HTTP text read with per-hop egress admission.
        pub const WEBFETCH: &str = "workspace/webfetch";
        /// Declarative toolchain/executable discovery; never executes.
        pub const PROBE: &str = "workspace/probe";
        /// Ranked `@` mention completion paths from bounded native discovery.
        pub const MENTION_CANDIDATES: &str = "workspace/mentionCandidates";
        /// Bounded fixed-argv GNU ls listing, through the shared command service.
        pub const LIST_FILES: &str = "workspace/listFiles";
        /// Bounded rg/GNU grep composition through the shared process owner.
        pub const GREP: &str = "workspace/grep";
        /// Fixed-argv, complete-output read-only Git status report.
        pub const GIT_STATUS: &str = "git/status";
        /// Closed fixed-argv read-only Git query through shared execution policy.
        pub const GIT_READ: &str = "git/read";
        /// Closed, explicitly approved Git write intents.
        pub const GIT_MUTATION: &str = "git/mutate";
        /// Cancel pending request.
        pub const CANCEL: &str = "rpc/cancel";
        /// Drain host.
        pub const SHUTDOWN: &str = "shutdown";
        /// Exit connection.
        pub const EXIT: &str = "exit";
    }

    /// Canonical prompts used across native conversation lifecycles.
    pub mod prompts {
        /// User prompt for requesting a tools-off conversation history summary.
        pub const COMPACTION_REQUEST: &str = "COMPACTION_REQUEST: Summarize the conversation so far for another coding agent. \
            Output a structured summary with these headings: Goal, Done, Files and symbols touched, \
            Open issues, Next step. Use exact paths. Do not continue the task. Do not call tools. \
            Reply with the summary only.";
    }
}
