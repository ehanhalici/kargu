//! Native framing/literal preparation and real Git equivalence, without editor writes.
use kargu_core::{
    constants::limits,
    edit::{
        EditError,
        patch::{OperationKind, UnifiedPatch},
        proposal::replace,
        types::{ContentHash, EditPath, EditText},
    },
};
use std::{fs, path::Path, process::Command};
type TestResult = Result<(), Box<dyn std::error::Error>>;
fn text(value: &str) -> Result<EditText, EditError> {
    EditText::try_from(value.to_owned())
}
fn patch(value: &str) -> Result<UnifiedPatch, EditError> {
    UnifiedPatch::try_from(value.to_owned())
}

#[test]
fn literal_replacement_is_unique_case_sensitive_unicode_and_regex_literal() -> TestResult {
    let base = text("same\nAlpha α😀 [a.*] $1 \\ path\nsame\n")?;
    let actual = replace(
        &base,
        &text("α😀 [a.*] $1 \\ path")?,
        &text("🦀 $2 \\literal")?,
    )?;
    assert_eq!(actual.as_str(), "same\nAlpha 🦀 $2 \\literal\nsame\n");
    assert_eq!(
        replace(&base, &text("same")?, &text("other")?).err(),
        Some(EditError::AmbiguousMatch)
    );
    assert_eq!(
        replace(&base, &text("alpha")?, &text("other")?).err(),
        Some(EditError::MissingMatch)
    );
    assert_eq!(
        replace(&base, &text("")?, &text("other")?).err(),
        Some(EditError::MissingMatch)
    );
    assert_eq!(
        replace(&text("aaa")?, &text("aa")?, &text("x")?)?.as_str(),
        "xa"
    );
    assert_ne!(text(" exact ")?.hash(), text("exact")?.hash());
    assert_ne!(text("exact\n")?.hash(), text("exact")?.hash());
    let encoded = serde_json::to_string(&actual.hash())?;
    assert_eq!(
        serde_json::from_str::<ContentHash>(&encoded)?,
        actual.hash()
    );
    assert!(serde_json::from_str::<ContentHash>("\"ABC\"").is_err());
    Ok(())
}
#[test]
fn content_paths_and_expanding_replacement_are_bounded_before_publishing() -> TestResult {
    let large = EditText::try_from("x".repeat(limits::EDIT_TEXT_BYTES))?;
    assert_eq!(
        replace(&text("aa x")?, &text("aa")?, &large).err(),
        Some(EditError::Limit)
    );
    assert_eq!(
        EditText::try_from("x".repeat(limits::EDIT_TEXT_BYTES + 1)).err(),
        Some(EditError::Limit)
    );
    for path in [
        "",
        ".",
        "/outside",
        "../outside",
        "a/../../outside",
        ".git/config",
        "nested/.git/index",
        ".kargu.patch",
        "a\0b",
        "a\nb",
        "a\tb",
    ] {
        assert!(EditPath::try_from(path.to_owned()).is_err(), "{path:?}");
    }
    assert_eq!(
        EditPath::try_from("./src/./é😀.el".to_owned())?.as_str(),
        "src/é😀.el"
    );
    Ok(())
}
#[test]
fn complete_hunks_keep_header_like_body_crlf_and_actual_coordinates() -> TestResult {
    let parsed = patch(
        "--- a/a.txt\r\n+++ b/a.txt\r\n@@ -1,2 +1,2 @@ function\r\n--- old source\r\n+++ new source\r\n unchanged\r\n@@ -8 +8 @@\r\n-last\r\n+end\r\n",
    )?;
    assert_eq!(parsed.hunk_count().get(), 2);
    let operation = parsed.operations().first().ok_or("operation")?;
    assert_eq!(operation.kind(), OperationKind::Update);
    assert_eq!(operation.hunks().len(), 2);
    let hunk = operation.hunks().first().ok_or("hunk")?;
    assert_eq!(hunk.old_range().0.get(), 1);
    assert_eq!(hunk.old_range().1.get(), 2);
    assert_eq!(hunk.new_range().1.get(), 2);
    assert!(
        parsed
            .normalized()
            .contains("--- old source\n+++ new source\n unchanged\n")
    );
    assert!(!parsed.normalized().contains('\r'));
    Ok(())
}
#[test]
fn unsupported_directives_and_escaped_or_reserved_targets_fail_closed() -> TestResult {
    for directive in [
        "*** Begin Patch",
        "*** Move to: x",
        "GIT binary patch",
        "Binary files a/x and b/x differ",
        "rename from x",
        "copy to y",
        "similarity index 90%",
        "old mode 100644",
        "new mode 100755",
        "new file mode 100755",
        "deleted file mode 120000",
    ] {
        assert_eq!(
            patch(&format!(
                "{directive}\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n"
            ))
            .err(),
            Some(EditError::UnsupportedPatch)
        );
    }
    for header in [
        "--- a/../outside\n+++ b/../outside",
        "--- a/.git/config\n+++ b/.git/config",
        "--- /dev/null\n+++ /dev/null",
        "--- a/old\n+++ b/new",
        "--- \"a/\\056\\056/outside\"\n+++ \"b/\\056\\056/outside\"",
        "--- a/.kargu.patch\n+++ b/.kargu.patch",
        "--- \"a/\\777\"\n+++ \"b/\\777\"",
    ] {
        assert!(patch(&format!("{header}\n@@ -1 +1 @@\n-a\n+b\n")).is_err());
    }
    assert!(patch("--- a/a\n+++ b/a\n@@ -1 +1 @@\n-GIT binary patch\n+*** Begin Patch\n").is_ok());
    Ok(())
}
#[test]
fn malformed_incomplete_or_oversized_framing_never_becomes_a_partial_patch() -> TestResult {
    for fragment in [
        "",
        "@@ -1 +1 @@\n-a\n+b\n",
        "--- a/a\nnot a new header\n",
        "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n",
        "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n+extra\n",
        "--- a/a\n+++ b/a\n@@ -0 +1 @@\n-a\n+b\n",
        "--- a/a\n+++ b/a\n@@ -1,+1 +1 @@\n-a\n+b\n",
        "--- a/a\n+++ b/a\n@@ -1 +1 @@\n\\ No newline at end of file\n-a\n+b\n",
        "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n\\ No newline at end of file\n",
    ] {
        assert!(patch(fragment).is_err(), "{fragment:?}");
    }
    let huge = format!("--- a/a\n+++ b/a\n@@ -{},1 +1 @@\n-a\n+b\n", usize::MAX);
    assert!(patch(&huge).is_err());
    assert_eq!(
        patch(&"x".repeat(limits::EDIT_TEXT_BYTES + 1)).err(),
        Some(EditError::Limit)
    );
    assert_eq!(
        patch(&"\n".repeat(limits::EDIT_PATCH_LINES + 1)).err(),
        Some(EditError::Limit)
    );
    let hunks = format!(
        "--- a/a\n+++ b/a\n{}",
        "@@ -1 +1 @@\n-a\n+b\n".repeat(limits::EDIT_HUNKS + 1)
    );
    assert_eq!(patch(&hunks).err(), Some(EditError::Limit));
    let files = "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n".repeat(limits::EDIT_FILES + 1);
    assert_eq!(patch(&files).err(), Some(EditError::Limit));
    Ok(())
}
#[test]
fn zero_context_uniqueness_is_a_preflight_check_not_a_matching_engine() -> TestResult {
    let parsed = patch("--- a/a\n+++ b/a\n@@ -1 +1 @@\n-aa\n+new\n")?;
    let hunk = parsed
        .operations()
        .first()
        .and_then(|op| op.hunks().first())
        .ok_or("hunk")?;
    assert_eq!(
        hunk.check_unique_context(&text("aaaa")?),
        Err(EditError::AmbiguousMatch)
    );
    assert_eq!(
        hunk.check_unique_context(&text("nothing")?),
        Err(EditError::MissingMatch)
    );
    hunk.check_unique_context(&text("aaa")?)?;
    let parsed = patch("--- a/a\n+++ b/a\n@@ -1,2 +1,2 @@\n context\n-aa\n+new\n")?;
    parsed
        .operations()
        .first()
        .and_then(|op| op.hunks().first())
        .ok_or("hunk")?
        .check_unique_context(&text("aa aa")?)?;
    Ok(())
}
fn git_apply(root: &Path, parsed: &UnifiedPatch) -> TestResult {
    let git_dir = root.join(".git");
    fs::create_dir_all(git_dir.join("objects"))?;
    fs::create_dir_all(git_dir.join("refs"))?;
    fs::write(git_dir.join("HEAD"), "ref: refs/heads/main\n")?;
    fs::write(root.join(".kargu.patch"), parsed.normalized())?;
    let output = Command::new("git")
        .env_clear()
        .env("PATH", std::env::var_os("PATH").ok_or("PATH")?)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .arg(format!("--git-dir={}", git_dir.display()))
        .arg(format!("--work-tree={}", root.display()))
        .args([
            "-c",
            "core.attributesFile=/dev/null",
            "-c",
            "core.autocrlf=false",
            "apply",
            "--unidiff-zero",
            "-p1",
            "--",
            ".kargu.patch",
        ])
        .current_dir(root)
        .output()?;
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!git_dir.join("index").exists());
    Ok(())
}
#[test]
fn normalized_add_update_delete_and_no_newline_use_real_git_without_touching_index() -> TestResult {
    let root = tempfile::tempdir()?;
    fs::write(root.path().join("old"), "gone\n")?;
    fs::write(root.path().join("live"), "old")?;
    let parsed = patch(
        "--- /dev/null\n+++ b/new\n@@ -0,0 +1 @@\n+α😀\n--- a/old\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\n--- a/live\n+++ b/live\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n",
    )?;
    assert_eq!(parsed.hunk_count().get(), 3);
    git_apply(root.path(), &parsed)?;
    assert_eq!(fs::read_to_string(root.path().join("new"))?, "α😀\n");
    assert_eq!(fs::read_to_string(root.path().join("live"))?, "new");
    assert!(!root.path().join("old").exists());
    Ok(())
}
#[test]
fn quoted_git_paths_decode_utf8_octal_and_reencode_without_header_injection() -> TestResult {
    let root = tempfile::tempdir()?;
    let name = "é😀 quoted\\name\".txt";
    fs::write(root.path().join(name), "old\n")?;
    let old = serde_json::to_string(&format!("a/{name}"))?.replace('é', "\\303\\251");
    let new = serde_json::to_string(&format!("b/{name}"))?.replace('é', "\\303\\251");
    let parsed = patch(&format!("--- {old}\n+++ {new}\n@@ -1 +1 @@\n-old\n+new\n"))?;
    assert_eq!(
        parsed.operations().first().ok_or("path")?.path().as_str(),
        name
    );
    git_apply(root.path(), &parsed)?;
    assert_eq!(fs::read_to_string(root.path().join(name))?, "new\n");
    Ok(())
}

#[test]
fn review_data_distinguishes_full_edited_rejected_interrupted_and_noop_without_claiming_apply()
-> TestResult {
    use kargu_core::edit::review::{ReviewAssessment, ReviewDecision, ReviewKind};
    let base = text("original α😀\n")?;
    let proposed = text("requested α😀\n")?;
    for (decision, kind, accepted) in [
        (
            ReviewDecision::Accept {
                content: proposed.clone(),
            },
            ReviewKind::AcceptedProposal,
            true,
        ),
        (
            ReviewDecision::Accept {
                content: text("human edited α😀\n")?,
            },
            ReviewKind::AcceptedRevision,
            true,
        ),
        (
            ReviewDecision::Accept {
                content: base.clone(),
            },
            ReviewKind::Rejected,
            false,
        ),
        (ReviewDecision::Reject {}, ReviewKind::Rejected, false),
        (ReviewDecision::Interrupt {}, ReviewKind::Interrupted, false),
    ] {
        let assessment = ReviewAssessment::assess(&base, &proposed, decision);
        assert_eq!(assessment.kind(), kind);
        assert_eq!(assessment.accepted().is_some(), accepted);
    }
    let unchanged = ReviewAssessment::assess(
        &base,
        &base,
        ReviewDecision::Accept {
            content: base.clone(),
        },
    );
    assert_eq!(unchanged.kind(), ReviewKind::Unchanged);
    assert!(unchanged.accepted().is_none());
    for wire in [
        r#"{"decision":"approved"}"#,
        r#"{"decision":"reject","content":"x"}"#,
        r#"{"decision":"accept"}"#,
    ] {
        assert!(serde_json::from_str::<ReviewDecision>(wire).is_err());
    }
    Ok(())
}
