//! Trusted built-in tool definitions shared by execution and model presentation.
//! The schema asset carries no effect classification or executable code.

use super::{
    ToolRegistry,
    schema::{SchemaType, ToolDescription, ToolSchema},
};
use crate::{
    constants::limits,
    domain::{Mode, ToolName, ToolSafetyLevel},
    error::CoreError,
};
use serde::{Deserialize, Serialize, Serializer};
use serde_json::{Value, json};
use std::sync::Arc;

/// Concrete execution boundary, independent of how a tool is advertised.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolRoute {
    /// Native bounded read worker or network-read adapter.
    NativeRead,
    /// Native process/job service and its shared approval gate.
    NativeCommand,
    /// Native edit preparation/review with actual editor document primitives.
    NativeEdit,
    /// Allowlisted live editor capability, with native gate and resource revalidation.
    Editor,
}

/// Closed set of modes, parsed once from a trusted registration boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize)]
#[serde(try_from = "Vec<Mode>")]
pub struct ToolModes(u8);
fn bit(mode: Mode) -> u8 {
    match mode {
        Mode::Ask => 1,
        Mode::Plan => 2,
        Mode::Debug => 4,
        Mode::Agent => 8,
    }
}
impl TryFrom<Vec<Mode>> for ToolModes {
    type Error = CoreError;
    fn try_from(modes: Vec<Mode>) -> Result<Self, CoreError> {
        if modes.is_empty() || modes.len() > 4 {
            return Err(CoreError::InvalidValue { field: "ToolModes" });
        }
        let mut bits = 0u8;
        for mode in modes {
            let flag = bit(mode);
            if bits & flag != 0 {
                return Err(CoreError::InvalidValue { field: "ToolModes" });
            }
            bits |= flag;
        }
        Ok(Self(bits))
    }
}
impl ToolModes {
    /// Whether this definition permits the captured run mode.
    pub fn permits(self, mode: Mode) -> bool {
        self.0 & bit(mode) != 0
    }
}
impl Serialize for ToolModes {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        [Mode::Ask, Mode::Plan, Mode::Debug, Mode::Agent]
            .into_iter()
            .filter(|mode| self.permits(*mode))
            .collect::<Vec<_>>()
            .serialize(serializer)
    }
}

/// Immutable presentation metadata. It confers no execution or approval rights.
#[derive(Clone, Serialize)]
pub struct ToolPresentation {
    description: ToolDescription,
    parameters: ToolSchema,
    modes: ToolModes,
    route: ToolRoute,
}
impl ToolPresentation {
    /// Model-visible description.
    pub fn description(&self) -> &str {
        self.description.as_str()
    }
    /// Native structural argument schema; executor-specific validation follows.
    pub fn parameters(&self) -> &ToolSchema {
        &self.parameters
    }
    /// Allowed captured modes.
    pub fn modes(&self) -> ToolModes {
        self.modes
    }
    /// Executor boundary required by this definition.
    pub fn route(&self) -> ToolRoute {
        self.route
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema_version: u8,
    tools: Vec<Definition>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Definition {
    name: ToolName,
    description: ToolDescription,
    parameters: ToolSchema,
    aliases: Vec<ToolName>,
    modes: ToolModes,
}
struct Policy {
    safety: ToolSafetyLevel,
    modes: ToolModes,
    route: ToolRoute,
}
fn policy(name: &ToolName) -> Result<Policy, CoreError> {
    use ToolRoute::*;
    use ToolSafetyLevel::*;
    let (safety, modes, route) = match name.as_str() {
        "find_files" | "read_file" | "skill" | "webfetch" => (SafeReadOnly, 15, NativeRead),
        "list_files" | "workspace_grep" | "git_status" | "git_diff" | "git_log" | "git_blame"
        | "git_branches" | "git_stashes" => (SafeReadOnly, 15, NativeCommand),
        "bash" | "git_stage" | "git_unstage" | "git_commit" | "git_branch" | "git_stash" => {
            (ExecutesArbitraryCode, 8, NativeCommand)
        }
        "edit_file" | "write_file" | "apply_patch" => (MutatesState, 8, NativeEdit),
        "edit_by_lsp" => (MutatesState, 8, NativeEdit),
        "lsp_diagnostics"
        | "lsp_find_symbol"
        | "lsp_project_skeleton"
        | "read_file_symbols"
        | "read_symbol" => (SafeReadOnly, 15, Editor),
        "debug_get_context"
        | "debug_list_breakpoints"
        | "debug_scope"
        | "debug_stack"
        | "debug_threads"
        | "debug_modules"
        | "debug_sources" => (SafeReadOnly, 12, Editor),
        "debug_up"
        | "debug_down"
        | "debug_set_breakpoint"
        | "debug_clear_breakpoint"
        | "debug_toggle_breakpoint" => (MutatesState, 12, Editor),
        "debug_start" | "debug_eval" | "debug_watch" | "debug_step_in" | "debug_step_out"
        | "debug_step_over" | "debug_continue" | "debug_pause" | "debug_restart" | "debug_kill"
        | "debug_disconnect" | "debug_quit" => (ExecutesArbitraryCode, 12, Editor),
        _ => return Err(CoreError::Unavailable),
    };
    Ok(Policy {
        safety,
        modes: ToolModes(modes),
        route,
    })
}

impl ToolRegistry {
    /// Complete runtime catalog, including private execution helpers that are
    /// never advertised to the model. Composition installs one per application.
    pub fn standard() -> Result<Self, CoreError> {
        let mut registry = Self::builtins()?;
        registry.register_listing()?;
        registry.register_grep()?;
        registry.register_git_status()?;
        registry.register_git_reads()?;
        registry.register_git_mutations()?;
        registry.register_editor(ToolName::try_from("editor_edit".to_owned())?, vec![])?;
        Ok(registry)
    }

    /// Parse the complete built-in catalog atomically. Schema metadata cannot alter native policy.
    pub fn builtins() -> Result<Self, CoreError> {
        let source = include_str!("../../assets/tools.json");
        if source.len() > limits::TOOL_MANIFEST_BYTES {
            return Err(CoreError::Limit);
        }
        let manifest: Manifest =
            serde_json::from_str(source).map_err(|_| CoreError::InvalidValue {
                field: "ToolManifest",
            })?;
        if manifest.schema_version != 1 || manifest.tools.len() > limits::TOOL_DEFINITIONS {
            return Err(CoreError::Limit);
        }
        let mut registry = Self::default();
        for definition in manifest.tools {
            let profile = policy(&definition.name)?;
            if profile.modes != definition.modes
                || definition.parameters.kind() != SchemaType::Object
                || definition.aliases.len() > limits::TOOL_DEFINITIONS
                || registry.definitions.contains_key(&definition.name)
            {
                return Err(CoreError::InvalidValue {
                    field: "ToolManifest",
                });
            }
            registry.register(
                definition.name.clone(),
                definition.aliases.clone(),
                profile.safety,
            )?;
            let descriptor = registry
                .definitions
                .get_mut(&definition.name)
                .ok_or(CoreError::Unavailable)?;
            descriptor.presentation = Some(Arc::new(ToolPresentation {
                description: definition.description,
                parameters: definition.parameters,
                modes: profile.modes,
                route: profile.route,
            }));
        }
        Ok(registry)
    }

    /// Snapshot only canonical model definitions available to this captured mode/editor.
    /// Missing optional editor capabilities suppress their definitions; execution rechecks them.
    pub fn model_tools(
        &self,
        mode: Mode,
        editor_available: &[ToolName],
    ) -> Result<Vec<Value>, CoreError> {
        if editor_available.len() > limits::TOOL_DEFINITIONS {
            return Err(CoreError::Limit);
        }
        let mut visible: Vec<_> = self
            .definitions
            .values()
            .filter_map(|descriptor| {
                let presentation = descriptor.presentation.as_ref()?;
                (presentation.modes.permits(mode)
                    && (!matches!(
                        presentation.route,
                        ToolRoute::Editor | ToolRoute::NativeEdit
                    ) || editor_available.contains(descriptor.name())))
                .then_some((descriptor, presentation))
            })
            .collect();
        visible.sort_by(|(left, _), (right, _)| left.name().as_str().cmp(right.name().as_str()));
        Ok(visible.into_iter().map(|(descriptor, presentation)| json!({"type":"function", "function":{
            "name":descriptor.name(), "description":presentation.description, "parameters":presentation.parameters
        }})).collect())
    }
}
