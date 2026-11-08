//! Environment snapshot, capability guidance and mode reminder composition.

use super::instruction::{AssembledInstructions, InstructionText, ModeOverlay};

/// Newtype for workspace root path string.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceRootPath(String);

impl WorkspaceRootPath {
    /// Create new workspace root path.
    pub fn new(path: String) -> Self {
        Self(path)
    }

    /// Access path string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newtype for Git branch name.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GitBranchName(String);

impl GitBranchName {
    /// Create new branch name.
    pub fn new(name: String) -> Self {
        Self(name)
    }

    /// Access branch name string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Whether directory is a Git repository.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GitRepoStatus {
    /// Directory is inside a Git repository.
    Repo,
    /// Directory is not a Git repository.
    NotRepo,
}

impl GitRepoStatus {
    /// Canonical presentation string ("yes" or "no").
    const fn as_str(self) -> &'static str {
        match self {
            Self::Repo => "yes",
            Self::NotRepo => "no",
        }
    }
}

/// Git status snapshot for workspace.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GitSnapshot {
    repo_status: GitRepoStatus,
    branch: Option<GitBranchName>,
}

impl GitSnapshot {
    /// Create new Git snapshot.
    pub fn new(repo_status: GitRepoStatus, branch: Option<GitBranchName>) -> Self {
        Self {
            repo_status,
            branch,
        }
    }

    /// Return repo status.
    pub fn repo_status(&self) -> GitRepoStatus {
        self.repo_status
    }

    /// Return branch name if available.
    pub fn branch(&self) -> Option<&GitBranchName> {
        self.branch.as_ref()
    }
}

/// Newtype for platform OS / architecture name.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlatformName(String);

impl PlatformName {
    /// Create new platform name.
    pub fn new(name: String) -> Self {
        Self(name)
    }

    /// Access platform string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newtype for shell executable path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ShellPath(String);

impl ShellPath {
    /// Create new shell path.
    pub fn new(path: String) -> Self {
        Self(path)
    }

    /// Access shell path string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newtype for ISO 8601 date string (YYYY-MM-DD).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IsoDate(String);

impl IsoDate {
    /// Create new date string.
    pub fn new(date: String) -> Self {
        Self(date)
    }

    /// Access date string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newtype for editor host identifier.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EditorInfo(String);

impl EditorInfo {
    /// Create new editor info.
    pub fn new(info: String) -> Self {
        Self(info)
    }

    /// Access editor string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// System host information (OS platform and shell).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SystemInfo {
    platform: PlatformName,
    shell: ShellPath,
}

impl SystemInfo {
    /// Construct system info record.
    pub fn new(platform: PlatformName, shell: ShellPath) -> Self {
        Self { platform, shell }
    }

    /// Platform name.
    pub fn platform(&self) -> &PlatformName {
        &self.platform
    }

    /// Shell path.
    pub fn shell(&self) -> &ShellPath {
        &self.shell
    }
}

/// Session host information (date and editor).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionInfo {
    date: IsoDate,
    editor: EditorInfo,
}

impl SessionInfo {
    /// Construct session info record.
    pub fn new(date: IsoDate, editor: EditorInfo) -> Self {
        Self { date, editor }
    }

    /// Today's date string.
    pub fn date(&self) -> &IsoDate {
        &self.date
    }

    /// Editor version string.
    pub fn editor(&self) -> &EditorInfo {
        &self.editor
    }
}

/// Platform and host snapshot.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlatformSnapshot {
    system: SystemInfo,
    session: SessionInfo,
}

impl PlatformSnapshot {
    /// Construct platform snapshot.
    pub fn new(system: SystemInfo, session: SessionInfo) -> Self {
        Self { system, session }
    }

    /// Access system info.
    pub fn system(&self) -> &SystemInfo {
        &self.system
    }

    /// Access session info.
    pub fn session(&self) -> &SessionInfo {
        &self.session
    }
}

/// Newtype for context file path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextFileName(String);

impl ContextFileName {
    /// Create new context file name.
    pub fn new(name: String) -> Self {
        Self(name)
    }

    /// Access context file string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newtype for toolchain language name.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LanguageName(String);

impl LanguageName {
    /// Create new language name.
    pub fn new(name: String) -> Self {
        Self(name)
    }

    /// Access language name.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newtype for build or test command string.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolchainCommand(String);

impl ToolchainCommand {
    /// Create new toolchain command.
    pub fn new(cmd: String) -> Self {
        Self(cmd)
    }

    /// Access command string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newtype for toolchain notes string.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolchainNotes(String);

impl ToolchainNotes {
    /// Create new toolchain notes.
    pub fn new(notes: String) -> Self {
        Self(notes)
    }

    /// Access notes string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Language identity and optional notes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolchainIdentity {
    language: Option<LanguageName>,
    notes: Option<ToolchainNotes>,
}

impl ToolchainIdentity {
    /// Construct toolchain identity.
    pub fn new(language: Option<LanguageName>, notes: Option<ToolchainNotes>) -> Self {
        Self { language, notes }
    }

    /// Primary detected language.
    pub fn language(&self) -> Option<&LanguageName> {
        self.language.as_ref()
    }

    /// Notes if any.
    pub fn notes(&self) -> Option<&ToolchainNotes> {
        self.notes.as_ref()
    }
}

/// Build and test command set.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolchainCommands {
    build_cmd: Option<ToolchainCommand>,
    test_cmd: Option<ToolchainCommand>,
}

impl ToolchainCommands {
    /// Construct toolchain command set.
    pub fn new(build_cmd: Option<ToolchainCommand>, test_cmd: Option<ToolchainCommand>) -> Self {
        Self {
            build_cmd,
            test_cmd,
        }
    }

    /// Build / compiler command.
    pub fn build_cmd(&self) -> Option<&ToolchainCommand> {
        self.build_cmd.as_ref()
    }

    /// Test runner command.
    pub fn test_cmd(&self) -> Option<&ToolchainCommand> {
        self.test_cmd.as_ref()
    }
}

/// LSP / Flymake connection status.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LspStatus {
    /// LSP server is actively connected.
    Connected,
    /// LSP server is unavailable.
    Unavailable,
}

impl LspStatus {
    /// Return the canonical LSP guidance line.
    const fn guidance_line(self) -> &'static str {
        match self {
            Self::Connected => "  Flymake / LSP: Connected; request diagnostics explicitly.\n",
            Self::Unavailable => {
                "  Flymake / LSP: Unavailable; use available file/search tools and project tests.\n"
            }
        }
    }
}

/// Toolchain detection snapshot.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolchainSnapshot {
    identity: ToolchainIdentity,
    commands: ToolchainCommands,
    lsp_status: LspStatus,
}

impl ToolchainSnapshot {
    /// Construct toolchain snapshot.
    pub fn new(
        identity: ToolchainIdentity,
        commands: ToolchainCommands,
        lsp_status: LspStatus,
    ) -> Self {
        Self {
            identity,
            commands,
            lsp_status,
        }
    }

    /// Detected identity.
    pub fn identity(&self) -> &ToolchainIdentity {
        &self.identity
    }

    /// Build/test commands.
    pub fn commands(&self) -> &ToolchainCommands {
        &self.commands
    }

    /// LSP status.
    pub fn lsp_status(&self) -> LspStatus {
        self.lsp_status
    }
}

/// Workspace root, Git status and context file.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceContext {
    root: WorkspaceRootPath,
    git: GitSnapshot,
    context_file: Option<ContextFileName>,
}

impl WorkspaceContext {
    /// Construct workspace context.
    pub fn new(
        root: WorkspaceRootPath,
        git: GitSnapshot,
        context_file: Option<ContextFileName>,
    ) -> Self {
        Self {
            root,
            git,
            context_file,
        }
    }

    /// Root directory.
    pub fn root(&self) -> &WorkspaceRootPath {
        &self.root
    }

    /// Git snapshot.
    pub fn git(&self) -> &GitSnapshot {
        &self.git
    }

    /// Optional context buffer/file name.
    pub fn context_file(&self) -> Option<&ContextFileName> {
        self.context_file.as_ref()
    }
}

/// Complete environment snapshot.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EnvironmentSnapshot {
    workspace: WorkspaceContext,
    platform: PlatformSnapshot,
    toolchain: ToolchainSnapshot,
}

impl EnvironmentSnapshot {
    /// Construct complete environment snapshot.
    pub fn new(
        workspace: WorkspaceContext,
        platform: PlatformSnapshot,
        toolchain: ToolchainSnapshot,
    ) -> Self {
        Self {
            workspace,
            platform,
            toolchain,
        }
    }

    /// Workspace context.
    pub fn workspace(&self) -> &WorkspaceContext {
        &self.workspace
    }

    /// Platform snapshot.
    pub fn platform(&self) -> &PlatformSnapshot {
        &self.platform
    }

    /// Toolchain snapshot.
    pub fn toolchain(&self) -> &ToolchainSnapshot {
        &self.toolchain
    }
}

/// Policy for whether tools may be executed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ToolsPolicy {
    /// Tools are enabled for this request.
    Enabled,
    /// Tools are disabled (plain text response only).
    Disabled,
}

/// Policy for low-usage search / reading mode.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UsagePolicy {
    /// Normal tool operation.
    Normal,
    /// Low usage mode active.
    LowUsage,
}

/// Mode and execution policy settings.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PoliciesSnapshot {
    tools: ToolsPolicy,
    usage: UsagePolicy,
    mode: ModeOverlay,
}

impl PoliciesSnapshot {
    /// Construct policies snapshot.
    pub fn new(tools: ToolsPolicy, usage: UsagePolicy, mode: ModeOverlay) -> Self {
        Self { tools, usage, mode }
    }

    /// Tools permission policy.
    pub fn tools(&self) -> ToolsPolicy {
        self.tools
    }

    /// Usage budget policy.
    pub fn usage(&self) -> UsagePolicy {
        self.usage
    }

    /// Mode overlay.
    pub fn mode(&self) -> ModeOverlay {
        self.mode
    }
}

/// Newtype for model name.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelName(String);

impl ModelName {
    /// Create new model name.
    pub fn new(name: String) -> Self {
        Self(name)
    }

    /// Access model name string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newtype for tool guidance name.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolGuidanceName(String);

impl ToolGuidanceName {
    /// Create new tool guidance name.
    pub fn new(name: String) -> Self {
        Self(name)
    }

    /// Access tool name string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newtype for tool guidance description.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolGuidanceDescription(String);

impl ToolGuidanceDescription {
    /// Create new tool description.
    pub fn new(desc: String) -> Self {
        Self(desc)
    }

    /// Access tool description string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// One advertised tool descriptor.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdvertisedTool {
    name: ToolGuidanceName,
    description: ToolGuidanceDescription,
}

impl AdvertisedTool {
    /// Create new advertised tool descriptor.
    pub fn new(name: ToolGuidanceName, description: ToolGuidanceDescription) -> Self {
        Self { name, description }
    }

    /// Tool name.
    pub fn name(&self) -> &ToolGuidanceName {
        &self.name
    }

    /// Tool description.
    pub fn description(&self) -> &ToolGuidanceDescription {
        &self.description
    }
}

/// Newtype for rendered XML skills catalog.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkillsCatalogContent(String);

impl SkillsCatalogContent {
    /// Create skills catalog content.
    pub fn new(content: String) -> Self {
        Self(content)
    }

    /// Access catalog text.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Tooling, skills, and model identification.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolingSnapshot {
    model: ModelName,
    tools: Vec<AdvertisedTool>,
    skills: Option<SkillsCatalogContent>,
}

impl ToolingSnapshot {
    /// Construct tooling snapshot.
    pub fn new(
        model: ModelName,
        tools: Vec<AdvertisedTool>,
        skills: Option<SkillsCatalogContent>,
    ) -> Self {
        Self {
            model,
            tools,
            skills,
        }
    }

    /// Model name.
    pub fn model(&self) -> &ModelName {
        &self.model
    }

    /// Advertised tools list.
    pub fn tools(&self) -> &[AdvertisedTool] {
        &self.tools
    }

    /// Skills catalog if available.
    pub fn skills(&self) -> Option<&SkillsCatalogContent> {
        self.skills.as_ref()
    }
}

/// Complete capability and policy snapshot.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapabilitySnapshot {
    policies: PoliciesSnapshot,
    tooling: ToolingSnapshot,
}

impl CapabilitySnapshot {
    /// Construct capability snapshot.
    pub fn new(policies: PoliciesSnapshot, tooling: ToolingSnapshot) -> Self {
        Self { policies, tooling }
    }

    /// Policies snapshot.
    pub fn policies(&self) -> &PoliciesSnapshot {
        &self.policies
    }

    /// Tooling snapshot.
    pub fn tooling(&self) -> &ToolingSnapshot {
        &self.tooling
    }
}

fn format_toolchain_block(tc: &ToolchainSnapshot) -> String {
    let mut out = String::from("<project_toolchain>\n");
    let lang = tc
        .identity()
        .language()
        .map_or("Not automatically detected", |l| l.as_str());
    out.push_str(&format!("  Language: {}\n", lang));
    if let Some(cmd) = tc.commands().build_cmd() {
        out.push_str(&format!("  Build / Compiler: {}\n", cmd.as_str()));
    }
    if let Some(cmd) = tc.commands().test_cmd() {
        out.push_str(&format!("  Test command: {}\n", cmd.as_str()));
    }
    if let Some(notes) = tc.identity().notes() {
        out.push_str(&format!("  Notes: {}\n", notes.as_str()));
    }
    out.push_str(tc.lsp_status().guidance_line());
    out.push_str("  Execution: In agent mode, use `bash' to run build and test commands.\n");
    out.push_str("  Verification Rule: Always verify that tests pass and no compile errors remain before concluding your work.\n");
    out.push_str("</project_toolchain>\n");
    out
}

fn format_env_block(env: &EnvironmentSnapshot, mode_name: &str, model_name: &ModelName) -> String {
    let branch = env
        .workspace()
        .git()
        .branch()
        .map_or("(none)", |b| b.as_str());
    let ctx = env
        .workspace()
        .context_file()
        .map_or("(none)", |c| c.as_str());
    format!(
        "You are powered by the model named {}.\n\
         Here is some useful information about the environment you are running in:\n\
         <env>\n  Working directory: {}\n  Workspace root folder: {}\n  Is directory a git repo: {}\n  Platform: {}\n  Today's date: {}\n  Emacs: {}\n  Shell: {}\n  Git Branch: {}\n  Context file: {}\n  Mode: {}\n</env>\n\n",
        model_name.as_str(),
        env.workspace().root().as_str(),
        env.workspace().root().as_str(),
        env.workspace().git().repo_status().as_str(),
        env.platform().system().platform().as_str(),
        env.platform().session().date().as_str(),
        env.platform().session().editor().as_str(),
        env.platform().system().shell().as_str(),
        branch,
        ctx,
        mode_name,
    )
}

fn format_tools_guidance(caps: &CapabilitySnapshot) -> Option<String> {
    if matches!(caps.policies().tools(), ToolsPolicy::Disabled) {
        return None;
    }
    let mut out = String::from("<available_tools_guidance>\n");
    out.push_str("You can call MULTIPLE tools in one turn; execution is sequential.\n");
    out.push_str("Search first; read only relevant line ranges. Use structural tools when available. Verify edits with available diagnostics and tests.\n");
    if matches!(caps.policies().usage(), UsagePolicy::LowUsage) {
        out.push_str("Low usage mode: use targeted searches, small line ranges and concise results. Do not repeat unchanged file reads or request whole-project dumps.\n");
    }
    for tool in caps.tooling().tools() {
        out.push_str(&format!(
            "- `{}`: {}\n",
            tool.name().as_str(),
            tool.description().as_str()
        ));
    }
    out.push_str("</available_tools_guidance>");
    Some(out)
}

fn format_runtime_environment(env: &EnvironmentSnapshot, caps: &CapabilitySnapshot) -> String {
    let mode_str = match caps.policies().mode() {
        ModeOverlay::Ask => "ask",
        ModeOverlay::Plan => "plan",
        ModeOverlay::Debug => "debug",
        ModeOverlay::Agent => "agent",
        ModeOverlay::Compaction => "compaction",
    };
    let env_block = format_env_block(env, mode_str, caps.tooling().model());
    let tc_block = format_toolchain_block(env.toolchain());
    format!(
        "<runtime_environment>\n{}{}</runtime_environment>",
        env_block, tc_block
    )
}

/// Mode reminder factory for user conversation turns.
pub struct ModeReminder;

impl ModeReminder {
    /// Return the canonical system-reminder tag for this mode and tools policy.
    pub fn for_turn(mode: ModeOverlay, tools: ToolsPolicy) -> InstructionText {
        if matches!(tools, ToolsPolicy::Disabled) {
            return InstructionText::new(
                "<system-reminder>\nThis model cannot call tools. Answer in plain text. Do not invent function-call markup.\n</system-reminder>".to_owned()
            );
        }
        let reminder = match mode {
            ModeOverlay::Ask => {
                "<system-reminder>\nMode: ASK (read-only). Answer the question or analyze the code. Do not propose edits, create files, or run commands that modify the project.\n</system-reminder>"
            }
            ModeOverlay::Plan => {
                "<system-reminder>\nMode: PLAN (read-only). Explore the codebase and design an implementation approach. End your turn by printing a numbered or bulleted plan. Do not execute changes yet.\n</system-reminder>"
            }
            ModeOverlay::Debug => {
                "<system-reminder>\nMode: DEBUG. Reproduce or observe the issue before changing code. Look at compiler output, runtime logs, or DAP state. Only propose changes once the root cause is confirmed.\n</system-reminder>"
            }
            ModeOverlay::Agent => {
                "<system-reminder>\nMode: AGENT. Make surgical edits to fulfill the user's request. Verify all changes with available diagnostics and compiler/test runs. Stop when done; do not over-engineer.\n</system-reminder>"
            }
            ModeOverlay::Compaction => {
                "<system-reminder>\nMode: COMPACTION. Summarize the conversation history concisely.\n</system-reminder>"
            }
        };
        InstructionText::new(reminder.to_owned())
    }
}

/// Assemble the complete canonical system prompt from instruction, environment and capability snapshots.
pub fn compose_system_prompt(
    instructions: &AssembledInstructions,
    env: &EnvironmentSnapshot,
    caps: &CapabilitySnapshot,
) -> InstructionText {
    let mut parts = Vec::new();
    parts.push(instructions.text().as_str().to_owned());
    if let (ToolsPolicy::Enabled, Some(catalog)) =
        (caps.policies().tools(), caps.tooling().skills())
    {
        parts.push(catalog.as_str().to_owned());
    }
    parts.push(
        caps.policies()
            .mode()
            .prompt_instruction()
            .as_str()
            .to_owned(),
    );
    if let Some(guidance) = format_tools_guidance(caps) {
        parts.push(guidance);
    }
    let runtime_block = format_runtime_environment(env, caps);
    parts.push(runtime_block);
    InstructionText::new(parts.join("\n\n"))
}
