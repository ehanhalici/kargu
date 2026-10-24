//! Immutable command capture, explicit tool policy and single-use approval grants.
//!
//! Path identity checks are revalidation evidence, not an OS shell sandbox.

use crate::{
    application::{ApplicationActor, Mode, RunHandle, RunLease, RunScope, ToolOutcome},
    constants::{limits, timeouts},
    domain::*,
    error::CoreError,
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

/// Pinned directory identity used by settings and commands.
#[derive(Clone)]
pub struct Workspace {
    path: PathBuf,
    directory: Arc<File>,
}
impl TryFrom<PathBuf> for Workspace {
    type Error = CoreError;
    fn try_from(path: PathBuf) -> Result<Self, CoreError> {
        use nix::fcntl::{OFlag, open};
        use nix::sys::stat::Mode as FileMode;
        let path = path.canonicalize()?;
        // O_DIRECTORY rejects FIFOs/devices before opening for IO; O_NOFOLLOW
        // also rejects replacement of the canonical root with a symlink.
        let directory = open(
            &path,
            OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
            FileMode::empty(),
        )
        .map_err(std::io::Error::from)?;
        Ok(Self {
            path,
            directory: Arc::new(File::from(directory)),
        })
    }
}
impl Workspace {
    /// Canonical captured directory; no fallback to the process cwd.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Compare current path identity to the held directory, before side effects.
    pub fn revalidate(&self) -> Result<(), CoreError> {
        let held = self.directory.metadata()?;
        let current = self
            .path
            .metadata()
            .map_err(|_| CoreError::WorkspaceChanged)?;
        if !current.is_dir()
            || held.dev() != current.dev()
            || held.ino() != current.ino()
            || self
                .path
                .canonicalize()
                .map_err(|_| CoreError::WorkspaceChanged)?
                != self.path
        {
            return Err(CoreError::WorkspaceChanged);
        }
        Ok(())
    }
}

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
    safety: ToolSafetyLevel,
    pub(crate) invocation: PathBuf,
    pub(crate) program: PathBuf,
    pub(crate) arguments: Vec<OsString>,
    pub(crate) cwd: Workspace,
    pub(crate) timeout: ExecutionTimeout,
    pub(crate) retention: OutputRetention,
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
            safety: ToolSafetyLevel::ExecutesArbitraryCode,
            invocation: input.program,
            program,
            arguments: input.arguments,
            cwd: Workspace::try_from(input.working_directory)?,
            timeout,
            retention: OutputRetention::Prefix,
            revision: ExecutableRevision::from(&metadata),
            executable,
            environment: input.environment,
        })
    }
}
impl CommandSpec {
    /// Capture output retention before approval; it is included in the action digest.
    pub fn with_retention(mut self, retention: OutputRetention) -> Self {
        self.retention = retention;
        self
    }
    /// Only the trusted fixed-argv listing adapter can request this class.
    pub(crate) fn directory_listing(input: CommandInput) -> Result<Self, CoreError> {
        let mut command = Self::try_from(input)?;
        command.safety = ToolSafetyLevel::SafeReadOnly;
        Ok(command)
    }
    fn revalidate(&self, run: &RunHandle) -> Result<(), CoreError> {
        run.check_live()?;
        run.settings().workspace.revalidate()?;
        self.cwd.revalidate()?;
        if !self.cwd.path.starts_with(run.settings().workspace.path()) {
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

/// Canonical tool metadata; callers cannot relabel a general program as read-only.
pub struct ToolDescriptor {
    name: ToolName,
    safety: ToolSafetyLevel,
}
impl ToolDescriptor {
    /// Canonical name after alias resolution.
    pub fn name(&self) -> &ToolName {
        &self.name
    }
    /// Actual executor's effect class.
    pub fn safety(&self) -> ToolSafetyLevel {
        self.safety
    }
}

/// Explicit application-owned definitions and flattened aliases. No global registry.
#[derive(Default)]
pub struct ToolRegistry {
    definitions: HashMap<ToolName, ToolDescriptor>,
    aliases: HashMap<ToolName, ToolName>,
}
impl ToolRegistry {
    /// Register a process executor atomically. Every process is arbitrary code.
    pub fn register_process(
        &mut self,
        name: ToolName,
        aliases: Vec<ToolName>,
    ) -> Result<(), CoreError> {
        self.register(name, aliases, ToolSafetyLevel::ExecutesArbitraryCode)
    }
    pub(crate) fn register_listing(&mut self) -> Result<(), CoreError> {
        self.register(
            ToolName::try_from("list_files".to_owned())?,
            vec![],
            ToolSafetyLevel::SafeReadOnly,
        )
    }
    fn register(
        &mut self,
        name: ToolName,
        aliases: Vec<ToolName>,
        safety: ToolSafetyLevel,
    ) -> Result<(), CoreError> {
        if self.aliases.contains_key(&name)
            || aliases.iter().any(|alias| {
                alias != &name
                    && (self.definitions.contains_key(alias)
                        || self
                            .aliases
                            .get(alias)
                            .is_some_and(|target| target != &name))
            })
        {
            return Err(CoreError::Rejected);
        }
        self.definitions.insert(
            name.clone(),
            ToolDescriptor {
                name: name.clone(),
                safety,
            },
        );
        for alias in aliases {
            if alias != name {
                self.aliases.insert(alias, name.clone());
            }
        }
        Ok(())
    }
    /// Resolve aliases to current definitions, never an old metadata snapshot.
    pub fn resolve(&self, name: &ToolName) -> Result<&ToolDescriptor, CoreError> {
        self.definitions
            .get(self.aliases.get(name).unwrap_or(name))
            .ok_or(CoreError::Unavailable)
    }
}

/// SHA-256 of owner, revisions, canonical tool, executable identity, cwd and argv.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActionDigest([u8; 32]);
fn digest(
    run: &RunHandle,
    name: &ToolName,
    command: &CommandSpec,
) -> Result<ActionDigest, CoreError> {
    let mut hash = Sha256::new();
    hash.update(b"kargu-command-v1");
    let scope = serde_json::to_vec(run.scope())
        .map_err(|_| CoreError::InvalidValue { field: "RunScope" })?;
    for bytes in [
        scope.as_slice(),
        name.as_str().as_bytes(),
        command.program.as_os_str().as_bytes(),
        command.invocation.as_os_str().as_bytes(),
        command.cwd.path().as_os_str().as_bytes(),
    ] {
        hash.update(
            u64::try_from(bytes.len())
                .map_err(|_| CoreError::ArithmeticOverflow)?
                .to_le_bytes(),
        );
        hash.update(bytes);
    }
    hash.update(
        u64::try_from(command.arguments.len())
            .map_err(|_| CoreError::ArithmeticOverflow)?
            .to_le_bytes(),
    );
    for arg in &command.arguments {
        let bytes = arg.as_os_str().as_bytes();
        hash.update(
            u64::try_from(bytes.len())
                .map_err(|_| CoreError::ArithmeticOverflow)?
                .to_le_bytes(),
        );
        hash.update(bytes);
    }
    hash.update(
        u64::try_from(command.environment.0.len())
            .map_err(|_| CoreError::ArithmeticOverflow)?
            .to_le_bytes(),
    );
    for (key, value) in command.environment.entries() {
        for bytes in [key.as_os_str().as_bytes(), value.as_os_str().as_bytes()] {
            hash.update(
                u64::try_from(bytes.len())
                    .map_err(|_| CoreError::ArithmeticOverflow)?
                    .to_le_bytes(),
            );
            hash.update(bytes);
        }
    }
    for metadata in [
        command.executable.metadata()?,
        command.cwd.directory.metadata()?,
    ] {
        hash.update(metadata.dev().to_le_bytes());
        hash.update(metadata.ino().to_le_bytes());
    }
    if let Some(duration) = command.timeout.duration() {
        hash.update([1]);
        hash.update(duration.as_nanos().to_le_bytes());
    } else {
        hash.update([0]);
    }
    hash.update([match command.retention {
        OutputRetention::Prefix => 0,
        OutputRetention::Tail => 1,
    }]);
    Ok(ActionDigest(hash.finalize().into()))
}

/// UI decision; missing UI must use Rejected, never Approved.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UserDecision {
    /// Exact captured action was approved.
    Approved,
    /// User or missing UI denied the action.
    Rejected,
}

/// Immutable review data; command text is accessible only through explicit getters.
pub struct ApprovalRequest {
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

struct PendingApproval {
    run: RunHandle,
    call_id: ToolCallId,
    name: ToolName,
    command: CommandSpec,
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
    command: CommandSpec,
    lease: RunLease,
    deadline: Instant,
}
pub(crate) struct ApprovedParts {
    pub(crate) run: RunHandle,
    pub(crate) call_id: ToolCallId,
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
    pub(crate) fn command(&self) -> &CommandSpec {
        &self.command
    }
    pub(crate) fn into_parts(self) -> ApprovedParts {
        ApprovedParts {
            run: self.run,
            call_id: self.call_id,
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
        actor.validate(run)?;
        let descriptor = registry.resolve(requested)?;
        if descriptor.safety != command.safety
            || (run.settings().mode != Mode::Agent
                && descriptor.safety != ToolSafetyLevel::SafeReadOnly)
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
        actor.register_call(run, call_id.clone(), descriptor.name().clone())?;
        let id = ApprovalId::new();
        let request = ApprovalRequest {
            id: id.clone(),
            scope: run.scope().clone(),
            digest: action_digest.clone(),
            deadline,
            name: descriptor.name().clone(),
            program: command.program.clone(),
            invocation: command.invocation.clone(),
            arguments: command.arguments.clone(),
            cwd: command.cwd.path.clone(),
            environment: command.environment.clone(),
        };
        self.pending.insert(
            id,
            PendingApproval {
                run: run.clone(),
                call_id,
                name: descriptor.name().clone(),
                command,
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
        let pending = self
            .pending
            .remove(request.id())
            .ok_or(CoreError::ApprovalUnavailable)?;
        let validation = if Instant::now() >= pending.deadline {
            Err(CoreError::ApprovalExpired)
        } else if decision == UserDecision::Rejected {
            Err(CoreError::Rejected)
        } else {
            pending.command.revalidate(run)
        };
        if let Err(error) = validation {
            let outcome = if matches!(error, CoreError::ApprovalExpired) {
                ToolOutcome::Timeout
            } else {
                ToolOutcome::Rejected
            };
            actor.complete_tool(run, &pending.call_id, outcome)?;
            return Err(error);
        }
        // Recompute from private captured data, never caller-supplied display text.
        if digest(run, &pending.name, &pending.command)? != pending.digest {
            return Err(CoreError::Rejected);
        }
        Ok(AuthorizedCommand {
            run: pending.run,
            call_id: pending.call_id,
            command: pending.command,
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
        actor.validate_owner(run)?;
        let ids: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, p)| p.run.same_owner(run))
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            if let Some(pending) = self.pending.remove(&id) {
                actor.complete_tool(
                    run,
                    &pending.call_id,
                    if Instant::now() >= pending.deadline {
                        ToolOutcome::Timeout
                    } else {
                        ToolOutcome::Cancelled
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
                actor.complete_tool(run, &pending.call_id, outcome)?;
            }
        }
        Ok(())
    }
    /// Number of owned requests still awaiting a decision.
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }
}
