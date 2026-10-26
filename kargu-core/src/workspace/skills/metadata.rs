//! Deliberately small string-only frontmatter reader; no YAML evaluation.

use super::{Skill, SkillMetadata, SkillName};
use crate::{constants::limits, error::CoreError};
use std::path::Path;
use zeroize::Zeroizing;

pub(super) fn parse(text: &str, path: &Path) -> Result<Skill, CoreError> {
    let raw = text
        .strip_prefix('\u{feff}')
        .unwrap_or(text)
        .replace("\r\n", "\n");
    if raw.contains('\0') {
        return Err(CoreError::Rejected);
    }
    let fallback = path
        .parent()
        .and_then(Path::file_name)
        .and_then(|s| s.to_str())
        .ok_or(CoreError::Rejected)?;
    let (front, body) = if let Some(rest) = raw.strip_prefix("---\n") {
        let mut end = None;
        let mut offset = 4usize;
        for line in rest.split_inclusive('\n') {
            if line.trim_end_matches('\n') == "---" {
                end = Some((offset, offset.saturating_add(line.len())));
                break;
            }
            offset = offset.saturating_add(line.len());
        }
        if let Some((start, end)) = end {
            (
                raw.get(4..start).ok_or(CoreError::Limit)?,
                raw.get(end..).ok_or(CoreError::Limit)?,
            )
        } else {
            ("", raw.as_str())
        }
    } else {
        ("", raw.as_str())
    };
    let name = field(front, "name")?
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| fallback.into());
    let name = SkillName::try_from(name)?.0;
    let description = field(front, "description")?.unwrap_or_default();
    if description.len() > limits::SKILL_DESCRIPTION_BYTES {
        return Err(CoreError::Limit);
    }
    Ok(Skill {
        metadata: SkillMetadata {
            name,
            description,
            path: path.to_str().ok_or(CoreError::Rejected)?.into(),
        },
        body: Zeroizing::new(body.into()),
    })
}

fn field(front: &str, key: &str) -> Result<Option<String>, CoreError> {
    let mut lines = front.lines();
    while let Some(line) = lines.next() {
        let Some(value) = line.strip_prefix(key).and_then(|s| s.strip_prefix(':')) else {
            continue;
        };
        let value = value.trim();
        let header = value.split('#').next().unwrap_or("").trim();
        if matches!(header, "|" | "|-" | "|+" | ">" | ">-" | ">+") {
            let block: Vec<_> = lines
                .take_while(|line| line.is_empty() || line.starts_with([' ', '\t']))
                .collect();
            let indent = block
                .iter()
                .filter(|line| !line.trim().is_empty())
                .map(|line| {
                    line.len()
                        .saturating_sub(line.trim_start_matches([' ', '\t']).len())
                })
                .min()
                .unwrap_or(0);
            let lines: Vec<_> = block
                .iter()
                .map(|line| line.get(indent.min(line.len())..).unwrap_or(""))
                .collect();
            let mut output = String::new();
            let mut previous: Option<&str> = None;
            for line in lines {
                if let Some(prior) = previous {
                    if header.starts_with('|')
                        || line.is_empty()
                        || prior.starts_with(' ')
                        || line.starts_with(' ')
                    {
                        output.push('\n');
                    } else if !prior.is_empty() {
                        output.push(' ');
                    }
                }
                output.push_str(line);
                previous = Some(line);
            }
            return Ok(Some(output.trim().into()));
        }
        let scalar = if value.starts_with('"') {
            serde_json::from_str::<String>(value).map_err(|_| CoreError::InvalidValue {
                field: "SkillMetadata",
            })?
        } else if value.starts_with('\'') {
            value
                .strip_prefix('\'')
                .and_then(|s| s.strip_suffix('\''))
                .ok_or(CoreError::InvalidValue {
                    field: "SkillMetadata",
                })?
                .replace("''", "'")
        } else {
            let end = value.char_indices().find_map(|(i, c)| {
                (c == '#' && value.get(..i).is_some_and(|s| s.ends_with([' ', '\t']))).then_some(i)
            });
            value
                .get(..end.unwrap_or(value.len()))
                .ok_or(CoreError::Limit)?
                .trim()
                .into()
        };
        return Ok(Some(scalar));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn frontmatter_preserves_legacy_quotes_blocks_eof_crlf_and_fallback() -> Result<(), CoreError> {
        for (text, name, description, body) in [
            (
                "---\r\nname: 'quoted name'\r\ndescription: \"line\\nvalue\"\r\n---",
                "quoted name",
                "line\nvalue",
                "",
            ),
            (
                "---\nname: folded\ndescription: >-\n  first line\n  second line\n\n  paragraph two\n---\nbody",
                "folded",
                "first line second line\nparagraph two",
                "body",
            ),
            (
                "---\nname: literal\ndescription: |\n  first\n  second\n---\nbody",
                "literal",
                "first\nsecond",
                "body",
            ),
            (
                "---\nname: 'it''s'\ndescription: plain # comment\n---\nbody",
                "it's",
                "plain",
                "body",
            ),
            ("body", "fallback", "", "body"),
        ] {
            let skill = parse(text, Path::new("/fallback/SKILL.md"))?;
            assert_eq!(skill.metadata.name, name);
            assert_eq!(skill.metadata.description, description);
            assert_eq!(skill.body.as_str(), body);
        }
        assert!(
            parse(
                "---\nname: \"bad\\q\"\n---\nbody",
                Path::new("/fallback/SKILL.md")
            )
            .is_err()
        );
        Ok(())
    }
}
