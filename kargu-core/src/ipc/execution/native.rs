//! Model argument → existing closed native command adapters. Root, revisions,
//! mode, executable and environment come from the actual run, never model keys.

use super::{
    input::{ExecuteInput, Prepared},
    reply::Reply,
};
use crate::{
    application::RunHandle,
    constants::{limits, timeouts},
    domain::ToolName,
    error::CoreError,
    workspace::{self, command::Preparation},
};
use serde::de::DeserializeOwned;
use serde_json::{Value, json, value::RawValue};
use std::collections::BTreeMap;

fn decode<T: DeserializeOwned>(value: Value) -> Result<T, CoreError> {
    serde_json::from_value(value).map_err(|_| CoreError::InvalidValue {
        field: "NativeToolArguments",
    })
}
fn environment() -> Result<BTreeMap<String, String>, CoreError> {
    std::env::vars_os()
        .map(|(name, value)| {
            Ok((
                name.into_string().map_err(|_| CoreError::InvalidValue {
                    field: "EnvironmentEncoding",
                })?,
                value.into_string().map_err(|_| CoreError::InvalidValue {
                    field: "EnvironmentEncoding",
                })?,
            ))
        })
        .collect()
}
pub(super) fn prepare(
    run: &RunHandle,
    name: &ToolName,
    args: &RawValue,
    context: &Preparation,
) -> Result<Prepared, CoreError> {
    run.check_live()?;
    context.check()?;
    let args: Value = serde_json::from_str(args.get()).map_err(|_| CoreError::InvalidToolOutput)?;
    let root = run.settings().workspace().path();
    let timeout = u64::try_from(timeouts::WORKSPACE_READ.as_millis())
        .map_err(|_| CoreError::ArithmeticOverflow)?;
    match name.as_str() {
        crate::constants::protocol::BASH_TOOL => {
            let script = args
                .get("command")
                .and_then(Value::as_str)
                .ok_or(CoreError::Rejected)?;
            let job_command = script.trim();
            if args.get("background").and_then(Value::as_bool) == Some(true)
                || job_command == "list"
                || job_command.starts_with("status ")
                || job_command.starts_with("kill ")
            {
                return Err(CoreError::Unavailable);
            }
            let shell = match workspace::command::executable("bash") {
                Ok(shell) => shell,
                Err(CoreError::Unavailable) => workspace::command::executable("sh")?,
                Err(error) => return Err(error),
            };
            let input: ExecuteInput = decode(
                json!({"root":root,"mode":run.settings().mode,"program":shell,
                "arguments":["-c",script],"cwd":args.get("cwd"),"timeout_ms":null,
                "output_bytes":limits::SEARCH_RESULT_BYTES,"environment":environment()?,
                "config_revision":run.scope().config_revision(),"policy_revision":run.scope().policy_revision()}),
            )?;
            input.prepare_borrowed()
        }
        "list_files" => {
            let input: workspace::listing::ListFilesInput =
                decode(json!({"root":root,"path":args.get("path"),"skip_directories":[]}))?;
            let (command, settings) = input.prepare()?;
            Ok(Prepared {
                command,
                settings,
                tool: name.clone(),
                reply: Reply::Command,
            })
        }
        "workspace_grep" => {
            let input: workspace::grep::GrepInput = decode(
                json!({"root":root,"path":args.get("path"),"pattern":args.get("pattern"),
                "glob":args.get("glob"),"max_matches":args.get("max_matches").cloned().unwrap_or(json!(50)),
                "skip_directories":[],"output_bytes":limits::SEARCH_RESULT_BYTES,"timeout_ms":timeout}),
            )?;
            let (command, settings, report) = input.prepare()?;
            Ok(Prepared {
                command,
                settings,
                tool: name.clone(),
                reply: Reply::Grep(report),
            })
        }
        "git_status" => {
            let input: workspace::git::GitStatusInput = decode(
                json!({"root":root,"timeout_ms":timeout,"output_bytes":limits::SEARCH_RESULT_BYTES}),
            )?;
            input.prepare(context).map(Prepared::from)
        }
        "git_log" | "git_diff" | "git_blame" | "git_branches" | "git_stashes" => {
            let query = match name.as_str() {
                "git_log" => {
                    json!({"operation":"log","max_count":args.get("max_count").cloned().unwrap_or(json!(10)),"path":args.get("path")})
                }
                "git_diff" => {
                    json!({"operation":"diff","staged":args.get("staged").cloned().unwrap_or(json!(false)),"path":args.get("path"),"commit":args.get("commit")})
                }
                "git_blame" => {
                    json!({"operation":"blame","path":args.get("file_path"),"from":args.get("start_line"),"to":args.get("end_line")})
                }
                "git_branches" => json!({"operation":"branches"}),
                _ => json!({"operation":"stashes"}),
            };
            let input: workspace::git::GitReadInput = decode(
                json!({"root":root,"query":query,"timeout_ms":timeout,"output_bytes":limits::SEARCH_RESULT_BYTES}),
            )?;
            input.prepare(context).map(Prepared::from)
        }
        "git_stage" | "git_unstage" | "git_commit" | "git_branch" | "git_stash" => {
            let query = match name.as_str() {
                "git_stage" => json!({"operation":"stage","paths":[args.get("paths")]}),
                "git_unstage" => json!({"operation":"unstage","paths":[args.get("paths")]}),
                "git_commit" => {
                    json!({"operation":"commit","message":args.get("message"),"all":args.get("all").cloned().unwrap_or(json!(false))})
                }
                "git_branch" => match args.get("action").and_then(Value::as_str) {
                    Some("create") => json!({"operation":"branch_create","name":args.get("name")}),
                    Some("switch") => json!({"operation":"branch_switch","name":args.get("name")}),
                    Some("delete") => json!({"operation":"branch_delete","name":args.get("name")}),
                    Some("list") => return read_list(root, "branches", timeout, context),
                    _ => return Err(CoreError::Rejected),
                },
                _ => match args.get("action").and_then(Value::as_str) {
                    Some("push") => json!({"operation":"stash_push","message":args.get("message")}),
                    Some("apply") => json!({"operation":"stash_apply","stash":args.get("stash")}),
                    Some("list") => return read_list(root, "stashes", timeout, context),
                    _ => return Err(CoreError::Rejected),
                },
            };
            let input: workspace::git::mutation::MutationInput = decode(
                json!({"root":root,"mode":run.settings().mode,"query":query,
                "timeout_ms":timeout,"output_bytes":limits::SEARCH_RESULT_BYTES,"environment":environment()?,
                "config_revision":run.scope().config_revision(),"policy_revision":run.scope().policy_revision()}),
            )?;
            input.prepare(context).map(Prepared::from)
        }
        _ => Err(CoreError::Unavailable),
    }
}
fn read_list(
    root: &std::path::Path,
    operation: &str,
    timeout: u64,
    context: &Preparation,
) -> Result<Prepared, CoreError> {
    let input: workspace::git::GitReadInput =
        decode(json!({"root":root,"query":{"operation":operation},
        "timeout_ms":timeout,"output_bytes":limits::SEARCH_RESULT_BYTES}))?;
    input.prepare(context).map(Prepared::from)
}
