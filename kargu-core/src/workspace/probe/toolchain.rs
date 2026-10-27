//! File-dependent command selection is metadata; discovery executes no scripts.
use super::{Commands, Probe, Toolchain};
use crate::{error::CoreError, security::file::PinnedFile};
use zeroize::Zeroizing;
pub(super) fn manager(p: &Probe<'_>) -> &'static str {
    if p.exists("pnpm-lock.yaml") {
        "pnpm"
    } else if p.exists("yarn.lock") {
        "yarn"
    } else if p.exists("bun.lockb") || p.exists("bun.lock") {
        "bun"
    } else {
        "npm"
    }
}
fn scripts(p: &mut Probe<'_>) -> Result<Vec<&'static str>, CoreError> {
    if !p.exists("package.json") {
        return Ok(vec![]);
    }
    let path = p.root.join("package.json");
    let canonical = path.canonicalize()?;
    if !canonical.starts_with(p.root) {
        return Err(CoreError::Rejected);
    }
    let file = PinnedFile::open(&path, canonical, p.cancel, p.deadline)?;
    if file.size() > 262144 {
        p.complete = false;
        return Ok(vec![]);
    }
    let mut reader = file.reader()?;
    let mut bytes = Zeroizing::new(Vec::new());
    let mut chunk = [0; 4096];
    loop {
        let count = reader.read(&mut chunk, p.cancel, p.deadline)?;
        if count == 0 {
            break;
        }
        if bytes.len().saturating_add(count) > 262144 {
            p.complete = false;
            return Ok(vec![]);
        }
        bytes.extend_from_slice(chunk.get(..count).ok_or(CoreError::Limit)?);
    }
    reader.finish()?;
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        p.complete = false;
        return Ok(vec![]);
    };
    Ok(["build", "test", "lint"]
        .into_iter()
        .filter(|key| {
            value
                .get("scripts")
                .and_then(|s| s.get(key))
                .and_then(|v| v.as_str())
                .is_some_and(|s| !s.trim().is_empty())
        })
        .collect())
}
fn file_command(arguments: &str) -> String {
    format!(
        "find . -path './.git' -prune -o -type f -name '*.el' -exec emacs -Q --batch {arguments} {{}} +"
    )
}
pub(super) fn commands(toolchain: &Toolchain, p: &mut Probe<'_>) -> Result<Commands, CoreError> {
    Ok(match toolchain {
        Toolchain::Static { commands } => commands.clone(),
        Toolchain::Javascript { typescript } => {
            let manager = manager(p);
            let scripts = scripts(p)?;
            Commands {
                build_cmd: if scripts.contains(&"build") {
                    Some(format!("{manager} run build"))
                } else if *typescript {
                    Some("npx tsc --noEmit".into())
                } else {
                    None
                },
                test_cmd: scripts.contains(&"test").then(|| format!("{manager} test")),
                lint_cmd: scripts
                    .contains(&"lint")
                    .then(|| format!("{manager} run lint")),
                notes: Some(format!(
                    "Package manager: {manager}. Only use scripts defined in package.json."
                )),
            }
        }
        Toolchain::Java {} => {
            let gradle = p.exists("build.gradle") || p.exists("build.gradle.kts");
            let manager = if gradle {
                if p.exists("gradlew") {
                    "./gradlew"
                } else {
                    "gradle"
                }
            } else {
                "mvn"
            };
            Commands {
                build_cmd: Some(format!(
                    "{manager} {}",
                    if gradle { "build -x test" } else { "compile" }
                )),
                test_cmd: Some(format!("{manager} test")),
                lint_cmd: Some(format!(
                    "{manager} {}",
                    if gradle { "check" } else { "checkstyle:check" }
                )),
                notes: Some(
                    if gradle {
                        "Run Gradle build and test tasks using the `bash` tool."
                    } else {
                        "Run Maven goals using the `bash` tool."
                    }
                    .into(),
                ),
            }
        }
        Toolchain::Elisp {} => {
            let runner = ["tests/run-tests.el", "test/run-tests.el"]
                .into_iter()
                .find(|path| p.exists(path));
            Commands{build_cmd:Some(file_command("-L . -f batch-byte-compile")),test_cmd:runner.map(|r|format!("emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize))' -l '{r}'")),lint_cmd:Some(file_command("--eval '(progn (dolist (file command-line-args-left) (with-temp-buffer (insert-file-contents file) (emacs-lisp-mode) (check-parens))) (setq command-line-args-left nil))'")),notes:Some(format!("Use native xref and imenu, not an external language server. Build and parenthesis checks target project .el files. {}",if runner.is_some(){"The test command loads the existing project runner."}else{"No conventional ERT runner was found; read project instructions to select tests. Never treat zero loaded tests as verification."}))}
        }
    })
}
