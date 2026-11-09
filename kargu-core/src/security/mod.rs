//! Immutable command capture, explicit tool policy and single-use approval grants.
//!
//! Path identity checks are revalidation evidence, not an OS shell sandbox.

use crate::{
    application::ApplicationActor,
    constants::{limits, timeouts},
    domain::Mode,
    domain::*,
    error::CoreError,
    run::{RunHandle, RunLease, RunScope, ToolOutcome},
};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    ffi::OsString,
    fs::File,
    os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::time::Instant;

mod editor;
pub use crate::policy::{
    RegistryRevision, ToolDescriptor, ToolModes, ToolPresentation, ToolRegistry, ToolRoute,
    UserDecision, Workspace, schema,
};
mod delegated;
pub use delegated::{
    AuthorizedEditorTool, EditorResource, EditorToolAdmission, EditorToolApprovalRequest,
    IssuedEditorTool, PreparedEditorTool,
};
pub use editor::{
    AuthorizedEditorEdit, EditorAdmission, EditorAdmissionInput, EditorApprovalRequest,
    EditorDecision, EditorPresenter,
};
pub(crate) use editor::{IssuedEditorEdit, RevisedEditorAction};
mod action_snapshot;
pub(crate) mod file;
pub(crate) use action_snapshot::ActionSnapshot;
mod read_target;
pub(crate) use read_target::ReadTarget;

/// Explicit immutable subprocess environment; secrets are never implicitly inherited.
#[derive(Clone, Default)]
pub struct CommandEnvironment(BTreeMap<OsString, OsString>);
impl TryFrom<BTreeMap<OsString, OsString>> for CommandEnvironment {
    type Error = CoreError;
    fn try_from(values: BTreeMap<OsString, OsString>) -> Result<Self, CoreError> {
        if values.len() > limits::COMMAND_ENVIRONMENT_ENTRIES {
            return Err(CoreError::Limit);
        }
        let mut bytes = 0_usize;
        for (key, value) in &values {
            if key.is_empty()
                || key
                    .as_os_str()
                    .as_bytes()
                    .iter()
                    .any(|b| *b == 0 || *b == b'=')
                || value.as_os_str().as_bytes().contains(&0)
            {
                return Err(CoreError::InvalidValue {
                    field: "CommandEnvironment",
                });
            }
            bytes = bytes
                .checked_add(key.len())
                .and_then(|n| n.checked_add(value.len()))
                .ok_or(CoreError::ArithmeticOverflow)?;
        }
        if bytes > limits::COMMAND_BYTES {
            return Err(CoreError::Limit);
        }
        Ok(Self(values))
    }
}
impl CommandEnvironment {
    /// Iterate only for trusted execution/presentation; no Debug/Serialize is derived.
    pub fn entries(&self) -> impl Iterator<Item = (&OsString, &OsString)> {
        self.0.iter()
    }
}

#[derive(PartialEq, Eq)]
struct ExecutableRevision {
    device: u64,
    inode: u64,
    size: u64,
    mode: u32,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl From<&std::fs::Metadata> for ExecutableRevision {
    fn from(m: &std::fs::Metadata) -> Self {
        Self {
            device: m.dev(),
            inode: m.ino(),
            size: m.len(),
            mode: m.mode(),
            modified: (m.mtime(), m.mtime_nsec()),
            changed: (m.ctime(), m.ctime_nsec()),
        }
    }
}

/// Boundary DTO: parsed once before the immutable command is formed.
pub struct CommandInput {
    /// Explicit executable path; PATH/shell interpolation is not performed.
    pub program: PathBuf,
    /// Exact argv values.
    pub arguments: Vec<OsString>,
    /// Explicit working directory.
    pub working_directory: PathBuf,
    /// Per-command wall-clock limit, also capped by the run deadline.
    pub timeout: Option<Duration>,
    /// Exact approved environment. Empty means env_clear, not implicit inheritance.
    pub environment: CommandEnvironment,
}

/// Validated immutable command; no Debug or Serialize can disclose its arguments.
pub struct CommandSpec {
    action_snapshot: Option<Arc<ActionSnapshot>>,
    isolated_patch: Option<Workspace>,
    safety: ToolSafetyLevel,
    read_targets: Vec<ReadTarget>,
    pub(crate) invocation: PathBuf,
    pub(crate) program: PathBuf,
    pub(crate) arguments: Vec<OsString>,
    cwd: Workspace,
    timeout: ExecutionTimeout,
    pub(crate) idle_timeout: IdleTimeout,
    capture: CapturePolicy,
    pub(crate) success_codes: SuccessCodes,
    pub(crate) output_limit: OutputLimit,
    pub(crate) stderr: StderrPolicy,
    executable: File,
    revision: ExecutableRevision,
    pub(crate) environment: CommandEnvironment,
}
impl TryFrom<CommandInput> for CommandSpec {
    type Error = CoreError;
    fn try_from(input: CommandInput) -> Result<Self, CoreError> {
        let timeout = ExecutionTimeout::try_from(input.timeout)?;
        if !input.program.is_absolute() || input.arguments.len() > limits::COMMAND_ARGUMENTS {
            return Err(CoreError::InvalidValue { field: "Command" });
        }
        let mut size = input.program.as_os_str().len();
        for arg in &input.arguments {
            if arg.as_os_str().as_bytes().contains(&0) {
                return Err(CoreError::InvalidValue {
                    field: "CommandArgument",
                });
            }
            size = size
                .checked_add(arg.len())
                .ok_or(CoreError::ArithmeticOverflow)?;
        }
        if size > limits::COMMAND_BYTES {
            return Err(CoreError::Limit);
        }
        let program = input.program.canonicalize()?;
        // Refuse FIFO/device blocking at an untrusted executable boundary.
        let executable = File::from(
            nix::fcntl::open(
                &program,
                nix::fcntl::OFlag::O_RDONLY
                    | nix::fcntl::OFlag::O_NONBLOCK
                    | nix::fcntl::OFlag::O_NOFOLLOW
                    | nix::fcntl::OFlag::O_CLOEXEC,
                nix::sys::stat::Mode::empty(),
            )
            .map_err(std::io::Error::from)?,
        );
        let metadata = executable.metadata()?;
        if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
            return Err(CoreError::InvalidValue {
                field: "Executable",
            });
        }
        Ok(Self {
            action_snapshot: None,
            isolated_patch: None,
            safety: ToolSafetyLevel::ExecutesArbitraryCode,
            read_targets: Vec::new(),
            invocation: input.program,
            program,
            arguments: input.arguments,
            cwd: Workspace::try_from(input.working_directory)?,
            timeout,
            idle_timeout: IdleTimeout::DISABLED,
            capture: CapturePolicy::default(),
            success_codes: SuccessCodes::default(),
            output_limit: OutputLimit::default(),
            stderr: StderrPolicy::Separate,
            revision: ExecutableRevision::from(&metadata),
            executable,
            environment: input.environment,
        })
    }
}
impl CommandSpec {
    /// Closed Git adapter may prepare a patch only in its retained private
    /// workspace. This capability is never deserialized from command RPC input.
    pub(crate) fn edit_patch(input: CommandInput, workspace: Workspace) -> Result<Self, CoreError> {
        let mut command = Self::git_read(input)?;
        workspace.revalidate()?;
        if command.cwd.path() != workspace.path() {
            return Err(CoreError::Rejected);
        }
        command.isolated_patch = Some(workspace);
        Ok(command)
    }
    pub(crate) fn with_action_snapshot(mut self, snapshot: Arc<ActionSnapshot>) -> Self {
        self.action_snapshot = Some(snapshot);
        self
    }
    /// Select ordinary retention mode, replacing any record capture before approval.
    pub fn with_retention(mut self, retention: OutputRetention) -> Self {
        self.capture = CapturePolicy::Retain(retention);
        self
    }
    /// Capture a complete output policy; Records always uses prefix retention.
    pub fn with_capture(mut self, capture: CapturePolicy) -> Self {
        self.capture = capture;
        self
    }
    /// Capture adapter-selected success semantics, never inferred from command text.
    pub fn with_success_codes(mut self, policy: SuccessCodes) -> Self {
        self.success_codes = policy;
        self
    }
    /// Capture a bounded output capacity before requesting approval.
    pub fn with_output_limit(mut self, limit: OutputLimit) -> Self {
        self.output_limit = limit;
        self
    }
    /// Capture OS-level stderr routing before approval.
    pub fn with_stderr(mut self, policy: StderrPolicy) -> Self {
        self.stderr = policy;
        self
    }
    /// Capture idle termination as part of the exact approved action.
    pub fn with_idle_timeout(mut self, timeout: IdleTimeout) -> Self {
        self.idle_timeout = timeout;
        self
    }
    /// Only the trusted fixed-argv listing adapter can request this class.
    pub(crate) fn directory_listing(input: CommandInput) -> Result<Self, CoreError> {
        let mut command = Self::try_from(input)?;
        command.safety = ToolSafetyLevel::SafeReadOnly;
        Ok(command)
    }
    /// Only the trusted fixed-argv content-search adapter may request this class.
    pub(crate) fn workspace_grep(input: CommandInput) -> Result<Self, CoreError> {
        let mut command = Self::try_from(input)?;
        command.safety = ToolSafetyLevel::SafeReadOnly;
        Ok(command)
    }
    /// Trusted fixed-argv Git adapters disable optional writes and executable config.
    pub(crate) fn git_read(input: CommandInput) -> Result<Self, CoreError> {
        let mut command = Self::try_from(input)?;
        command.safety = ToolSafetyLevel::SafeReadOnly;
        Ok(command)
    }
    pub(crate) fn with_read_target(mut self, target: PathBuf) -> Result<Self, CoreError> {
        self = self.with_target_evidence(ReadTarget::try_from(target)?)?;
        Ok(self)
    }
    pub(crate) fn with_snapshot_target(self, target: PathBuf) -> Result<Self, CoreError> {
        self.with_target_evidence(ReadTarget::snapshot(target)?)
    }
    pub(crate) fn with_target_evidence(mut self, target: ReadTarget) -> Result<Self, CoreError> {
        if self.read_targets.len() >= 8 {
            return Err(CoreError::Limit);
        }
        self.read_targets.push(target);
        Ok(self)
    }
    fn revalidate(&self, run: &RunHandle) -> Result<(), CoreError> {
        if let Some(snapshot) = &self.action_snapshot {
            snapshot.revalidate()?;
        }
        run.check_live()?;
        run.settings().workspace().revalidate()?;
        self.cwd.revalidate()?;
        for target in &self.read_targets {
            target.revalidate()?;
        }
        let isolated = match &self.isolated_patch {
            Some(workspace) => {
                workspace.revalidate()?;
                self.cwd.path() == workspace.path()
            }
            None => false,
        };
        if !isolated
            && !self
                .cwd
                .path()
                .starts_with(run.settings().workspace().path())
        {
            return Err(CoreError::Rejected);
        }
        let held = self.executable.metadata()?;
        let current = self
            .program
            .metadata()
            .map_err(|_| CoreError::WorkspaceChanged)?;
        if held.dev() != current.dev()
            || held.ino() != current.ino()
            || self.revision != ExecutableRevision::from(&current)
        {
            return Err(CoreError::WorkspaceChanged);
        }
        Ok(())
    }
}

/// SHA-256 of owner, revisions, canonical tool, executable identity, cwd and argv.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActionDigest([u8; 32]);
impl serde::Serialize for ActionDigest {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(
            &self
                .0
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>(),
        )
    }
}
fn digest(
    run: &RunHandle,
    name: &ToolName,
    command: &CommandSpec,
) -> Result<ActionDigest, CoreError> {
    let mut hash = Sha256::new();
    hash.update(b"kargu-command-v1");
    match &command.action_snapshot {
        Some(snapshot) => {
            hash.update([1]);
            hash.update(snapshot.digest());
        }
        None => hash.update([0]),
    }
    put_read_targets(&mut hash, &command.read_targets)?;
    let scope = serde_json::to_vec(run.scope())
        .map_err(|_| CoreError::InvalidValue { field: "RunScope" })?;
    for bytes in [
        scope.as_slice(),
        name.as_str().as_bytes(),
        command.program.as_os_str().as_bytes(),
        command.invocation.as_os_str().as_bytes(),
        command.cwd.path().as_os_str().as_bytes(),
    ] {
        put_bytes(&mut hash, bytes)?;
    }
    put_invocation(&mut hash, command)?;
    put_policies(&mut hash, command)?;
    Ok(ActionDigest(hash.finalize().into()))
}

/// Length prefix shared by every variable-size digest field.
fn put_len(hash: &mut Sha256, len: usize) -> Result<(), CoreError> {
    hash.update(
        u64::try_from(len)
            .map_err(|_| CoreError::ArithmeticOverflow)?
            .to_le_bytes(),
    );
    Ok(())
}

/// One length-prefixed byte field.
fn put_bytes(hash: &mut Sha256, bytes: &[u8]) -> Result<(), CoreError> {
    put_len(hash, bytes.len())?;
    hash.update(bytes);
    Ok(())
}

/// Identity of every declared read target; immutable ones also pin content metadata.
fn put_read_targets(hash: &mut Sha256, targets: &[ReadTarget]) -> Result<(), CoreError> {
    put_len(hash, targets.len())?;
    for target in targets {
        let metadata = target.metadata()?;
        hash.update([u8::from(target.immutable())]);
        if target.immutable() {
            hash.update(metadata.len().to_le_bytes());
            hash.update(metadata.mode().to_le_bytes());
            hash.update(metadata.mtime().to_le_bytes());
            hash.update(metadata.mtime_nsec().to_le_bytes());
            hash.update(metadata.ctime().to_le_bytes());
            hash.update(metadata.ctime_nsec().to_le_bytes());
        }
        hash.update(metadata.dev().to_le_bytes());
        hash.update(metadata.ino().to_le_bytes());
        put_bytes(hash, target.path.as_os_str().as_bytes())?;
    }
    Ok(())
}

/// Arguments, environment, and the executable and cwd identities.
fn put_invocation(hash: &mut Sha256, command: &CommandSpec) -> Result<(), CoreError> {
    put_len(hash, command.arguments.len())?;
    for arg in &command.arguments {
        put_bytes(hash, arg.as_os_str().as_bytes())?;
    }
    put_len(hash, command.environment.0.len())?;
    for (key, value) in command.environment.entries() {
        put_bytes(hash, key.as_os_str().as_bytes())?;
        put_bytes(hash, value.as_os_str().as_bytes())?;
    }
    for metadata in [command.executable.metadata()?, command.cwd.held_metadata()?] {
        hash.update(metadata.dev().to_le_bytes());
        hash.update(metadata.ino().to_le_bytes());
    }
    Ok(())
}

/// An optional duration as a presence tag plus nanoseconds.
fn put_duration(hash: &mut Sha256, duration: Option<Duration>) {
    match duration {
        Some(duration) => {
            hash.update([1]);
            hash.update(duration.as_nanos().to_le_bytes());
        }
        None => hash.update([0]),
    }
}

/// Timeouts, capture, exit-code and stderr policies, and the output limit.
fn put_policies(hash: &mut Sha256, command: &CommandSpec) -> Result<(), CoreError> {
    put_duration(hash, command.timeout.duration());
    put_duration(hash, command.idle_timeout.duration());
    hash.update([match command.capture.retention() {
        OutputRetention::Prefix => 0,
        OutputRetention::Tail => 1,
    }]);
    match command.capture {
        CapturePolicy::Retain(_) => hash.update([0]),
        CapturePolicy::Records(limit) => {
            hash.update([1]);
            hash.update(limit.as_u64().to_le_bytes());
        }
        CapturePolicy::Complete => hash.update([2]),
    }
    hash.update([match command.success_codes {
        SuccessCodes::Zero => 0,
        SuccessCodes::ZeroOrOne => 1,
        SuccessCodes::ZeroOrTwo => 2,
    }]);
    hash.update([match command.stderr {
        StderrPolicy::Separate => 0,
        StderrPolicy::Merge => 1,
    }]);
    put_len(hash, command.output_limit.as_usize())
}

/// Immutable review data; command text is accessible only through explicit getters.
pub struct ApprovalRequest {
    safety: ToolSafetyLevel,
    retention: OutputRetention,
    stdout_records: Option<RecordLimit>,
    stop_on_bytes: bool,
    success_codes: SuccessCodes,
    output_limit: OutputLimit,
    timeout: ExecutionTimeout,
    idle_timeout: IdleTimeout,
    stderr: StderrPolicy,
    id: ApprovalId,
    scope: RunScope,
    digest: ActionDigest,
    deadline: Instant,
    name: ToolName,
    program: PathBuf,
    invocation: PathBuf,
    arguments: Vec<OsString>,
    cwd: PathBuf,
    environment: CommandEnvironment,
}
impl ApprovalRequest {
    /// Captured executor effect class, verified against the registry and command.
    /// A display/canonical tool name is never an automatic-approval authority.
    /// Callers cannot relabel a captured review:
    /// ```compile_fail
    /// use kargu_core::{security::ApprovalRequest, domain::ToolSafetyLevel};
    /// fn relabel(mut request: ApprovalRequest) {
    ///     request.safety = ToolSafetyLevel::SafeReadOnly;
    /// }
    /// ```
    pub fn safety(&self) -> ToolSafetyLevel {
        self.safety
    }
    /// Exact stdout producer-stop budget, separate from retained byte capacity.
    pub fn stdout_records(&self) -> Option<RecordLimit> {
        self.stdout_records
    }
    /// Byte overflow is an active producer stop/failure, not ordinary archive truncation.
    pub fn stop_on_bytes(&self) -> bool {
        self.stop_on_bytes
    }
    /// Exact accepted exit semantics.
    pub fn success_codes(&self) -> SuccessCodes {
        self.success_codes
    }
    /// Captured idle interval, separate from execution and approval timeouts.
    pub fn idle_timeout(&self) -> IdleTimeout {
        self.idle_timeout
    }
    /// Captured stdout/stderr routing.
    pub fn stderr(&self) -> StderrPolicy {
        self.stderr
    }
    /// Captured output policy shown to the reviewer.
    pub fn retention(&self) -> OutputRetention {
        self.retention
    }
    /// Captured per-stream retention capacity.
    pub fn output_limit(&self) -> OutputLimit {
        self.output_limit
    }
    /// Captured execution duration, not the independent approval lifetime.
    pub fn execution_timeout(&self) -> ExecutionTimeout {
        self.timeout
    }
    /// One-time approval identity, not an executable capability.
    pub fn id(&self) -> &ApprovalId {
        &self.id
    }
    /// Exact owning run and captured policy/config revisions.
    pub fn scope(&self) -> &RunScope {
        &self.scope
    }
    /// Commitment to the full action and runtime context.
    pub fn digest(&self) -> &ActionDigest {
        &self.digest
    }
    /// Deadline capped by the run deadline.
    pub fn deadline(&self) -> Instant {
        self.deadline
    }
    /// Canonical tool shown to the user.
    pub fn tool_name(&self) -> &ToolName {
        &self.name
    }
    /// Explicitly access the executable for a trusted confirmation presenter.
    pub fn program(&self) -> &Path {
        &self.program
    }
    /// Original executable spelling used as argv[0], significant for multicall binaries.
    pub fn invocation(&self) -> &Path {
        &self.invocation
    }
    /// Explicitly access argv; never put this in Debug/log output.
    pub fn arguments(&self) -> &[OsString] {
        &self.arguments
    }
    /// Captured working directory displayed for review.
    pub fn working_directory(&self) -> &Path {
        &self.cwd
    }
    /// Exact immutable environment for trusted user review; never implicitly logged.
    pub fn environment(&self) -> &CommandEnvironment {
        &self.environment
    }
}

enum CapturedAction {
    Command(Box<CommandSpec>),
    Editor(Box<crate::edit::intent::EditorAction>),
    Delegated(Box<PreparedEditorTool>),
}
struct PendingApproval {
    run: RunHandle,
    call_id: ToolCallId,
    step_id: Option<ToolStepId>,
    name: ToolName,
    action: CapturedAction,
    digest: ActionDigest,
    deadline: Instant,
    lease: RunLease,
}

/// Consuming, non-Clone execution capability. Only this module can construct it.
/// ```compile_fail
/// use kargu_core::security::AuthorizedCommand;
/// fn replay(grant: AuthorizedCommand) { let _second = grant.clone(); }
/// ```
pub struct AuthorizedCommand {
    run: RunHandle,
    call_id: ToolCallId,
    step_id: Option<ToolStepId>,
    command: CommandSpec,
    lease: RunLease,
    deadline: Instant,
}
pub(crate) struct ApprovedParts {
    pub(crate) run: RunHandle,
    pub(crate) call_id: ToolCallId,
    pub(crate) step_id: Option<ToolStepId>,
    pub(crate) command: CommandSpec,
    pub(crate) lease: RunLease,
}
impl AuthorizedCommand {
    pub(crate) fn run(&self) -> &RunHandle {
        &self.run
    }
    pub(crate) fn call_id(&self) -> &ToolCallId {
        &self.call_id
    }
    pub(crate) fn step_id(&self) -> Option<&ToolStepId> {
        self.step_id.as_ref()
    }
    pub(crate) fn command(&self) -> &CommandSpec {
        &self.command
    }
    pub(crate) fn into_parts(self) -> ApprovedParts {
        ApprovedParts {
            run: self.run,
            call_id: self.call_id,
            step_id: self.step_id,
            command: self.command,
            lease: self.lease,
        }
    }
    pub(crate) fn revalidate(&self, actor: &ApplicationActor) -> Result<(), CoreError> {
        actor.validate(&self.run)?;
        if Instant::now() >= self.deadline {
            return Err(CoreError::ApprovalExpired);
        }
        if self.run.settings().mode != Mode::Agent
            && self.command.safety != ToolSafetyLevel::SafeReadOnly
        {
            return Err(CoreError::Rejected);
        }
        self.command.revalidate(&self.run)
    }
}

/// One owner-scoped approval ledger. No hash/UUID by itself authorizes a command.
#[derive(Default)]
pub struct ExecutionGate {
    pending: HashMap<ApprovalId, PendingApproval>,
}
struct CommandAdmission<'a> {
    registry: &'a ToolRegistry,
    requested: &'a ToolName,
    call_id: ToolCallId,
    step_id: Option<ToolStepId>,
    command: CommandSpec,
}
impl ExecutionGate {
    /// Validate typed arguments/owner/mode/budget before requesting user approval.
    pub fn prepare(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        registry: &ToolRegistry,
        requested: &ToolName,
        call_id: ToolCallId,
        command: CommandSpec,
    ) -> Result<ApprovalRequest, CoreError> {
        self.prepare_command(
            actor,
            run,
            CommandAdmission {
                registry,
                requested,
                call_id,
                step_id: None,
                command,
            },
        )
    }
    pub(crate) fn prepare_step(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        requested: &ToolName,
        parent: ToolCallId,
        step: ToolStepId,
        command: CommandSpec,
    ) -> Result<ApprovalRequest, CoreError> {
        self.prepare_command(
            actor,
            run,
            CommandAdmission {
                registry: run.tool_registry(),
                requested,
                call_id: parent,
                step_id: Some(step),
                command,
            },
        )
    }
    fn prepare_command(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        input: CommandAdmission<'_>,
    ) -> Result<ApprovalRequest, CoreError> {
        let CommandAdmission {
            registry,
            requested,
            call_id,
            step_id,
            command,
        } = input;
        actor.validate(run)?;
        let descriptor = registry.resolve(requested)?;
        if command.isolated_patch.is_some() && descriptor.name().as_str() != "edit_patch_prepare" {
            return Err(CoreError::Rejected);
        }
        if descriptor.safety() != command.safety
            || (run.settings().mode != Mode::Agent
                && descriptor.safety() != ToolSafetyLevel::SafeReadOnly)
        {
            return Err(CoreError::Rejected);
        }
        if self.pending.len() >= limits::MAX_PENDING {
            return Err(CoreError::Limit);
        }
        command.revalidate(run)?;
        let action_digest = digest(run, descriptor.name(), &command)?;
        let deadline = run.deadline().cap(
            Instant::now()
                .checked_add(timeouts::APPROVAL)
                .ok_or(CoreError::ArithmeticOverflow)?,
        );
        let lease = run.lease()?;
        if let Some(step) = &step_id {
            actor.claim_step(run, &call_id, step, descriptor.name(), descriptor.safety())?;
        } else {
            actor.reserve_call(
                run,
                call_id.clone(),
                descriptor.name().clone(),
                descriptor.safety(),
            )?;
        }
        let id = ApprovalId::new();
        let request = ApprovalRequest {
            safety: descriptor.safety(),
            retention: command.capture.retention(),
            stdout_records: command.capture.records(),
            stop_on_bytes: command.capture.stop_on_bytes(),
            success_codes: command.success_codes,
            output_limit: command.output_limit,
            timeout: command.timeout,
            idle_timeout: command.idle_timeout,
            stderr: command.stderr,
            id: id.clone(),
            scope: run.scope().clone(),
            digest: action_digest.clone(),
            deadline,
            name: descriptor.name().clone(),
            program: command.program.clone(),
            invocation: command.invocation.clone(),
            arguments: command.arguments.clone(),
            cwd: command.cwd.path().to_path_buf(),
            environment: command.environment.clone(),
        };
        self.pending.insert(
            id,
            PendingApproval {
                run: run.clone(),
                call_id,
                step_id,
                name: descriptor.name().clone(),
                action: CapturedAction::Command(Box::new(command)),
                digest: action_digest,
                deadline,
                lease,
            },
        );
        Ok(request)
    }
    /// Consume only a matching owner's exact review. Replay, expiry and rejection fail closed.
    pub fn decide(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        request: &ApprovalRequest,
        decision: UserDecision,
    ) -> Result<AuthorizedCommand, CoreError> {
        actor.validate(run)?;
        let pending = self
            .pending
            .get(request.id())
            .ok_or(CoreError::ApprovalUnavailable)?;
        if !pending.run.same_owner(run)
            || pending.digest != request.digest
            || &request.scope != run.scope()
        {
            return Err(CoreError::StaleOwner);
        }
        if !matches!(pending.action, CapturedAction::Command(_)) {
            return Err(CoreError::Rejected);
        }
        let pending = self
            .pending
            .remove(request.id())
            .ok_or(CoreError::ApprovalUnavailable)?;
        let CapturedAction::Command(command) = pending.action else {
            return Err(CoreError::Rejected);
        };
        let validation = if Instant::now() >= pending.deadline {
            Err(CoreError::ApprovalExpired)
        } else if decision == UserDecision::Rejected {
            Err(CoreError::Rejected)
        } else {
            command.revalidate(run)
        };
        if let Err(error) = validation {
            let outcome = if matches!(error, CoreError::ApprovalExpired) {
                ToolOutcome::Timeout
            } else {
                ToolOutcome::Rejected
            };
            actor.complete_action(run, &pending.call_id, pending.step_id.as_ref(), outcome)?;
            return Err(error);
        }
        // Recompute from private captured data, never caller-supplied display text.
        if digest(run, &pending.name, &command)? != pending.digest {
            return Err(CoreError::Rejected);
        }
        Ok(AuthorizedCommand {
            run: pending.run,
            call_id: pending.call_id,
            step_id: pending.step_id,
            command: *command,
            lease: pending.lease,
            deadline: pending.deadline,
        })
    }
    /// Remove cancelled/expired requests for this run, releasing its resource leases.
    pub fn dismiss_run(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
    ) -> Result<(), CoreError> {
        self.dismiss_with(actor, run, ToolOutcome::Cancelled)
    }
    pub(crate) fn timeout_run(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
    ) -> Result<(), CoreError> {
        self.dismiss_with(actor, run, ToolOutcome::Timeout)
    }
    fn dismiss_with(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
        outcome: ToolOutcome,
    ) -> Result<(), CoreError> {
        actor.validate_owner(run)?;
        let ids: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, p)| p.run.same_owner(run))
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            if let Some(pending) = self.pending.remove(&id) {
                actor.complete_action(
                    run,
                    &pending.call_id,
                    pending.step_id.as_ref(),
                    if Instant::now() >= pending.deadline {
                        ToolOutcome::Timeout
                    } else {
                        outcome
                    },
                )?;
            }
        }
        Ok(())
    }
    /// Sweep only this owner's expired/revoked approvals on the controller timer.
    pub fn expire(
        &mut self,
        actor: &mut ApplicationActor,
        run: &RunHandle,
    ) -> Result<(), CoreError> {
        actor.validate_owner(run)?;
        let now = Instant::now();
        let ids: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, p)| {
                p.run.same_owner(run) && (now >= p.deadline || run.check_live().is_err())
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            if let Some(pending) = self.pending.remove(&id) {
                let outcome = if now >= pending.deadline {
                    ToolOutcome::Timeout
                } else {
                    ToolOutcome::Cancelled
                };
                actor.complete_action(run, &pending.call_id, pending.step_id.as_ref(), outcome)?;
            }
        }
        Ok(())
    }
    /// Number of owned requests still awaiting a decision.
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }
}

impl CommandSpec {
    /// The `cwd` field.
    pub(crate) fn cwd(&self) -> &Workspace {
        &self.cwd
    }
    /// The `timeout` field.
    pub(crate) fn timeout(&self) -> &ExecutionTimeout {
        &self.timeout
    }
}

impl CommandSpec {
    /// The `capture` field.
    pub(crate) fn capture(&self) -> CapturePolicy {
        self.capture
    }
}
