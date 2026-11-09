//! Native diagnostic freshness and baseline comparison over detached editor facts.

use super::{coordinates::SourceRange, types::*};
use crate::{constants::limits, domain::evidence::EditPath, error::CoreError};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
mod project;
pub use project::ProjectDiagnostics;

mod severity;
pub use severity::Severity;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DiagnosticInput {
    source: DiagnosticSource,
    code: Option<DiagnosticCode>,
    severity: severity::SeverityObservation,
    range: SourceRange,
    message: SensorText,
}

/// One diagnostic's exact source span and semantic identity.
#[derive(Clone, Deserialize, Serialize)]
#[serde(from = "DiagnosticInput")]
pub struct Diagnostic {
    /// Diagnostic producer, rather than the selected UI backend.
    source: DiagnosticSource,
    /// Optional checker code.
    code: Option<DiagnosticCode>,
    /// Canonical severity.
    severity: Severity,
    /// End-exclusive range in the diagnostic's own document.
    range: SourceRange,
    /// Bounded message text, excluded from debug output.
    message: SensorText,
    #[serde(skip)]
    native_severity: bool,
}
impl From<DiagnosticInput> for Diagnostic {
    fn from(input: DiagnosticInput) -> Self {
        let (severity, native_severity) = input.severity.classify();
        Self {
            source: input.source,
            code: input.code,
            severity,
            range: input.range,
            message: input.message,
            native_severity,
        }
    }
}
impl Diagnostic {
    pub(crate) fn has_native_severity(&self) -> bool {
        self.native_severity
    }
    /// Canonical severity classification of this finding.
    pub fn severity(&self) -> Severity {
        self.severity
    }
}

/// Exact document stamp. A reused path alone cannot identify a live buffer.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DocumentStamp {
    /// Workspace-relative source path.
    pub path: EditPath,
    /// Opaque editor document identity.
    document_id: DocumentId,
    /// Captured live modification tick.
    tick: DocumentTick,
}

/// One checker's report-function generation and its actual completion evidence.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BackendReport {
    /// Stable checker identity within this editor resource.
    backend: BackendId,
    /// Generation requested by the barrier.
    requested: PublicationGeneration,
    /// Generation observed when delivering the snapshot.
    observed: PublicationGeneration,
    /// Actual document tick when this report function was acquired.
    tick: DocumentTick,
    /// True only after the report function has been called for this generation.
    reported: bool,
}

/// Language-server publication evidence; missing versions cannot certify freshness.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ServerPublication {
    /// Server captured when requesting diagnostics.
    requested_server: ServerId,
    /// Server that supplied the publication.
    observed_server: ServerId,
    /// Version requested at the document barrier.
    requested_version: Option<LspVersion>,
    /// Version actually carried by publishDiagnostics or a version-bound pull.
    published_version: Option<LspVersion>,
    /// Document tick observed at publication.
    tick: DocumentTick,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SnapshotInput {
    requested: DocumentStamp,
    observed: DocumentStamp,
    available: bool,
    backends: Vec<BackendReport>,
    server: Option<ServerPublication>,
    diagnostics: Vec<Diagnostic>,
    truncated: bool,
}

/// Bounded parse-once diagnostics, with runtime freshness evaluated separately.
#[derive(Clone, Deserialize, Serialize)]
#[serde(try_from = "SnapshotInput")]
pub struct DiagnosticSnapshot {
    requested: DocumentStamp,
    observed: DocumentStamp,
    available: bool,
    backends: Vec<BackendReport>,
    server: Option<ServerPublication>,
    diagnostics: Vec<Diagnostic>,
    truncated: bool,
}
impl TryFrom<SnapshotInput> for DiagnosticSnapshot {
    type Error = CoreError;
    fn try_from(input: SnapshotInput) -> Result<Self, CoreError> {
        if input.backends.len() > limits::SENSOR_BACKENDS
            || input.diagnostics.len() > limits::SENSOR_DIAGNOSTICS
        {
            return Err(CoreError::Limit);
        }
        let mut identities = BTreeSet::new();
        for report in &input.backends {
            if !identities.insert(&report.backend) {
                return Err(CoreError::InvalidValue {
                    field: "BackendReport",
                });
            }
        }
        let bytes = serde_json::to_vec(&input.diagnostics)
            .map_err(|_| CoreError::Limit)?
            .len();
        if bytes > limits::SENSOR_DIAGNOSTIC_BYTES {
            return Err(CoreError::Limit);
        }
        Ok(Self {
            requested: input.requested,
            observed: input.observed,
            available: input.available,
            backends: input.backends,
            server: input.server,
            diagnostics: input.diagnostics,
            truncated: input.truncated,
        })
    }
}

/// Interpretation of the live observation, independent of how many diagnostics exist.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Freshness {
    /// No usable live checker is available.
    Unavailable,
    /// Document, checker generation or server identity changed.
    Stale,
    /// Still waiting for an exact report; an empty cache is not clean evidence.
    Pending,
    /// Every captured checker and publication belongs to the requested document.
    Fresh,
    /// A bounded snapshot omitted findings and cannot certify a clean document.
    Truncated,
}

impl DiagnosticSnapshot {
    /// Render only facts bound to the exact document captured before issuance.
    /// The returned freshness is separate from tool execution success and text.
    pub fn render_for(&self, document: &DocumentStamp) -> Result<(Freshness, String), CoreError> {
        use std::fmt::Write;
        if &self.requested != document {
            return Err(CoreError::StaleOwner);
        }
        let freshness = self.freshness();
        let label = match freshness {
            Freshness::Fresh => "fresh",
            Freshness::Pending => "pending",
            Freshness::Stale => "stale",
            Freshness::Unavailable => "unavailable",
            Freshness::Truncated => "truncated",
        };
        let mut text = format!("Diagnostics for {} ({label})\n", document.path.as_str());
        if freshness != Freshness::Fresh {
            text.push_str(
                "Verification incomplete: this snapshot cannot certify a clean document.\n",
            );
        }
        if self.diagnostics.is_empty() {
            text.push_str("0 observed findings; absence alone does not establish freshness.\n");
        }
        for diagnostic in &self.diagnostics {
            let start = diagnostic.range.start();
            let severity = match diagnostic.severity {
                Severity::Error => "error",
                Severity::Warning => "warning",
                Severity::Note => "note",
                Severity::Info => "info",
            };
            writeln!(
                text,
                "[{severity}] L{}:C{}: {} (source: {})",
                start.line.get(),
                start.column.get(),
                diagnostic.message.as_str(),
                diagnostic.source.as_str()
            )
            .map_err(|_| CoreError::InvalidToolOutput)?;
            if text.len() > limits::SENSOR_DIAGNOSTIC_BYTES {
                return Err(CoreError::Limit);
            }
        }
        text.push_str("Project-wide effects are unverified.");
        if text.len() > limits::SENSOR_DIAGNOSTIC_BYTES {
            return Err(CoreError::Limit);
        }
        Ok((freshness, text))
    }
    /// Decide freshness from exact runtime evidence, never from elapsed time.
    pub fn freshness(&self) -> Freshness {
        if !self.available || self.backends.is_empty() {
            return Freshness::Unavailable;
        }
        if self.requested != self.observed
            || self.backends.iter().any(|report| {
                report.requested != report.observed || report.tick != self.requested.tick
            })
        {
            return Freshness::Stale;
        }
        if let Some(server) = &self.server {
            if server.requested_server != server.observed_server
                || server.tick != self.requested.tick
            {
                return Freshness::Stale;
            }
            match (server.requested_version, server.published_version) {
                (Some(requested), Some(published)) if requested != published => {
                    return Freshness::Stale;
                }
                (None, _) | (_, None) => return Freshness::Pending,
                _ => {}
            }
        }
        if self.backends.iter().any(|report| !report.reported) {
            return Freshness::Pending;
        }
        if self.truncated {
            return Freshness::Truncated;
        }
        Freshness::Fresh
    }

    /// Exact live document this snapshot was requested for.
    pub fn document(&self) -> &DocumentStamp {
        &self.requested
    }

    /// Borrow observations for rendering, retaining their separate freshness status.
    pub fn diagnostics(&self) -> &[Diagnostic] {
        &self.diagnostics
    }

    /// A clean verdict requires complete fresh evidence and no error severity.
    pub fn is_clean(&self) -> bool {
        self.freshness() == Freshness::Fresh
            && self
                .diagnostics
                .iter()
                .all(|d| d.severity != Severity::Error)
    }

    fn comparable_producers(&self, baseline: &Self) -> bool {
        let current: BTreeSet<_> = self.backends.iter().map(|report| &report.backend).collect();
        let previous: BTreeSet<_> = baseline
            .backends
            .iter()
            .map(|report| &report.backend)
            .collect();
        current == previous
            && match (&self.server, &baseline.server) {
                (None, None) => true,
                (Some(current), Some(previous)) => {
                    current.requested_server == previous.requested_server
                        && matches!((current.requested_version, previous.requested_version),
                        (Some(now), Some(before)) if now >= before)
                }
                _ => false,
            }
    }

    /// Compare semantic errors across trustworthy snapshots from the same producers.
    /// Restarted/replaced checkers or reversed document evidence invalidate the
    /// baseline. New report generations and position shifts remain comparable.
    pub fn compare_errors(&self, baseline: &Self) -> Option<DiagnosticDelta> {
        if self.freshness() != Freshness::Fresh
            || baseline.freshness() != Freshness::Fresh
            || self.requested.path != baseline.requested.path
            || self.requested.document_id != baseline.requested.document_id
            || self.requested.tick < baseline.requested.tick
            || !self.comparable_producers(baseline)
        {
            return None;
        }
        let mut previous = BTreeMap::new();
        for error in baseline
            .diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Error)
        {
            let key = (&error.source, &error.code, error.message.as_str());
            let count: &mut usize = previous.entry(key).or_insert(0);
            *count = count.checked_add(1)?;
        }
        let mut result = DiagnosticDelta::default();
        for error in self
            .diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Error)
        {
            let key = (&error.source, &error.code, error.message.as_str());
            if let Some(count) = previous.get_mut(&key).filter(|count| **count > 0) {
                *count = count.checked_sub(1)?;
                result.pre_existing.0 = result.pre_existing.0.checked_add(1)?;
            } else {
                result.new.0 = result.new.0.checked_add(1)?;
            }
        }
        result.resolved.0 = previous
            .values()
            .try_fold(0usize, |sum, count| sum.checked_add(*count))?;
        Some(result)
    }

    /// Deterministic signature of semantic error findings absent from `baseline`.
    /// Returns `None` unless the comparison is valid and at least one new error exists.
    pub fn new_error_signature(&self, baseline: &Self) -> Option<HealingSignature> {
        let delta = self.compare_errors(baseline)?;
        if delta.new.get() == 0 {
            return None;
        }
        let mut previous = baseline_error_pool(baseline)?;
        let mut keys = Vec::new();
        for error in self
            .diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Error)
        {
            let key = (&error.source, &error.code, error.message.as_str());
            if let Some(count) = previous.get_mut(&key).filter(|c| **c > 0) {
                *count = count.checked_sub(1)?;
            } else {
                keys.push(key);
            }
        }
        keys.sort();
        let bytes = serde_json::to_vec(&(self.requested.path.as_str(), keys)).ok()?;
        Some(HealingSignature(<[u8; 32]>::from(Sha256::digest(bytes))))
    }
}

type ErrorKey<'a> = (&'a DiagnosticSource, &'a Option<DiagnosticCode>, &'a str);

fn baseline_error_pool(baseline: &DiagnosticSnapshot) -> Option<BTreeMap<ErrorKey<'_>, usize>> {
    let mut pool = BTreeMap::new();
    for error in baseline
        .diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Error)
    {
        let key = (&error.source, &error.code, error.message.as_str());
        let count: &mut usize = pool.entry(key).or_insert(0);
        *count = count.checked_add(1)?;
    }
    Some(pool)
}

/// Position-independent digest of new semantic error findings introduced since baseline.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HealingSignature([u8; 32]);

/// Number of diagnostics, distinct from lines, bytes or healing attempts.
#[derive(Clone, Copy, Default, Debug, Eq, PartialEq, Serialize)]
pub struct DiagnosticCount(usize);
impl DiagnosticCount {
    /// Exact number of findings.
    pub fn get(self) -> usize {
        self.0
    }
}

/// Position-independent comparison of two fresh diagnostic snapshots.
#[derive(Clone, Copy, Default, Debug, Eq, PartialEq, Serialize)]
pub struct DiagnosticDelta {
    /// Errors absent from the baseline.
    pub new: DiagnosticCount,
    /// Errors also present in the baseline.
    pub pre_existing: DiagnosticCount,
    /// Baseline errors absent from the new snapshot.
    pub resolved: DiagnosticCount,
}

impl DocumentStamp {
    /// Opaque editor document identity.
    pub fn document_id(&self) -> &DocumentId {
        &self.document_id
    }
    /// Captured live modification tick.
    pub fn tick(&self) -> &DocumentTick {
        &self.tick
    }
}
