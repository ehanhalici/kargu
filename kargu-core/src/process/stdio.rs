//! Build exact commands and optional merged pipes without shell wrappers.

use crate::{domain::StderrPolicy, error::CoreError, security::CommandSpec};
use std::process::Stdio;
use tokio::process::{Child, ChildStdout, Command};

pub(super) fn spawn(spec: &CommandSpec) -> Result<Child, CoreError> {
    let mut command = Command::new(&spec.program);
    command
        .arg0(&spec.invocation)
        .args(&spec.arguments)
        .current_dir(spec.cwd.path())
        .env_clear()
        .envs(spec.environment.entries())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true);
    let merged = match spec.stderr {
        StderrPolicy::Separate => None,
        StderrPolicy::Merge => Some(merge(&mut command)?),
    };
    let mut child = command.spawn()?;
    if let Some(stdout) = merged {
        child.stdout = Some(stdout);
    }
    Ok(child)
}

fn merge(command: &mut Command) -> Result<ChildStdout, CoreError> {
    let (read, write) =
        nix::unistd::pipe2(nix::fcntl::OFlag::O_CLOEXEC).map_err(std::io::Error::from)?;
    let read = ChildStdout::from_std(std::process::ChildStdout::from(read))?;
    command
        .stdout(Stdio::from(write.try_clone()?))
        .stderr(Stdio::from(write));
    Ok(read)
}
