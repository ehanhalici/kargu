//! Sealed binding between one committed model edit and its editor preparation.
//! The source ID selects this binding; it cannot replace its root or tool data.

use super::{
    PartBuffer,
    types::{Begin, Intent, Part},
};
use crate::{
    application::{
        RunHandle, ToolOutcome,
        agent::{AgentTool, ToolAdmission},
    },
    domain::{ToolCallId, ToolName, ToolStepId},
    edit::{EditError, types::EditPath},
    error::CoreError,
    security::{ToolRoute, Workspace},
};
use serde_json::{Value, value::RawValue};
use std::{collections::BTreeMap, sync::Arc, time::Instant};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Copy, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ParentPolicy {
    review_mode: crate::edit::types::ReviewMode,
    save_policy: crate::edit::types::SavePolicy,
}
impl Default for ParentPolicy {
    fn default() -> Self {
        Self {
            review_mode: crate::edit::types::ReviewMode::Blocking,
            save_policy: crate::edit::types::SavePolicy::BufferOnly,
        }
    }
}

#[derive(Clone)]
pub(crate) struct ParentEdit {
    pub run: RunHandle,
    pub call: ToolCallId,
    pub name: ToolName,
    policy: ParentPolicy,
    arguments: Arc<RawValue>,
    selection: Option<crate::sensors::symbols::SymbolEditSelection>,
}
pub(super) enum ParentState {
    Open {
        binding: Box<ParentEdit>,
        begun: bool,
    },
    Closed,
}
pub(super) struct ParentSource {
    pub state: ParentState,
    pub step: Option<ToolStepId>,
    pub result: Option<ParentResult>,
}
pub(crate) struct ParentResult {
    pub outcome: ToolOutcome,
    pub text: String,
}
impl ParentEdit {
    pub(super) fn capture(
        call: &AgentTool,
        policy: ParentPolicy,
        selection: Option<crate::sensors::symbols::SymbolEditSelection>,
    ) -> Result<Self, CoreError> {
        if call.admission() != ToolAdmission::Ready || call.route() != Some(ToolRoute::NativeEdit) {
            return Err(CoreError::Rejected);
        }
        call.run().check_live()?;
        if (call.name().as_str() == "edit_by_lsp") != selection.is_some() {
            return Err(CoreError::Rejected);
        }
        Ok(Self {
            run: call.run().clone(),
            call: call.id().clone(),
            name: call.name().clone(),
            policy,
            arguments: Arc::from(call.arguments().to_owned()),
            selection,
        })
    }
    pub(super) fn check_begin(&self, input: &Begin) -> Result<(), CoreError> {
        self.run.check_live()?;
        if input.root != self.run.settings().workspace.path()
            || input.mode != self.run.settings().mode
            || input.config_revision != self.run.scope().config_revision()
            || input.policy_revision != self.run.scope().policy_revision()
            || input.review_mode != self.policy.review_mode
            || input.save_policy != self.policy.save_policy
        {
            return Err(CoreError::StaleOwner);
        }
        if let Some(selection) = &self.selection {
            let live = input.live.as_ref().ok_or(CoreError::StaleOwner)?;
            if String::from(live.id.clone()) != selection.document.document_id().as_str()
                || live.tick.get() != selection.document.tick().get()
                || input.language_source.as_ref() != Some(selection.source())
                || input.intent.path() != Some(&selection.document.path)
            {
                return Err(CoreError::StaleOwner);
            }
        } else if input.language_source.is_some() {
            return Err(CoreError::Rejected);
        }
        Ok(())
    }
    /// Validate uploaded intent/text before any file or Git preparation IO.
    pub(super) fn check_parts(
        &self,
        input: &Begin,
        parts: &BTreeMap<Part, PartBuffer>,
    ) -> Result<(), CoreError> {
        self.check_begin(input)?;
        let args: Value =
            serde_json::from_str(self.arguments.get()).map_err(|_| CoreError::InvalidToolOutput)?;
        let text = |name: &str| {
            args.get(name)
                .and_then(Value::as_str)
                .ok_or(CoreError::Rejected)
        };
        let part = |name: Part| {
            parts
                .get(&name)
                .filter(|part| part.complete())
                .map(|part| part.text.as_str())
                .ok_or(CoreError::Rejected)
        };
        let path = || {
            let path = std::path::Path::new(text("file_path")?);
            let relative = if path.is_absolute() {
                path.strip_prefix(self.run.settings().workspace.path())
                    .map_err(|_| CoreError::Rejected)?
            } else {
                path
            };
            EditPath::try_from(relative.to_str().ok_or(CoreError::Rejected)?.to_owned())
                .map_err(CoreError::from)
        };
        let valid = match (self.name.as_str(), &input.intent) {
            ("edit_file", Intent::Replace { path: target, .. }) => {
                *target == path()?
                    && part(Part::Old)? == text("old_string")?
                    && part(Part::New)? == text("new_string")?
            }
            ("write_file", Intent::Write { path: target, .. }) => {
                *target == path()? && part(Part::New)? == text("contents")?
            }
            ("apply_patch", Intent::Patch { .. }) => part(Part::Patch)? == text("patch")?,
            ("edit_by_lsp", Intent::Symbol { path: target, .. }) => {
                *target == path()? && part(Part::New)? == text("new_content")?
            }
            _ => false,
        };
        if !valid {
            return Err(EditError::InvalidEvidence.into());
        }
        self.run.settings().workspace.revalidate()
    }
    pub(super) fn workspace(&self) -> Result<Workspace, CoreError> {
        self.run.check_live()?;
        self.run.settings().workspace.revalidate()?;
        Ok(self.run.settings().workspace.clone())
    }
    pub(super) fn deadline(&self, deadline: Instant) -> Instant {
        self.run
            .deadline()
            .cap(tokio::time::Instant::from_std(deadline))
            .into_std()
    }
    pub(crate) fn cancellation(&self) -> CancellationToken {
        self.run.cancel_token()
    }
}

impl ParentEdit {
    pub(super) fn replace_symbol(
        &self,
        base: &crate::edit::types::EditText,
        new: &crate::edit::types::EditText,
    ) -> Result<crate::edit::types::EditText, CoreError> {
        let selected = self.selection.as_ref().ok_or(CoreError::Rejected)?;
        splice_symbol(base, new, selected.range)
    }
}
fn splice_symbol(
    base: &crate::edit::types::EditText,
    new: &crate::edit::types::EditText,
    range: crate::sensors::coordinates::SourceRange,
) -> Result<crate::edit::types::EditText, CoreError> {
    let start = crate::sensors::coordinates::offset(base.as_str(), range.start())?;
    let end = crate::sensors::coordinates::offset(base.as_str(), range.end())?;
    let prefix = base
        .as_str()
        .get(..start)
        .ok_or(CoreError::InvalidToolOutput)?;
    let suffix = base
        .as_str()
        .get(end..)
        .ok_or(CoreError::InvalidToolOutput)?;
    let bytes = prefix
        .len()
        .checked_add(new.as_str().len())
        .and_then(|n| n.checked_add(suffix.len()))
        .filter(|n| *n <= crate::constants::limits::EDIT_TEXT_BYTES)
        .ok_or(CoreError::Limit)?;
    let mut proposed = String::with_capacity(bytes);
    proposed.push_str(prefix);
    proposed.push_str(new.as_str());
    proposed.push_str(suffix);
    Ok(crate::edit::types::EditText::try_from(proposed)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit::types::EditText;
    #[test]
    fn symbol_splice_changes_only_the_selected_duplicate_and_preserves_crlf()
    -> Result<(), Box<dyn std::error::Error>> {
        let base = EditText::try_from("🦀body\r\n🦀body\r\n".to_owned())?;
        let new = EditText::try_from("changed".to_owned())?;
        let range = serde_json::from_value(
            serde_json::json!({"start":{"line":2,"column":0},"end":{"line":2,"column":5}}),
        )?;
        assert_eq!(
            splice_symbol(&base, &new, range)?.as_str(),
            "🦀body\r\nchanged\r\n"
        );
        let invalid = serde_json::from_value(
            serde_json::json!({"start":{"line":2,"column":0},"end":{"line":2,"column":6}}),
        )?;
        assert!(splice_symbol(&base, &new, invalid).is_err());
        Ok(())
    }
}
