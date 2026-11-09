//! Live-editor evidence contracts, exercised at the final migration acceptance gate.

use kargu_core::sensors::{
    coordinates::{Position, SourceRange, offset},
    diagnostics::{DiagnosticSnapshot, Freshness},
    types::{ScalarColumn, SourceLine},
};
use serde_json::{Value, json};

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn snapshot() -> Value {
    let stamp = json!({"path":"src/main.rs", "document_id":"document-1", "tick":7});
    json!({
        "requested":stamp, "observed":stamp,
        "available":true, "truncated":false, "diagnostics":[],
        "backends":[{"backend":"eglot", "requested":3, "observed":3, "tick":7, "reported":true}],
        "server":{"requested_server":"server-1", "observed_server":"server-1",
                  "requested_version":2, "published_version":2, "tick":7}
    })
}

#[test]
fn empty_diagnostics_need_exact_document_checker_and_versioned_publication() -> TestResult {
    let fresh: DiagnosticSnapshot = serde_json::from_value(snapshot())?;
    assert_eq!(fresh.freshness(), Freshness::Fresh);
    assert!(fresh.is_clean());
    for (pointer, replacement, expected) in [
        ("/observed/tick", json!(8), Freshness::Stale),
        (
            "/observed/document_id",
            json!("replaced-document"),
            Freshness::Stale,
        ),
        ("/backends/0/observed", json!(4), Freshness::Stale),
        ("/backends/0/reported", json!(false), Freshness::Pending),
        ("/server/published_version", Value::Null, Freshness::Pending),
        ("/server/published_version", json!(1), Freshness::Stale),
        (
            "/server/observed_server",
            json!("foreign-server"),
            Freshness::Stale,
        ),
        ("/available", json!(false), Freshness::Unavailable),
        ("/truncated", json!(true), Freshness::Truncated),
    ] {
        let mut input = snapshot();
        *input
            .pointer_mut(pointer)
            .ok_or("invalid fixture pointer")? = replacement;
        let parsed: DiagnosticSnapshot = serde_json::from_value(input)?;
        assert_eq!(parsed.freshness(), expected);
        assert!(!parsed.is_clean());
    }
    Ok(())
}

#[test]
fn semantic_baseline_keeps_duplicate_counts_and_ignores_position_shifts() -> TestResult {
    let diagnostic = json!({
        "source":"compiler", "code":"E1", "severity":"error", "message":"synthetic error",
        "range":{"start":{"line":1,"column":0},"end":{"line":1,"column":1}}
    });
    let mut before = snapshot();
    before["diagnostics"] = json!([diagnostic, diagnostic]);
    let baseline: DiagnosticSnapshot = serde_json::from_value(before)?;
    let mut after = snapshot();
    after["requested"]["tick"] = json!(8);
    after["observed"]["tick"] = json!(8);
    after["backends"][0]["tick"] = json!(8);
    after["server"]["tick"] = json!(8);
    let mut shifted = diagnostic;
    shifted["range"]["start"]["line"] = json!(5);
    shifted["range"]["end"]["line"] = json!(5);
    after["diagnostics"] = json!([shifted]);
    let observed: DiagnosticSnapshot = serde_json::from_value(after)?;
    let delta = observed
        .compare_errors(&baseline)
        .ok_or("fresh baseline missing")?;
    assert_eq!(delta.new.get(), 0);
    assert_eq!(delta.pre_existing.get(), 1);
    assert_eq!(delta.resolved.get(), 1);
    Ok(())
}

#[test]
fn fresh_baselines_require_the_same_producer_cohort_and_forward_document_evidence() -> TestResult {
    let variants = [
        "server_restart",
        "server_removed",
        "backend_replaced",
        "backend_added",
        "backend_removed",
        "tick_reversed",
        "version_reversed",
    ];
    for variant in variants {
        let mut before = snapshot();
        let mut after = snapshot();
        match variant {
            "server_restart" => {
                after["server"]["requested_server"] = json!("restarted-server");
                after["server"]["observed_server"] = json!("restarted-server");
            }
            "server_removed" => after["server"] = Value::Null,
            "backend_replaced" => after["backends"][0]["backend"] = json!("another-checker"),
            "backend_added" => after["backends"].as_array_mut().ok_or("backends")?.push(
                json!({"backend":"additional-checker","requested":9,"observed":9,"tick":7,"reported":true})),
            "backend_removed" => before["backends"].as_array_mut().ok_or("backends")?.push(
                json!({"backend":"removed-checker","requested":9,"observed":9,"tick":7,"reported":true})),
            "tick_reversed" => {
                before["requested"]["tick"] = json!(8);
                before["observed"]["tick"] = json!(8);
                before["backends"][0]["tick"] = json!(8);
                before["server"]["tick"] = json!(8);
            }
            "version_reversed" => {
                before["server"]["requested_version"] = json!(3);
                before["server"]["published_version"] = json!(3);
            }
            _ => return Err("invalid fixture".into()),
        }
        let baseline: DiagnosticSnapshot = serde_json::from_value(before)?;
        let observed: DiagnosticSnapshot = serde_json::from_value(after)?;
        assert_eq!(baseline.freshness(), Freshness::Fresh);
        assert_eq!(observed.freshness(), Freshness::Fresh);
        assert!(observed.compare_errors(&baseline).is_none(), "{variant}");
    }
    Ok(())
}

#[test]
fn baseline_producer_order_and_new_report_generations_do_not_invalidate_comparison() -> TestResult {
    let mut before = snapshot();
    before["backends"]
        .as_array_mut()
        .ok_or("backends")?
        .push(json!({"backend":"checker-2","requested":9,"observed":9,"tick":7,"reported":true}));
    let mut after = before.clone();
    after["requested"]["tick"] = json!(8);
    after["observed"]["tick"] = json!(8);
    after["server"]["tick"] = json!(8);
    after["server"]["requested_version"] = json!(3);
    after["server"]["published_version"] = json!(3);
    let backends = after["backends"].as_array_mut().ok_or("backends")?;
    backends.reverse();
    for backend in backends {
        backend["tick"] = json!(8);
        backend["requested"] = json!(10);
        backend["observed"] = json!(10);
    }
    let baseline: DiagnosticSnapshot = serde_json::from_value(before)?;
    let observed: DiagnosticSnapshot = serde_json::from_value(after)?;
    let delta = observed
        .compare_errors(&baseline)
        .ok_or("stable producer comparison")?;
    assert_eq!(delta.new.get(), 0);
    assert_eq!(delta.pre_existing.get(), 0);
    assert_eq!(delta.resolved.get(), 0);
    Ok(())
}

#[test]
fn scalar_positions_preserve_emoji_tabs_crlf_and_final_empty_line() -> TestResult {
    let text = "a🦀\t\r\nb\n";
    let position = |line, column| -> Result<Position, kargu_core::error::CoreError> {
        Ok(Position {
            line: SourceLine::try_from(line)?,
            column: ScalarColumn::try_from(column)?,
        })
    };
    assert_eq!(offset(text, position(1, 2)?)?, 5);
    assert_eq!(offset(text, position(1, 3)?)?, 6);
    assert_eq!(offset(text, position(3, 0)?)?, text.len());
    assert!(offset(text, position(1, 4)?).is_err());
    assert!(offset(text, position(4, 0)?).is_err());
    assert_eq!(offset("\r", position(1, 1)?)?, 1);
    assert!(
        serde_json::from_value::<SourceRange>(json!({
            "start":{"line":2,"column":0},"end":{"line":1,"column":0}
        }))
        .is_err()
    );
    Ok(())
}

#[test]
fn symbols_tree_and_xref_formatting_preserves_bounds() -> TestResult {
    use kargu_core::sensors::symbols::{DocumentSymbols, XrefLocation, format_xrefs};
    use std::path::PathBuf;

    let range: SourceRange = serde_json::from_value(json!({
        "start": {"line": 1, "column": 0},
        "end": {"line": 10, "column": 0}
    }))?;

    let doc_symbols: DocumentSymbols = serde_json::from_value(json!({"symbols":[{
        "name":"MyClass","kind":"class","range":range,"selection_range":range,"children":[{
            "name":"my_method","kind":"method","range":range,"children":[]
        }]}],"truncated":false}))?;

    let rendered = doc_symbols.render_tree();
    assert!(rendered.contains("Class MyClass"));
    assert!(rendered.contains("Method my_method"));

    let xrefs = vec![XrefLocation {
        path: PathBuf::from("src/lib.rs"),
        range,
        summary: None,
    }];
    let xref_text = format_xrefs(&xrefs, 5);
    assert!(xref_text.contains("src/lib.rs:L1:C0-L10:C0"));
    Ok(())
}

#[test]
fn skeleton_formatting_preserves_bounds_and_explicit_caps() -> TestResult {
    use kargu_core::sensors::symbols::{
        MaxPerFile, MaxSymbols, ProjectSkeleton, SkeletonLimits, SkeletonSource, SkeletonSymbol,
        SkeletonTruncated, SymbolKind, SymbolName,
    };
    use kargu_core::sensors::types::SourceLine;
    use std::path::PathBuf;

    let root = PathBuf::from("/workspace/project");
    let mut skeleton =
        ProjectSkeleton::new(root.clone(), SkeletonSource::new("test-lsp".to_string()));

    let sym1 = SkeletonSymbol::new(
        SymbolName::try_from("alpha".to_string())?,
        SymbolKind::Function,
        SourceLine::try_from(10)?,
    );
    let sym2 = SkeletonSymbol::new(
        SymbolName::try_from("beta".to_string())?,
        SymbolKind::Variable,
        SourceLine::try_from(25)?,
    );
    let sym3 = SkeletonSymbol::new(
        SymbolName::try_from("gamma".to_string())?,
        SymbolKind::Class,
        SourceLine::try_from(50)?,
    );

    skeleton.add_file(root.join("src/lib.rs"), vec![sym1, sym2]);
    skeleton.add_file(root.join("src/main.rs"), vec![sym3]);

    let limits = SkeletonLimits::new(MaxSymbols::new(10), MaxPerFile::new(5));
    let text = skeleton.render(limits)?;
    assert!(
        text.as_str()
            .starts_with("# Project skeleton (LSP: test-lsp)")
    );
    assert!(text.as_str().contains("# root: /workspace/project"));
    assert!(text.as_str().contains("# 2 files, 3 symbols"));
    assert!(text.as_str().contains("src/lib.rs:"));
    assert!(text.as_str().contains("  alpha (Function) :10"));
    assert!(text.as_str().contains("  beta (Variable) :25"));
    assert!(text.as_str().contains("src/main.rs:"));
    assert!(text.as_str().contains("  gamma (Class) :50"));

    let cap_limits = SkeletonLimits::new(MaxSymbols::new(2), MaxPerFile::new(2));
    let cap_text = skeleton.render(cap_limits)?;
    assert!(cap_text.as_str().contains("# symbol cap reached (2)"));
    assert!(cap_text.as_str().contains("  alpha (Function) :10"));
    assert!(cap_text.as_str().contains("  beta (Variable) :25"));
    assert!(!cap_text.as_str().contains("src/main.rs:"));

    let per_file_limits = SkeletonLimits::new(MaxSymbols::new(10), MaxPerFile::new(1));
    let per_file_text = skeleton.render(per_file_limits)?;
    assert!(per_file_text.as_str().contains("  alpha (Function) :10"));
    assert!(per_file_text.as_str().contains("  ... (1 more hidden)"));
    assert!(per_file_text.as_str().contains("  gamma (Class) :50"));

    skeleton.set_truncated(SkeletonTruncated::new(true));
    let trunc_text = skeleton.render(limits)?;
    assert!(trunc_text.as_str().contains("# symbol cap reached (10)"));

    Ok(())
}

#[test]
fn project_diagnostics_preserve_cache_uncertainty_and_supersede_only_the_same_fresh_source()
-> TestResult {
    use kargu_core::sensors::diagnostics::ProjectDiagnostics;
    let cached = json!({"path":"src/main.rs","source":"eglot","code":null,"severity":"error",
        "line":2,"column":null,"message":"cached finding"});
    let project = |live: Vec<Value>,
                   cached: Vec<Value>,
                   truncated: bool|
     -> Result<ProjectDiagnostics, serde_json::Error> {
        serde_json::from_value(json!({"live":live,"cached":cached,"truncated":truncated}))
    };
    let (status, text) = project(vec![snapshot()], vec![cached.clone()], false)?.render()?;
    assert_eq!(status, Freshness::Fresh);
    assert!(!text.contains("cached finding"));
    assert!(text.contains("project-wide effects are unverified"));
    let mut other = cached.clone();
    other["source"] = json!("other-checker");
    let (status, text) = project(vec![snapshot()], vec![other.clone(), other], false)?.render()?;
    assert_eq!(status, Freshness::Unavailable);
    assert_eq!(text.matches("cached finding").count(), 1);
    assert!(text.contains("C?"));
    assert!(text.contains("unversioned cache"));
    let mut stale = snapshot();
    stale["observed"]["tick"] = json!(8);
    let (status, text) = project(vec![stale], vec![cached], false)?.render()?;
    assert_eq!(status, Freshness::Stale);
    assert!(text.contains("cached finding"));
    assert_eq!(
        project(vec![], vec![], true)?.render()?.0,
        Freshness::Truncated
    );
    assert_eq!(
        project(vec![], vec![], false)?.render()?.0,
        Freshness::Unavailable
    );
    assert!(project(vec![snapshot(), snapshot()], vec![], false).is_err());
    Ok(())
}

#[test]
fn raw_flymake_severity_preserves_errors_and_rejects_unknown_ranks() -> TestResult {
    use kargu_core::sensors::diagnostics::Severity;
    for (input, expected) in [
        (json!("error"), Severity::Error),
        (json!("warning"), Severity::Warning),
        (json!("note"), Severity::Note),
        (json!("info"), Severity::Info),
        (json!({"flymake":1}), Severity::Note),
        (json!({"flymake":2}), Severity::Warning),
        (json!({"flymake":3}), Severity::Error),
        (json!({"flymake":9}), Severity::Error),
    ] {
        let parsed: Severity = serde_json::from_value(input)?;
        assert_eq!(parsed, expected);
    }
    for invalid in [
        json!(null),
        json!({"flymake":null}),
        json!({"flymake":0}),
        json!({"flymake":-1}),
        json!({"flymake":2.5}),
        json!({"flymake":u64::MAX}),
        json!({"flymake":3,"clean":true}),
        json!("custom"),
    ] {
        assert!(serde_json::from_value::<Severity>(invalid).is_err());
    }
    Ok(())
}
