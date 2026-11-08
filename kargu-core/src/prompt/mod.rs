//! Prompt and instruction composition module.

pub mod cache;
pub mod capture;
pub mod context;
pub mod instruction;

#[cfg(test)]
mod tests;

pub use cache::{
    CacheByteLimit, CacheByteSize, CacheEntryCount, CacheEntryLimit, CacheInsertion,
    CacheRevisions, CacheSessionScope, ContentRevisions, ContextRevision, NativePromptCache,
    PromptCacheKey, PromptCacheLimits,
};
pub use capture::capture_project_instruction;
pub use context::{
    AdvertisedTool, CapabilitySnapshot, ContextFileName, EditorInfo, EnvironmentSnapshot,
    GitBranchName, GitRepoStatus, GitSnapshot, IsoDate, LanguageName, LspStatus, ModeReminder,
    ModelName, PlatformName, PlatformSnapshot, PoliciesSnapshot, SessionInfo, ShellPath,
    SkillsCatalogContent, SystemInfo, ToolGuidanceDescription, ToolGuidanceName, ToolchainCommand,
    ToolchainCommands, ToolchainIdentity, ToolchainNotes, ToolchainSnapshot, ToolingSnapshot,
    ToolsPolicy, UsagePolicy, WorkspaceContext, WorkspaceRootPath, compose_system_prompt,
};
pub use instruction::{
    AssembledInstructions, CandidateInstructionFiles, DEFAULT_MAX_INSTRUCTION_BYTES,
    InstructionByteLimit, InstructionError, InstructionFilename, InstructionMetadata,
    InstructionRevision, InstructionSet, InstructionSize, InstructionSource, InstructionText,
    InstructionTrust, InstructionWorkspaceRoot, ModeOverlay, PrivilegeElevation,
    ProjectInstruction, ProjectInstructionPresence, SourceHash, TrustVerdict, UntrustedCount,
};
