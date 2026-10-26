//! Bounded instruction discovery. Search roots are editor grants, never tool arguments.

mod discover;
mod metadata;

use crate::{constants::limits, error::CoreError};
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, time::Instant};
use tokio_util::sync::CancellationToken;

macro_rules! budget {
    ($name:ident, $maximum:expr) => {
        #[derive(Deserialize)]
        #[serde(try_from = "usize")]
        struct $name(usize);
        impl TryFrom<usize> for $name {
            type Error = CoreError;
            fn try_from(value: usize) -> Result<Self, CoreError> {
                if value > $maximum {
                    Err(CoreError::Limit)
                } else {
                    Ok(Self(value))
                }
            }
        }
    };
}
budget!(FileBytes, limits::SKILL_FILE_BYTES);
budget!(BodyChars, limits::SKILL_BODY_CHARS);
budget!(DirectoryLimit, limits::SEARCH_DIRECTORIES);

#[derive(Deserialize)]
#[serde(try_from = "PathBuf")]
struct SearchRoot(PathBuf);
impl TryFrom<PathBuf> for SearchRoot {
    type Error = CoreError;
    fn try_from(value: PathBuf) -> Result<Self, CoreError> {
        super::command::validate_path(&value)?;
        if !value.is_absolute() || value.as_os_str().as_encoded_bytes().contains(&0) {
            return Err(CoreError::Rejected);
        }
        Ok(Self(value))
    }
}

#[derive(Deserialize)]
#[serde(try_from = "String")]
struct SkillName(String);
impl TryFrom<String> for SkillName {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        let value = value.trim();
        if value.is_empty() || value.len() > limits::SKILL_NAME_BYTES || value.contains('\0') {
            return Err(CoreError::InvalidValue { field: "SkillName" });
        }
        Ok(Self(value.to_owned()))
    }
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum Operation {
    Catalog {},
    Load { name: SkillName },
}

#[derive(Deserialize)]
#[serde(try_from = "SkillDto")]
pub(crate) struct SkillInput {
    root: SearchRoot,
    user_root: Option<SearchRoot>,
    skip_directories: Vec<String>,
    max_directories: DirectoryLimit,
    max_file_bytes: FileBytes,
    body_chars: BodyChars,
    query: Operation,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SkillDto {
    root: SearchRoot,
    user_root: Option<SearchRoot>,
    skip_directories: Vec<String>,
    max_directories: DirectoryLimit,
    max_file_bytes: FileBytes,
    body_chars: BodyChars,
    query: Operation,
}
impl TryFrom<SkillDto> for SkillInput {
    type Error = CoreError;
    fn try_from(value: SkillDto) -> Result<Self, CoreError> {
        if value.skip_directories.len() > 64
            || value.skip_directories.iter().any(|name| {
                name.is_empty()
                    || name.len() > 256
                    || name == "."
                    || name == ".."
                    || name.contains(['/', '\0'])
            })
        {
            return Err(CoreError::InvalidValue {
                field: "SkillExclusions",
            });
        }
        Ok(Self {
            root: value.root,
            user_root: value.user_root,
            skip_directories: value.skip_directories,
            max_directories: value.max_directories,
            max_file_bytes: value.max_file_bytes,
            body_chars: value.body_chars,
            query: value.query,
        })
    }
}

#[derive(Serialize)]
pub(crate) struct SkillMetadata {
    name: String,
    description: String,
    path: String,
}
struct Skill {
    metadata: SkillMetadata,
    body: zeroize::Zeroizing<String>,
}
#[derive(Serialize)]
pub(crate) struct SkillResult {
    text: String,
    skills: Vec<SkillMetadata>,
    truncated: bool,
    skipped: usize,
}

impl SkillInput {
    pub(crate) fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<SkillResult, CoreError> {
        discover::execute(self, cancel, deadline)
    }
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn render(
    skills: Vec<Skill>,
    input: &SkillInput,
    truncated: bool,
    skipped: usize,
) -> Result<SkillResult, CoreError> {
    let mut text = match &input.query {
        Operation::Catalog {} if skills.is_empty() => String::new(),
        Operation::Catalog {} => {
            let entries: Vec<_> = skills.iter().map(|s| format!(
                "  <skill>\n    <name>{}</name>\n    <description>{}</description>\n  </skill>",
                escape(&s.metadata.name), escape(&s.metadata.description))).collect();
            format!(
                "Skills provide specialized instructions for specific tasks.\nUse the skill tool with the skill name when a task matches.\n<available_skills>\n{}\n</available_skills>\n",
                entries.join("\n")
            )
        }
        Operation::Load { name } => {
            if let Some(skill) = skills.iter().find(|s| s.metadata.name == name.0) {
                let count = skill.body.chars().count();
                let mut body: String = skill.body.chars().take(input.body_chars.0).collect();
                if count > input.body_chars.0 {
                    body.push_str("\n... (skill truncated)");
                }
                let base = std::path::Path::new(&skill.metadata.path)
                    .parent()
                    .and_then(|p| p.to_str())
                    .ok_or(CoreError::Rejected)?;
                format!(
                    "<skill_content name=\"{}\">\n# Skill: {}\n\n{}\nBase directory: {}/\n</skill_content>",
                    escape(&skill.metadata.name),
                    escape(&skill.metadata.name),
                    body.trim(),
                    escape(base)
                )
            } else {
                format!(
                    "ERROR: skill {:?} not found. Available: {}",
                    name.0,
                    if skills.is_empty() {
                        "none".into()
                    } else {
                        skills
                            .iter()
                            .map(|s| s.metadata.name.as_str())
                            .collect::<Vec<_>>()
                            .join(", ")
                    }
                )
            }
        }
    };
    if truncated || skipped > 0 {
        text.push_str(&format!("\nSkill discovery incomplete: limits_reached={truncated}, unreadable_or_invalid={skipped}."));
    }
    if text.len() > limits::SKILL_OUTPUT_BYTES {
        return Err(CoreError::Limit);
    }
    Ok(SkillResult {
        text,
        skills: skills.into_iter().map(|s| s.metadata).collect(),
        truncated,
        skipped,
    })
}
