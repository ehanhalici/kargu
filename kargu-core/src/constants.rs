//! Shared protocol names, resource bounds and deadlines. Wire fixtures remain literal.

/// Resource limits used by admission, transport and process supervision.
pub mod limits {
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
    /// Maximum client version length.
    pub const CLIENT_VERSION_BYTES: usize = 128;
    /// Maximum advertised client capabilities.
    pub const CLIENT_CAPABILITIES: usize = 64;
    /// Maximum tool name length.
    pub const TOOL_NAME_BYTES: usize = 64;
    /// Maximum opaque request owner length.
    pub const REQUEST_SCOPE_BYTES: usize = 256;
    /// Default run tool call limit.
    pub const TOOL_CALLS: u64 = 25;
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
}

/// Timeouts are typed durations, never shared unlabelled numbers.
pub mod timeouts {
    use std::time::Duration;
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
    pub const LIFECYCLE_CAPABILITIES: [&str; 25] = [
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
        "workspace_list_files_ls",
        "workspace_grep",
        "git_status",
        "provider_catalog",
        "provider_catalog_target",
        "command_execute",
        "process_jobs",
        "process_idle_timeout",
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
        /// Close session.
        pub const SESSION_CLOSE: &str = "session/close";
        /// Bounded, read-only native file discovery.
        pub const FIND_FILES: &str = "workspace/findFiles";
        /// Bounded fixed-argv GNU ls listing, through the shared command service.
        pub const LIST_FILES: &str = "workspace/listFiles";
        /// Bounded rg/GNU grep composition through the shared process owner.
        pub const GREP: &str = "workspace/grep";
        /// Fixed-argv, complete-output read-only Git status report.
        pub const GIT_STATUS: &str = "git/status";
        /// Cancel pending request.
        pub const CANCEL: &str = "rpc/cancel";
        /// Drain host.
        pub const SHUTDOWN: &str = "shutdown";
        /// Exit connection.
        pub const EXIT: &str = "exit";
    }
}
