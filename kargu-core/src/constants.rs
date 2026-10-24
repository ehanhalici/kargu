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
    pub const LIFECYCLE_CAPABILITIES: [&str; 15] = [
        "api_request",
        "api_wire",
        "api_request_policy",
        "api_auth",
        "application_lifecycle",
        "session_lifecycle",
        methods::PING,
        "workspace_find_files",
        "workspace_list_files_ls",
        "workspace_grep",
        "git_status",
        "provider_catalog",
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
        /// Credential-free embedded provider definitions for editor projection.
        pub const PROVIDER_CATALOG: &str = "provider/catalog";
        /// Owned HTTP attempt with bounded SSE deltas and explicit cancellation.
        pub const API_REQUEST: &str = "api/request";
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
