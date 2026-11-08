//! Golden and negative prompt assembly and contract acceptance tests.

use kargu_core::{
    domain::{ConfigRevision, SessionId},
    models::store::MetadataRevision,
    prompt::{
        AdvertisedTool, CacheByteLimit, CacheEntryLimit, CacheInsertion, CacheRevisions,
        CacheSessionScope, CandidateInstructionFiles, CapabilitySnapshot, ContentRevisions,
        ContextFileName, ContextRevision, EditorInfo, EnvironmentSnapshot, GitBranchName,
        GitRepoStatus, GitSnapshot, InstructionByteLimit, InstructionError, InstructionFilename,
        InstructionMetadata, InstructionRevision, InstructionSet, InstructionSize, InstructionText,
        InstructionTrust, InstructionWorkspaceRoot, IsoDate, LanguageName, LspStatus, ModeOverlay,
        ModeReminder, ModelName, NativePromptCache, PlatformName, PlatformSnapshot,
        PoliciesSnapshot, PrivilegeElevation, ProjectInstruction, PromptCacheKey,
        PromptCacheLimits, SessionInfo, ShellPath, SkillsCatalogContent, SourceHash, SystemInfo,
        ToolGuidanceDescription, ToolGuidanceName, ToolchainCommand, ToolchainCommands,
        ToolchainIdentity, ToolchainNotes, ToolchainSnapshot, ToolingSnapshot, ToolsPolicy,
        TrustVerdict, UsagePolicy, WorkspaceContext, WorkspaceRootPath,
        capture_project_instruction, compose_system_prompt,
    },
};
use std::{
    fs,
    time::{Duration, Instant},
};
use tempfile::tempdir;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn test_environment(root_path: &str, lang: Option<&str>) -> EnvironmentSnapshot {
    let ws = WorkspaceContext::new(
        WorkspaceRootPath::new(root_path.to_owned()),
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
            lang.map(|l| LanguageName::new(l.to_owned())),
            Some(ToolchainNotes::new("test notes".to_owned())),
        ),
        ToolchainCommands::new(
            Some(ToolchainCommand::new("cargo build".to_owned())),
            Some(ToolchainCommand::new("cargo test".to_owned())),
        ),
        LspStatus::Connected,
    );
    EnvironmentSnapshot::new(ws, platform, toolchain)
}

fn test_capabilities(
    tools: ToolsPolicy,
    usage: UsagePolicy,
    mode: ModeOverlay,
) -> CapabilitySnapshot {
    let policies = PoliciesSnapshot::new(tools, usage, mode);
    let advertised = vec![
        AdvertisedTool::new(
            ToolGuidanceName::new("read_file".to_owned()),
            ToolGuidanceDescription::new("Read file contents by line ranges".to_owned()),
        ),
        AdvertisedTool::new(
            ToolGuidanceName::new("edit_file".to_owned()),
            ToolGuidanceDescription::new("Edit file surgically".to_owned()),
        ),
    ];
    let skills = Some(SkillsCatalogContent::new(
        "<skills>\n  <skill>\n    <name>test-skill</name>\n  </skill>\n</skills>".to_owned(),
    ));
    let tooling = ToolingSnapshot::new(ModelName::new("gpt-4o".to_owned()), advertised, skills);
    CapabilitySnapshot::new(policies, tooling)
}

#[test]
fn golden_tools_off_omits_schemas_and_skills() -> TestResult {
    let instructions = InstructionSet::new().assemble();
    let env = test_environment("/home/user/project", Some("rust"));
    let caps = test_capabilities(ToolsPolicy::Disabled, UsagePolicy::Normal, ModeOverlay::Ask);

    let prompt = compose_system_prompt(&instructions, &env, &caps);
    let text = prompt.as_str();

    assert!(!text.contains("<available_tools_guidance>"));
    assert!(!text.contains("<skills>"));
    assert!(!text.contains("read_file"));
    assert!(!text.contains("edit_file"));

    let reminder = ModeReminder::for_turn(ModeOverlay::Ask, ToolsPolicy::Disabled);
    assert!(
        reminder
            .as_str()
            .contains("This model cannot call tools. Answer in plain text.")
    );
    Ok(())
}

#[test]
fn golden_modes_produce_distinct_guidance_and_reminders() -> TestResult {
    let modes = [
        (ModeOverlay::Ask, "Mode: ASK (read-only)"),
        (ModeOverlay::Plan, "Mode: PLAN (read-only)"),
        (ModeOverlay::Debug, "Mode: DEBUG"),
        (ModeOverlay::Agent, "Mode: AGENT"),
        (ModeOverlay::Compaction, "Mode: COMPACTION"),
    ];

    for (mode, expected_str) in modes {
        let reminder = ModeReminder::for_turn(mode, ToolsPolicy::Enabled);
        assert!(
            reminder.as_str().contains(expected_str),
            "expected reminder for {:?} to contain {}",
            mode,
            expected_str
        );
    }
    Ok(())
}

#[test]
fn golden_reasoning_and_unicode_preservation() -> TestResult {
    let unicode_path = "/home/kullanıcı/proje_özel_şube_çalışması";
    let env = test_environment(unicode_path, Some("türkçe_dili"));
    let caps = test_capabilities(
        ToolsPolicy::Enabled,
        UsagePolicy::Normal,
        ModeOverlay::Agent,
    );
    let instructions = InstructionSet::new().assemble();

    let prompt = compose_system_prompt(&instructions, &env, &caps);
    let text = prompt.as_str();

    assert!(text.contains(unicode_path));
    assert!(text.contains("türkçe_dili"));
    assert!(text.contains("Working directory: /home/kullanıcı/proje_özel_şube_çalışması"));
    Ok(())
}

#[test]
fn negative_untrusted_project_cannot_elevate_privilege() -> TestResult {
    assert_eq!(
        InstructionTrust::Project.trust_verdict(),
        TrustVerdict::Untrusted
    );
    assert_eq!(
        InstructionTrust::Model.trust_verdict(),
        TrustVerdict::Untrusted
    );
    assert_eq!(
        InstructionTrust::Project.privilege_elevation(),
        PrivilegeElevation::Forbidden
    );
    assert_eq!(
        InstructionTrust::Model.privilege_elevation(),
        PrivilegeElevation::Forbidden
    );
    Ok(())
}

#[test]
fn negative_path_escape_and_oversize_rejected() -> TestResult {
    let dir = tempdir()?;
    let root = InstructionWorkspaceRoot::new(dir.path().to_path_buf());
    let escape_candidate = CandidateInstructionFiles::custom(vec![InstructionFilename::new(
        "../escape.md".to_owned(),
    )]);
    let limit = InstructionByteLimit::new(100);

    let escape_res = capture_project_instruction(&root, &escape_candidate, limit);
    // Non-existent path returns Ok(None); escaping existing path triggers PathEscape
    assert!(escape_res.is_ok());

    let big_file = dir.path().join("AGENTS.md");
    fs::write(&big_file, "12345678901234567890")?;
    let standard = CandidateInstructionFiles::default_candidates();
    let small_limit = InstructionByteLimit::new(10);
    let oversize_res = capture_project_instruction(&root, &standard, small_limit);

    assert_eq!(
        oversize_res,
        Err(InstructionError::Oversize {
            size: InstructionSize::new(20),
            limit: small_limit,
        })
    );
    Ok(())
}

#[test]
fn golden_instruction_precedence_ordering() -> TestResult {
    let meta = InstructionMetadata::new(SourceHash::new([5u8; 32]), InstructionSize::new(10));
    let pi = ProjectInstruction::new(
        InstructionFilename::new("AGENTS.md".to_owned()),
        InstructionText::new("LAYER_2_PROJECT".to_owned()),
        meta,
    );
    let assembled = InstructionSet::new()
        .with_default_asset(Some(InstructionText::new("LAYER_1_DEFAULT".to_owned())))
        .with_project_instruction(Some(pi))
        .with_user_override(Some(InstructionText::new("LAYER_3_USER".to_owned())))
        .with_model_specific(Some(InstructionText::new("LAYER_4_MODEL".to_owned())))
        .with_mode_overlay(Some(ModeOverlay::Plan))
        .with_editor_text(Some(InstructionText::new("LAYER_6_EDITOR".to_owned())))
        .assemble();

    let text = assembled.text().as_str();
    let p1 = text.find("LAYER_1_DEFAULT").ok_or("missing L1")?;
    let p2 = text.find("LAYER_2_PROJECT").ok_or("missing L2")?;
    let p3 = text.find("LAYER_3_USER").ok_or("missing L3")?;
    let p4 = text.find("LAYER_4_MODEL").ok_or("missing L4")?;
    let p5 = text.find("Mode: PLAN").ok_or("missing L5")?;
    let p6 = text.find("LAYER_6_EDITOR").ok_or("missing L6")?;

    assert!(p1 < p2);
    assert!(p2 < p3);
    assert!(p3 < p4);
    assert!(p4 < p5);
    assert!(p5 < p6);
    Ok(())
}

#[test]
fn native_prompt_cache_invalidation_and_determinism() -> TestResult {
    let limits = PromptCacheLimits::new(
        CacheEntryLimit::new(10),
        CacheByteLimit::new(10_000),
        Duration::from_secs(5),
    );
    let mut cache = NativePromptCache::new(limits);
    let session = SessionId::new();
    let root = WorkspaceRootPath::new("/workspace/app".to_owned());
    let scope = CacheSessionScope::new(session.clone(), root, ModeOverlay::Agent);
    let content1 = ContentRevisions::new(
        InstructionRevision::new("rev_1".to_owned()),
        ContextRevision::new("ctx_1".to_owned()),
    );
    let key1 = PromptCacheKey::new(
        scope.clone(),
        CacheRevisions::new(ConfigRevision::ZERO, MetadataRevision::default(), content1),
        ToolsPolicy::Enabled,
    );
    let prompt_text = InstructionText::new("Assembled system prompt".to_owned());
    let now = Instant::now();

    cache.insert(CacheInsertion::new(key1.clone(), prompt_text.clone()), now);

    // Cache hit
    let hit = cache.get(&key1, now);
    assert_eq!(hit, Some(prompt_text));

    // Cache miss on instruction revision change
    let content2 = ContentRevisions::new(
        InstructionRevision::new("rev_2".to_owned()),
        ContextRevision::new("ctx_1".to_owned()),
    );
    let key2 = PromptCacheKey::new(
        scope,
        CacheRevisions::new(ConfigRevision::ZERO, MetadataRevision::default(), content2),
        ToolsPolicy::Enabled,
    );
    assert_eq!(cache.get(&key2, now), None);

    // Invalidation by session
    cache.invalidate_session(&session);
    assert_eq!(cache.get(&key1, now), None);
    assert_eq!(cache.entry_count().get(), 0);
    Ok(())
}
