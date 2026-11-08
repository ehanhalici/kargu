//! Instruction source inventory, precedence, trust boundaries and revision tracking.

use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Maximum bytes allowed for an injected project instruction file.
pub const DEFAULT_MAX_INSTRUCTION_BYTES: usize = 20_000;

/// Newtype for workspace root directory.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstructionWorkspaceRoot(PathBuf);

impl InstructionWorkspaceRoot {
    /// Create new workspace root.
    pub fn new(path: PathBuf) -> Self {
        Self(path)
    }

    /// Access inner path.
    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

/// Newtype for candidate filenames list.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CandidateInstructionFiles(Vec<InstructionFilename>);

impl CandidateInstructionFiles {
    /// Standard candidate list ("AGENTS.md", "CLAUDE.md", "CONTEXT.md").
    pub fn default_candidates() -> Self {
        Self(vec![
            InstructionFilename::new("AGENTS.md".to_owned()),
            InstructionFilename::new("CLAUDE.md".to_owned()),
            InstructionFilename::new("CONTEXT.md".to_owned()),
        ])
    }

    /// Custom candidate list.
    pub fn custom(names: Vec<InstructionFilename>) -> Self {
        Self(names)
    }

    /// Iterate over candidates.
    pub fn iter(&self) -> impl Iterator<Item = &InstructionFilename> {
        self.0.iter()
    }
}

/// Newtype for instruction text.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstructionText(String);

impl InstructionText {
    /// Create new instruction text.
    pub fn new(text: String) -> Self {
        Self(text)
    }

    /// Access the text as a string slice.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Number of bytes in the instruction text.
    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// True if instruction text is empty.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

/// Newtype for instruction filename.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstructionFilename(String);

impl InstructionFilename {
    /// Create new instruction filename.
    pub fn new(name: String) -> Self {
        Self(name)
    }

    /// Access filename as a string slice.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// SHA-256 hash of instruction source content.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SourceHash([u8; 32]);

impl SourceHash {
    /// Create hash from raw 32-byte digest.
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    /// Return raw bytes of the hash.
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

/// Newtype for byte limit on instruction reading.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InstructionByteLimit(usize);

impl InstructionByteLimit {
    /// Create a byte limit from usize.
    pub fn new(limit: usize) -> Self {
        Self(limit)
    }

    /// Limit value in bytes.
    pub fn get(&self) -> usize {
        self.0
    }
}

/// Newtype for instruction size in bytes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InstructionSize(usize);

impl InstructionSize {
    /// Create size from usize.
    pub fn new(size: usize) -> Self {
        Self(size)
    }

    /// Size in bytes.
    pub fn get(&self) -> usize {
        self.0
    }
}

/// Metadata for captured instruction source (hash commitment and size).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InstructionMetadata {
    hash: SourceHash,
    size: InstructionSize,
}

impl InstructionMetadata {
    /// Construct instruction metadata.
    pub const fn new(hash: SourceHash, size: InstructionSize) -> Self {
        Self { hash, size }
    }

    /// Access source hash.
    pub const fn hash(&self) -> &SourceHash {
        &self.hash
    }

    /// Access byte size.
    pub const fn size(&self) -> InstructionSize {
        self.size
    }
}

/// Newtype for untrusted instruction count.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct UntrustedCount(usize);

impl UntrustedCount {
    /// Construct untrusted count.
    pub const fn new(value: usize) -> Self {
        Self(value)
    }

    /// Inner count value.
    pub const fn get(self) -> usize {
        self.0
    }
}

/// Verdict on whether an instruction source is trusted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TrustVerdict {
    /// Trusted source (system default or explicit user config).
    Trusted,
    /// Untrusted source (project file, model output, or unvetted text).
    Untrusted,
}

/// Decision on privilege elevation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrivilegeElevation {
    /// Elevation permitted.
    Permitted,
    /// Elevation forbidden.
    Forbidden,
}

/// Indicator for presence of project instruction file.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectInstructionPresence {
    /// Project instruction file is present.
    Present,
    /// Project instruction file is absent.
    Absent,
}

/// Unique revision computed from instruction sources and their contents.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstructionRevision(String);

impl InstructionRevision {
    /// Create revision from hex string.
    pub fn new(hex: String) -> Self {
        Self(hex)
    }

    /// Access revision as string slice.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Trust origin of an instruction block.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InstructionTrust {
    /// Built-in static prompt asset (trusted).
    System,
    /// Explicit user configuration override (trusted).
    User,
    /// Project instruction file such as AGENTS.md (untrusted content).
    Project,
    /// Model or provider specific guidance (untrusted for permission elevation).
    Model,
    /// Raw explicit editor text primitive.
    Editor,
}

impl InstructionTrust {
    /// Trust verdict for this instruction tier.
    pub const fn trust_verdict(&self) -> TrustVerdict {
        match self {
            Self::System | Self::User => TrustVerdict::Trusted,
            Self::Project | Self::Model | Self::Editor => TrustVerdict::Untrusted,
        }
    }

    /// Privilege elevation policy for this tier.
    pub const fn privilege_elevation(&self) -> PrivilegeElevation {
        PrivilegeElevation::Forbidden
    }
}

/// Explicit error categories for instruction reading and resolution.
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum InstructionError {
    /// Candidate instruction file not found.
    #[error("instruction file not found")]
    NotFound,
    /// File size exceeds bounded limit.
    #[error("instruction file size exceeds limit")]
    Oversize {
        /// Actual file size in bytes.
        size: InstructionSize,
        /// Maximum permitted bytes.
        limit: InstructionByteLimit,
    },
    /// I/O read failure with message.
    #[error("instruction read error: {0}")]
    ReadError(String),
    /// File path resolves outside workspace root.
    #[error("instruction path escapes workspace root")]
    PathEscape,
    /// File contains non-UTF8 bytes.
    #[error("instruction file is not valid UTF-8")]
    InvalidUtf8,
    /// Attempt to elevate untrusted instruction to execution privilege.
    #[error("untrusted instruction elevation rejected")]
    UntrustedElevation,
}

/// Mode overlay for system prompt.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModeOverlay {
    /// Ask mode (read-only analysis).
    Ask,
    /// Plan mode (implementation checklist).
    Plan,
    /// Debug mode (runtime and DAP evidence).
    Debug,
    /// Agent mode (surgical editing and testing).
    Agent,
    /// Compaction mode (history summary turn).
    Compaction,
}

impl ModeOverlay {
    /// Return canonical guidance text for this mode as an instruction text.
    pub fn prompt_instruction(&self) -> InstructionText {
        InstructionText::new(
            match self {
                Self::Ask => "Mode: ASK (read-only). Analyze and explain. Do not edit files.",
                Self::Plan => {
                    "Mode: PLAN (read-only). Explore, then output a markdown implementation checklist. Do not edit files."
                }
                Self::Debug => {
                    "Mode: DEBUG. Ground answers in DAP/runtime evidence and diagnostics. Do not edit unless asked."
                }
                Self::Agent => {
                    "Mode: AGENT. Inspect, edit surgically, verify with available diagnostics, and run project compiler/tests."
                }
                Self::Compaction => "Mode: COMPACTION. Summarize the conversation history concisely.",
            }
            .to_owned(),
        )
    }
}

/// Validated project instruction captured from workspace.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectInstruction {
    filename: InstructionFilename,
    content: InstructionText,
    metadata: InstructionMetadata,
}

impl ProjectInstruction {
    /// Construct a validated project instruction.
    pub fn new(
        filename: InstructionFilename,
        content: InstructionText,
        metadata: InstructionMetadata,
    ) -> Self {
        Self {
            filename,
            content,
            metadata,
        }
    }

    /// Filename of the instruction source.
    pub fn filename(&self) -> &InstructionFilename {
        &self.filename
    }

    /// Text content of the instruction source.
    pub fn content(&self) -> &InstructionText {
        &self.content
    }

    /// Content hash of the instruction source.
    pub fn hash(&self) -> &SourceHash {
        self.metadata.hash()
    }

    /// Size in bytes of the instruction source.
    pub fn size(&self) -> InstructionSize {
        self.metadata.size()
    }
}

/// One instruction source in the precedence chain.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InstructionSource {
    /// Default built-in base asset.
    DefaultAsset(InstructionText),
    /// Project instruction file (AGENTS.md, etc.).
    ProjectFile(ProjectInstruction),
    /// User explicit configuration override.
    UserOverride(InstructionText),
    /// Model or provider specific instructions.
    ModelSpecific(InstructionText),
    /// Mode-specific system prompt paragraph.
    ModeOverlay(ModeOverlay),
    /// Explicit editor raw text primitive.
    EditorText(InstructionText),
}

impl InstructionSource {
    /// Return the trust origin of this instruction source.
    pub fn trust_level(&self) -> InstructionTrust {
        match self {
            Self::DefaultAsset(_) => InstructionTrust::System,
            Self::UserOverride(_) => InstructionTrust::User,
            Self::ProjectFile(_) => InstructionTrust::Project,
            Self::ModelSpecific(_) => InstructionTrust::Model,
            Self::ModeOverlay(_) => InstructionTrust::System,
            Self::EditorText(_) => InstructionTrust::Editor,
        }
    }

    /// Return the formatted text block for this source.
    pub fn text_block(&self) -> InstructionText {
        match self {
            Self::DefaultAsset(text) => text.clone(),
            Self::ProjectFile(pi) => InstructionText::new(format!(
                "Instructions from: {}\n{}",
                pi.filename().as_str(),
                pi.content().as_str()
            )),
            Self::UserOverride(text) => text.clone(),
            Self::ModelSpecific(text) => text.clone(),
            Self::ModeOverlay(mode) => mode.prompt_instruction(),
            Self::EditorText(text) => text.clone(),
        }
    }
}

/// Fully assembled instructions with canonical text and computed revision.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssembledInstructions {
    text: InstructionText,
    revision: InstructionRevision,
    has_project_file: bool,
    untrusted_count: usize,
}

impl AssembledInstructions {
    /// Full canonical prompt text.
    pub fn text(&self) -> &InstructionText {
        &self.text
    }

    /// Computed revision hash.
    pub fn revision(&self) -> &InstructionRevision {
        &self.revision
    }

    /// Indicator for presence of project instruction file.
    pub fn project_presence(&self) -> ProjectInstructionPresence {
        if self.has_project_file {
            ProjectInstructionPresence::Present
        } else {
            ProjectInstructionPresence::Absent
        }
    }

    /// Count of untrusted source blocks included.
    pub fn untrusted_count(&self) -> UntrustedCount {
        UntrustedCount::new(self.untrusted_count)
    }
}

/// Builder for ordered instruction sources respecting canonical precedence:
/// 1. DefaultAsset
/// 2. ProjectFile
/// 3. UserOverride
/// 4. ModelSpecific
/// 5. ModeOverlay
/// 6. EditorText
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct InstructionSet {
    default_asset: Option<InstructionText>,
    project_file: Option<ProjectInstruction>,
    user_override: Option<InstructionText>,
    model_specific: Option<InstructionText>,
    mode_overlay: Option<ModeOverlay>,
    editor_text: Option<InstructionText>,
}

impl InstructionSet {
    /// Create empty instruction set.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set default base asset (defaults to crate constants).
    pub fn with_default_asset(mut self, asset: Option<InstructionText>) -> Self {
        self.default_asset = asset;
        self
    }

    /// Set project instruction file.
    pub fn with_project_instruction(mut self, pi: Option<ProjectInstruction>) -> Self {
        self.project_file = pi;
        self
    }

    /// Set user explicit override.
    pub fn with_user_override(mut self, override_text: Option<InstructionText>) -> Self {
        self.user_override = override_text;
        self
    }

    /// Set model/provider specific instructions.
    pub fn with_model_specific(mut self, model_text: Option<InstructionText>) -> Self {
        self.model_specific = model_text;
        self
    }

    /// Set mode overlay.
    pub fn with_mode_overlay(mut self, mode: Option<ModeOverlay>) -> Self {
        self.mode_overlay = mode;
        self
    }

    /// Set explicit editor text primitive.
    pub fn with_editor_text(mut self, text: Option<InstructionText>) -> Self {
        self.editor_text = text;
        self
    }

    /// Collect sources in precedence order.
    fn collect_ordered_sources(&self) -> Vec<InstructionSource> {
        let mut sources = Vec::new();
        let base = self.default_asset.clone().unwrap_or_else(|| {
            InstructionText::new(crate::constants::DEFAULT_SYSTEM_PROMPT.trim().to_owned())
        });
        sources.push(InstructionSource::DefaultAsset(base));
        if let Some(ref pi) = self.project_file {
            sources.push(InstructionSource::ProjectFile(pi.clone()));
        }
        if let Some(ref uo) = self.user_override {
            sources.push(InstructionSource::UserOverride(uo.clone()));
        }
        if let Some(ref ms) = self.model_specific {
            sources.push(InstructionSource::ModelSpecific(ms.clone()));
        }
        if let Some(mode) = self.mode_overlay {
            sources.push(InstructionSource::ModeOverlay(mode));
        }
        if let Some(ref et) = self.editor_text {
            sources.push(InstructionSource::EditorText(et.clone()));
        }
        sources
    }

    /// Assemble canonical text and calculate revision.
    pub fn assemble(&self) -> AssembledInstructions {
        let sources = self.collect_ordered_sources();
        let mut hasher = Sha256::new();
        let mut blocks = Vec::with_capacity(sources.len());
        let mut untrusted_count: usize = 0;
        let mut has_project_file = false;

        for src in &sources {
            if matches!(src.trust_level().trust_verdict(), TrustVerdict::Untrusted) {
                untrusted_count = untrusted_count.saturating_add(1);
            }
            if matches!(src, InstructionSource::ProjectFile(_)) {
                has_project_file = true;
            }
            let block = src.text_block();
            hasher.update((block.len() as u64).to_le_bytes());
            hasher.update(block.as_str().as_bytes());
            blocks.push(block.as_str().to_owned());
        }

        let combined = blocks.join("\n\n");
        let hash_hex = format!("{:x}", hasher.finalize());

        AssembledInstructions {
            text: InstructionText::new(combined),
            revision: InstructionRevision::new(hash_hex),
            has_project_file,
            untrusted_count,
        }
    }
}
