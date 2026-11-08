//! Native aggregation of live snapshots and explicitly unversioned file cache.
use super::*;
use std::fmt::Write;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct CachedFinding {
    path: EditPath,
    source: DiagnosticSource,
    code: Option<DiagnosticCode>,
    severity: Severity,
    line: SourceLine,
    column: Option<ScalarColumn>,
    message: SensorText,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ProjectInput {
    live: Vec<DiagnosticSnapshot>,
    cached: Vec<CachedFinding>,
    truncated: bool,
}

/// Bounded observations, not a project-wide build or verification certificate.
#[derive(Deserialize)]
#[serde(try_from = "ProjectInput")]
pub struct ProjectDiagnostics(ProjectInput);
impl TryFrom<ProjectInput> for ProjectDiagnostics {
    type Error = CoreError;
    fn try_from(value: ProjectInput) -> Result<Self, CoreError> {
        if value.live.len() > limits::EDIT_FILES
            || value.cached.len() > limits::SENSOR_DIAGNOSTICS
            || serde_json::to_vec(&value)
                .map_err(|_| CoreError::Limit)?
                .len()
                > limits::SENSOR_DIAGNOSTIC_BYTES
        {
            return Err(CoreError::Limit);
        }
        let mut paths = BTreeSet::new();
        for snapshot in &value.live {
            if !paths.insert(snapshot.document().path.as_str()) {
                return Err(CoreError::InvalidToolOutput);
            }
        }
        Ok(Self(value))
    }
}
/// Only a fresh report from the same producer for the same file supersedes a cached finding.
fn supersedes(snapshot: &DiagnosticSnapshot, finding: &CachedFinding) -> bool {
    snapshot.freshness() == Freshness::Fresh
        && snapshot.document().path == finding.path
        && snapshot
            .backends
            .iter()
            .any(|backend| backend.backend.as_str() == finding.source.as_str())
}
impl ProjectDiagnostics {
    /// Aggregate and render in Rust, preserving unversioned cache uncertainty.
    pub fn render(&self) -> Result<(Freshness, String), CoreError> {
        let mut text = String::from(
            "Available project diagnostic observations. Unopened/unreported files and project-wide effects are unverified.\n",
        );
        let mut statuses = Vec::new();
        if self.0.truncated {
            statuses.push(Freshness::Truncated);
        }
        let mut live: Vec<_> = self.0.live.iter().collect();
        live.sort_by_key(|snapshot| snapshot.document().path.as_str());
        for snapshot in &live {
            let (status, section) = snapshot.render_for(snapshot.document())?;
            statuses.push(status);
            text.push_str(&section);
            text.push('\n');
            if text.len() > limits::SENSOR_DIAGNOSTIC_BYTES {
                return Err(CoreError::Limit);
            }
        }
        let mut seen = BTreeSet::new();
        for finding in &self.0.cached {
            if live.iter().any(|snapshot| supersedes(snapshot, finding)) {
                continue;
            }
            let key = (
                finding.path.as_str(),
                finding.source.as_str(),
                &finding.code,
                finding.severity,
                finding.line,
                finding.column,
                finding.message.as_str(),
            );
            if !seen.insert(key) {
                continue;
            }
            statuses.push(Freshness::Unavailable);
            let column = finding
                .column
                .map_or_else(|| "?".to_owned(), |column| column.get().to_string());
            writeln!(
                text,
                "{} L{}:C{} [{:?}] {} (source: {}; unversioned cache, freshness unavailable)",
                finding.path.as_str(),
                finding.line.get(),
                column,
                finding.severity,
                finding.message.as_str(),
                finding.source.as_str()
            )
            .map_err(|_| CoreError::InvalidToolOutput)?;
            if text.len() > limits::SENSOR_DIAGNOSTIC_BYTES {
                return Err(CoreError::Limit);
            }
        }
        let status = [
            Freshness::Truncated,
            Freshness::Stale,
            Freshness::Pending,
            Freshness::Unavailable,
        ]
        .into_iter()
        .find(|status| statuses.contains(status))
        .unwrap_or(if statuses.is_empty() {
            Freshness::Unavailable
        } else {
            Freshness::Fresh
        });
        if status != Freshness::Fresh {
            text.push_str("Verification incomplete; cached, unavailable or omitted observations do not certify a clean project.");
        }
        if text.len() > limits::SENSOR_DIAGNOSTIC_BYTES {
            return Err(CoreError::Limit);
        }
        Ok((status, text))
    }
}
