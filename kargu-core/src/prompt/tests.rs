use super::*;
use crate::{
    domain::{ConfigRevision, SessionId},
    models::store::MetadataRevision,
};
use std::{
    fs,
    time::{Duration, Instant},
};
use tempfile::tempdir;

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn default_asset_has_stable_revision() {
    let set1 = InstructionSet::new();
    let set2 = InstructionSet::new();
    let asm1 = set1.assemble();
    let asm2 = set2.assemble();
    assert_eq!(asm1.revision(), asm2.revision());
    assert!(!asm1.text().is_empty());
    assert_eq!(asm1.project_presence(), ProjectInstructionPresence::Absent);
    assert_eq!(asm1.untrusted_count().get(), 0);
}

#[test]
fn project_instruction_changes_revision() {
    let base = InstructionSet::new().assemble();
    let meta = InstructionMetadata::new(SourceHash::new([1u8; 32]), InstructionSize::new(26));
    let pi = ProjectInstruction::new(
        InstructionFilename::new("AGENTS.md".to_owned()),
        InstructionText::new("Follow architecture rules.".to_owned()),
        meta,
    );
    let with_proj = InstructionSet::new()
        .with_project_instruction(Some(pi))
        .assemble();
    assert_ne!(base.revision(), with_proj.revision());
    assert_eq!(
        with_proj.project_presence(),
        ProjectInstructionPresence::Present
    );
    assert_eq!(with_proj.untrusted_count().get(), 1);
    assert!(
        with_proj
            .text()
            .as_str()
            .contains("Instructions from: AGENTS.md")
    );
    assert!(
        with_proj
            .text()
            .as_str()
            .contains("Follow architecture rules.")
    );
}

#[test]
fn content_change_changes_revision() {
    let meta1 = InstructionMetadata::new(SourceHash::new([1u8; 32]), InstructionSize::new(6));
    let pi1 = ProjectInstruction::new(
        InstructionFilename::new("AGENTS.md".to_owned()),
        InstructionText::new("Rule A".to_owned()),
        meta1,
    );
    let meta2 = InstructionMetadata::new(SourceHash::new([2u8; 32]), InstructionSize::new(6));
    let pi2 = ProjectInstruction::new(
        InstructionFilename::new("AGENTS.md".to_owned()),
        InstructionText::new("Rule B".to_owned()),
        meta2,
    );
    let asm1 = InstructionSet::new()
        .with_project_instruction(Some(pi1))
        .assemble();
    let asm2 = InstructionSet::new()
        .with_project_instruction(Some(pi2))
        .assemble();
    assert_ne!(asm1.revision(), asm2.revision());
}

#[test]
fn filename_change_changes_revision() {
    let meta = InstructionMetadata::new(SourceHash::new([1u8; 32]), InstructionSize::new(9));
    let pi1 = ProjectInstruction::new(
        InstructionFilename::new("AGENTS.md".to_owned()),
        InstructionText::new("Same rule".to_owned()),
        meta,
    );
    let pi2 = ProjectInstruction::new(
        InstructionFilename::new("CLAUDE.md".to_owned()),
        InstructionText::new("Same rule".to_owned()),
        meta,
    );
    let asm1 = InstructionSet::new()
        .with_project_instruction(Some(pi1))
        .assemble();
    let asm2 = InstructionSet::new()
        .with_project_instruction(Some(pi2))
        .assemble();
    assert_ne!(asm1.revision(), asm2.revision());
}

#[test]
fn mode_overlay_changes_revision_and_text() {
    let ask = InstructionSet::new()
        .with_mode_overlay(Some(ModeOverlay::Ask))
        .assemble();
    let agent = InstructionSet::new()
        .with_mode_overlay(Some(ModeOverlay::Agent))
        .assemble();
    assert_ne!(ask.revision(), agent.revision());
    assert!(ask.text().as_str().contains("Mode: ASK"));
    assert!(agent.text().as_str().contains("Mode: AGENT"));
}

#[test]
fn precedence_ordering_preserved() -> TestResult {
    let meta = InstructionMetadata::new(SourceHash::new([1u8; 32]), InstructionSize::new(20));
    let pi = ProjectInstruction::new(
        InstructionFilename::new("AGENTS.md".to_owned()),
        InstructionText::new("PROJECT_INSTRUCTIONS".to_owned()),
        meta,
    );
    let assembled = InstructionSet::new()
        .with_default_asset(Some(InstructionText::new("BASE_ASSET".to_owned())))
        .with_project_instruction(Some(pi))
        .with_user_override(Some(InstructionText::new("USER_OVERRIDE".to_owned())))
        .with_model_specific(Some(InstructionText::new("MODEL_SPECIFIC".to_owned())))
        .with_mode_overlay(Some(ModeOverlay::Debug))
        .with_editor_text(Some(InstructionText::new("EDITOR_RAW".to_owned())))
        .assemble();

    let text = assembled.text().as_str();
    let pos_base = text.find("BASE_ASSET").ok_or("missing BASE_ASSET")?;
    let pos_proj = text
        .find("PROJECT_INSTRUCTIONS")
        .ok_or("missing PROJECT_INSTRUCTIONS")?;
    let pos_user = text.find("USER_OVERRIDE").ok_or("missing USER_OVERRIDE")?;
    let pos_model = text
        .find("MODEL_SPECIFIC")
        .ok_or("missing MODEL_SPECIFIC")?;
    let pos_mode = text.find("Mode: DEBUG").ok_or("missing Mode: DEBUG")?;
    let pos_editor = text.find("EDITOR_RAW").ok_or("missing EDITOR_RAW")?;

    assert!(pos_base < pos_proj);
    assert!(pos_proj < pos_user);
    assert!(pos_user < pos_model);
    assert!(pos_model < pos_mode);
    assert!(pos_mode < pos_editor);
    Ok(())
}

#[test]
fn trust_levels_and_elevation_invariants() {
    assert_eq!(
        InstructionTrust::Project.trust_verdict(),
        TrustVerdict::Untrusted
    );
    assert_eq!(
        InstructionTrust::Model.trust_verdict(),
        TrustVerdict::Untrusted
    );
    assert_eq!(
        InstructionTrust::System.trust_verdict(),
        TrustVerdict::Trusted
    );
    assert_eq!(
        InstructionTrust::User.trust_verdict(),
        TrustVerdict::Trusted
    );

    assert_eq!(
        InstructionTrust::Project.privilege_elevation(),
        PrivilegeElevation::Forbidden
    );
    assert_eq!(
        InstructionTrust::Model.privilege_elevation(),
        PrivilegeElevation::Forbidden
    );
    assert_eq!(
        InstructionTrust::System.privilege_elevation(),
        PrivilegeElevation::Forbidden
    );
    assert_eq!(
        InstructionTrust::User.privilege_elevation(),
        PrivilegeElevation::Forbidden
    );
}

#[test]
fn capture_reads_candidate_file_in_order() -> TestResult {
    let dir = tempdir()?;
    let claude = dir.path().join("CLAUDE.md");
    let agents = dir.path().join("AGENTS.md");
    fs::write(&claude, "Claude instructions")?;
    fs::write(&agents, "Agents instructions")?;

    let root = InstructionWorkspaceRoot::new(dir.path().to_path_buf());
    let candidates = CandidateInstructionFiles::default_candidates();
    let limit = InstructionByteLimit::new(1000);
    let captured = capture_project_instruction(&root, &candidates, limit)?
        .ok_or("missing captured instruction")?;

    assert_eq!(captured.filename().as_str(), "AGENTS.md");
    assert_eq!(captured.content().as_str(), "Agents instructions");
    assert_eq!(captured.size().get(), 19);
    Ok(())
}

#[test]
fn capture_oversize_file_returns_error() -> TestResult {
    let dir = tempdir()?;
    let agents = dir.path().join("AGENTS.md");
    fs::write(&agents, "123456789012345")?;

    let root = InstructionWorkspaceRoot::new(dir.path().to_path_buf());
    let candidates = CandidateInstructionFiles::default_candidates();
    let limit = InstructionByteLimit::new(10);
    let result = capture_project_instruction(&root, &candidates, limit);
    assert_eq!(
        result,
        Err(InstructionError::Oversize {
            size: InstructionSize::new(15),
            limit
        })
    );
    Ok(())
}

#[test]
fn capture_missing_returns_none() -> TestResult {
    let dir = tempdir()?;
    let root = InstructionWorkspaceRoot::new(dir.path().to_path_buf());
    let candidates = CandidateInstructionFiles::default_candidates();
    let limit = InstructionByteLimit::new(1000);
    let result = capture_project_instruction(&root, &candidates, limit);
    assert_eq!(result, Ok(None));
    Ok(())
}

fn sample_environment() -> EnvironmentSnapshot {
    let ws = WorkspaceContext::new(
        WorkspaceRootPath::new("/workspace/kargu".to_owned()),
        GitSnapshot::new(
            GitRepoStatus::Repo,
            Some(GitBranchName::new("main".to_owned())),
        ),
        Some(ContextFileName::new("src/main.rs".to_owned())),
    );
    let platform = PlatformSnapshot::new(
        SystemInfo::new(
            PlatformName::new("linux (x86_64)".to_owned()),
            ShellPath::new("/bin/bash".to_owned()),
        ),
        SessionInfo::new(
            IsoDate::new("2026-11-08".to_owned()),
            EditorInfo::new("GNU Emacs 29.4".to_owned()),
        ),
    );
    let toolchain = ToolchainSnapshot::new(
        ToolchainIdentity::new(
            Some(LanguageName::new("rust".to_owned())),
            Some(ToolchainNotes::new("cargo workspace".to_owned())),
        ),
        ToolchainCommands::new(
            Some(ToolchainCommand::new("cargo build".to_owned())),
            Some(ToolchainCommand::new("cargo test".to_owned())),
        ),
        LspStatus::Connected,
    );
    EnvironmentSnapshot::new(ws, platform, toolchain)
}

fn sample_capabilities(
    tools: ToolsPolicy,
    usage: UsagePolicy,
    mode: ModeOverlay,
) -> CapabilitySnapshot {
    let policies = PoliciesSnapshot::new(tools, usage, mode);
    let advertised = vec![
        AdvertisedTool::new(
            ToolGuidanceName::new("read_file".to_owned()),
            ToolGuidanceDescription::new("Read file contents".to_owned()),
        ),
        AdvertisedTool::new(
            ToolGuidanceName::new("bash".to_owned()),
            ToolGuidanceDescription::new("Run shell commands".to_owned()),
        ),
    ];
    let skills = Some(SkillsCatalogContent::new(
        "<skills>\n  <skill>\n    <name>test-skill</name>\n  </skill>\n</skills>".to_owned(),
    ));
    let tooling = ToolingSnapshot::new(ModelName::new("test-model".to_owned()), advertised, skills);
    CapabilitySnapshot::new(policies, tooling)
}

#[test]
fn frozen_input_produces_identical_system_prompt() {
    let instructions = InstructionSet::new().assemble();
    let env = sample_environment();
    let caps = sample_capabilities(
        ToolsPolicy::Enabled,
        UsagePolicy::Normal,
        ModeOverlay::Agent,
    );

    let prompt1 = compose_system_prompt(&instructions, &env, &caps);
    let prompt2 = compose_system_prompt(&instructions, &env, &caps);

    assert_eq!(prompt1, prompt2);
    assert!(
        prompt1
            .as_str()
            .contains("You are powered by the model named test-model.")
    );
    assert!(prompt1.as_str().contains("<runtime_environment>"));
    assert!(prompt1.as_str().contains("Mode: AGENT"));
}

#[test]
fn tools_off_omits_tools_guidance_and_skills() {
    let instructions = InstructionSet::new().assemble();
    let env = sample_environment();
    let caps = sample_capabilities(ToolsPolicy::Disabled, UsagePolicy::Normal, ModeOverlay::Ask);

    let prompt = compose_system_prompt(&instructions, &env, &caps);

    assert!(!prompt.as_str().contains("<available_tools_guidance>"));
    assert!(!prompt.as_str().contains("<skills>"));
    assert!(prompt.as_str().contains("Mode: ASK"));

    let reminder = ModeReminder::for_turn(ModeOverlay::Ask, ToolsPolicy::Disabled);
    assert!(
        reminder
            .as_str()
            .contains("This model cannot call tools. Answer in plain text.")
    );
}

#[test]
fn tools_enabled_includes_tools_guidance_and_skills() {
    let instructions = InstructionSet::new().assemble();
    let env = sample_environment();
    let caps = sample_capabilities(
        ToolsPolicy::Enabled,
        UsagePolicy::Normal,
        ModeOverlay::Agent,
    );

    let prompt = compose_system_prompt(&instructions, &env, &caps);

    assert!(prompt.as_str().contains("<available_tools_guidance>"));
    assert!(
        prompt
            .as_str()
            .contains("- `read_file`: Read file contents")
    );
    assert!(prompt.as_str().contains("- `bash`: Run shell commands"));
    assert!(prompt.as_str().contains("<skills>"));
    assert!(prompt.as_str().contains("<name>test-skill</name>"));

    let reminder = ModeReminder::for_turn(ModeOverlay::Agent, ToolsPolicy::Enabled);
    assert!(
        reminder
            .as_str()
            .contains("Mode: AGENT. Make surgical edits")
    );
}

#[test]
fn low_usage_policy_adds_guidance_note() {
    let instructions = InstructionSet::new().assemble();
    let env = sample_environment();
    let caps = sample_capabilities(
        ToolsPolicy::Enabled,
        UsagePolicy::LowUsage,
        ModeOverlay::Debug,
    );

    let prompt = compose_system_prompt(&instructions, &env, &caps);

    assert!(
        prompt
            .as_str()
            .contains("Low usage mode: use targeted searches")
    );
}

#[test]
fn mode_overlays_and_reminders_differ() {
    let ask_rem = ModeReminder::for_turn(ModeOverlay::Ask, ToolsPolicy::Enabled);
    let plan_rem = ModeReminder::for_turn(ModeOverlay::Plan, ToolsPolicy::Enabled);
    let debug_rem = ModeReminder::for_turn(ModeOverlay::Debug, ToolsPolicy::Enabled);
    let agent_rem = ModeReminder::for_turn(ModeOverlay::Agent, ToolsPolicy::Enabled);
    let compact_rem = ModeReminder::for_turn(ModeOverlay::Compaction, ToolsPolicy::Enabled);

    assert!(ask_rem.as_str().contains("Mode: ASK (read-only)"));
    assert!(plan_rem.as_str().contains("Mode: PLAN (read-only)"));
    assert!(debug_rem.as_str().contains("Mode: DEBUG"));
    assert!(agent_rem.as_str().contains("Mode: AGENT"));
    assert!(compact_rem.as_str().contains("Mode: COMPACTION"));
}

#[test]
fn unicode_and_special_paths_preserved() {
    let ws = WorkspaceContext::new(
        WorkspaceRootPath::new("/workspace/pröject_ñame".to_owned()),
        GitSnapshot::new(
            GitRepoStatus::Repo,
            Some(GitBranchName::new("feat/ünicøde".to_owned())),
        ),
        Some(ContextFileName::new("src/üñicøde.rs".to_owned())),
    );
    let platform = PlatformSnapshot::new(
        SystemInfo::new(
            PlatformName::new("linux (x86_64)".to_owned()),
            ShellPath::new("/bin/zsh".to_owned()),
        ),
        SessionInfo::new(
            IsoDate::new("2026-11-08".to_owned()),
            EditorInfo::new("GNU Emacs 29.4".to_owned()),
        ),
    );
    let toolchain = ToolchainSnapshot::new(
        ToolchainIdentity::new(None, None),
        ToolchainCommands::new(None, None),
        LspStatus::Unavailable,
    );
    let env = EnvironmentSnapshot::new(ws, platform, toolchain);
    let caps = sample_capabilities(ToolsPolicy::Enabled, UsagePolicy::Normal, ModeOverlay::Plan);
    let instructions = InstructionSet::new().assemble();

    let prompt = compose_system_prompt(&instructions, &env, &caps);
    assert!(prompt.as_str().contains("/workspace/pröject_ñame"));
    assert!(prompt.as_str().contains("feat/ünicøde"));
    assert!(prompt.as_str().contains("src/üñicøde.rs"));
    assert!(
        prompt
            .as_str()
            .contains("Language: Not automatically detected")
    );
    assert!(prompt.as_str().contains("Flymake / LSP: Unavailable"));
}

fn sample_cache_key(mode: ModeOverlay, inst_rev: &str, session: SessionId) -> PromptCacheKey {
    let root = WorkspaceRootPath::new("/workspace/kargu".to_owned());
    let scope = CacheSessionScope::new(session, root, mode);
    let content = ContentRevisions::new(
        InstructionRevision::new(inst_rev.to_owned()),
        ContextRevision::new("ctx_hash_1".to_owned()),
    );
    let revisions = CacheRevisions::new(ConfigRevision::ZERO, MetadataRevision::default(), content);
    PromptCacheKey::new(scope, revisions, ToolsPolicy::Enabled)
}

fn sample_limits(entries: usize, bytes: usize, secs: u64) -> PromptCacheLimits {
    PromptCacheLimits::new(
        CacheEntryLimit::new(entries),
        CacheByteLimit::new(bytes),
        Duration::from_secs(secs),
    )
}

#[test]
fn cache_hit_on_matching_key_before_ttl() {
    let limits = sample_limits(10, 10_000, 5);
    let mut cache = NativePromptCache::new(limits);
    let key = sample_cache_key(ModeOverlay::Agent, "rev_a", SessionId::new());
    let text = InstructionText::new("System prompt body A".to_owned());
    let now = Instant::now();

    cache.insert(CacheInsertion::new(key.clone(), text.clone()), now);

    let retrieved = cache.get(&key, now);
    assert_eq!(retrieved, Some(text));
    assert_eq!(cache.entry_count().get(), 1);
}

#[test]
fn cache_miss_on_instruction_revision_change() {
    let limits = sample_limits(10, 10_000, 5);
    let mut cache = NativePromptCache::new(limits);
    let session = SessionId::new();
    let key1 = sample_cache_key(ModeOverlay::Agent, "rev_a", session.clone());
    let key2 = sample_cache_key(ModeOverlay::Agent, "rev_b", session);
    let text = InstructionText::new("System prompt body A".to_owned());
    let now = Instant::now();

    cache.insert(CacheInsertion::new(key1, text), now);

    assert_eq!(cache.get(&key2, now), None);
}

#[test]
fn cache_miss_on_mode_change() {
    let limits = sample_limits(10, 10_000, 5);
    let mut cache = NativePromptCache::new(limits);
    let session = SessionId::new();
    let key_agent = sample_cache_key(ModeOverlay::Agent, "rev_a", session.clone());
    let key_ask = sample_cache_key(ModeOverlay::Ask, "rev_a", session);
    let text = InstructionText::new("System prompt body A".to_owned());
    let now = Instant::now();

    cache.insert(CacheInsertion::new(key_agent, text), now);

    assert_eq!(cache.get(&key_ask, now), None);
}

#[test]
fn cache_miss_on_ttl_expiration() {
    let limits = sample_limits(10, 10_000, 5);
    let mut cache = NativePromptCache::new(limits);
    let key = sample_cache_key(ModeOverlay::Agent, "rev_a", SessionId::new());
    let text = InstructionText::new("System prompt body A".to_owned());
    let t0 = Instant::now();
    let t_expired = t0 + Duration::from_secs(6);

    cache.insert(CacheInsertion::new(key.clone(), text), t0);

    assert_eq!(cache.get(&key, t_expired), None);
    assert_eq!(cache.entry_count().get(), 0);
}

#[test]
fn cache_invalidation_by_session_and_workspace() {
    let limits = sample_limits(10, 10_000, 10);
    let mut cache = NativePromptCache::new(limits);
    let s1 = SessionId::new();
    let s2 = SessionId::new();
    let key_s1 = sample_cache_key(ModeOverlay::Agent, "rev_a", s1.clone());
    let key_s2 = sample_cache_key(ModeOverlay::Agent, "rev_a", s2.clone());
    let now = Instant::now();

    cache.insert(
        CacheInsertion::new(key_s1.clone(), InstructionText::new("P1".to_owned())),
        now,
    );
    cache.insert(
        CacheInsertion::new(key_s2.clone(), InstructionText::new("P2".to_owned())),
        now,
    );
    assert_eq!(cache.entry_count().get(), 2);

    cache.invalidate_session(&s1);
    assert_eq!(cache.get(&key_s1, now), None);
    assert!(cache.get(&key_s2, now).is_some());
    assert_eq!(cache.entry_count().get(), 1);

    cache.invalidate_workspace(&WorkspaceRootPath::new("/workspace/kargu".to_owned()));
    assert_eq!(cache.entry_count().get(), 0);
}

#[test]
fn cache_capacity_eviction_strictly_bounds_entries_and_bytes() {
    let limits = sample_limits(2, 30, 60);
    let mut cache = NativePromptCache::new(limits);
    let k1 = sample_cache_key(ModeOverlay::Agent, "r1", SessionId::new());
    let k2 = sample_cache_key(ModeOverlay::Agent, "r2", SessionId::new());
    let k3 = sample_cache_key(ModeOverlay::Agent, "r3", SessionId::new());
    let now = Instant::now();

    cache.insert(
        CacheInsertion::new(k1.clone(), InstructionText::new("1234567890".to_owned())), // 10 bytes
        now,
    );
    cache.insert(
        CacheInsertion::new(k2.clone(), InstructionText::new("1234567890".to_owned())), // 10 bytes
        now,
    );
    assert_eq!(cache.entry_count().get(), 2);

    // Third entry forces eviction of oldest (k1)
    cache.insert(
        CacheInsertion::new(k3.clone(), InstructionText::new("1234567890".to_owned())), // 10 bytes
        now,
    );
    assert_eq!(cache.entry_count().get(), 2);
    assert_eq!(cache.get(&k1, now), None); // k1 was evicted
    assert!(cache.get(&k2, now).is_some());
    assert!(cache.get(&k3, now).is_some());
    assert!(cache.byte_size().get() <= 30);
}
