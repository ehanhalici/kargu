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
fn debugger_snapshot_validates_epoch_and_renders_cleanly() -> TestResult {
    use kargu_core::sensors::debugger::{
        DebugContextSnapshot, DebugStatus, StackFrameDto, VariableDto,
    };
    use kargu_core::sensors::types::{
        DebugConnectionId, FrameId, SensorText, StopGeneration, ThreadId,
    };

    let conn = DebugConnectionId::try_from("conn-1".to_string())?;
    let foreign = DebugConnectionId::try_from("conn-2".to_string())?;
    let snap = DebugContextSnapshot {
        connection_id: conn.clone(),
        stop_generation: StopGeneration::try_from(1)?,
        thread_id: ThreadId::try_from(1)?,
        status: DebugStatus::Stopped,
        current_frame: Some(StackFrameDto {
            id: FrameId::try_from(0)?,
            name: "main".to_string(),
            thread_id: ThreadId::try_from(1)?,
            file: None,
            range: None,
        }),
        local_variables: vec![VariableDto {
            name: "x".to_string(),
            value: SensorText::try_from("42".to_string())?,
            var_type: Some("i32".to_string()),
            children_reference: None,
        }],
        stack_frames: vec![],
        threads: vec![],
    };

    assert!(
        snap.validate_epoch(&conn, StopGeneration::try_from(1)?)
            .is_ok()
    );
    assert!(
        snap.validate_epoch(&foreign, StopGeneration::try_from(1)?)
            .is_err()
    );
    assert!(
        snap.validate_epoch(&conn, StopGeneration::try_from(2)?)
            .is_err()
    );

    let summary = snap.render_summary(5);
    assert!(summary.contains("stop_epoch=1"));
    assert!(summary.contains("main"));
    assert!(summary.contains("x (i32): 42"));
    Ok(())
}

#[test]
fn mention_lexer_and_context_xml_rendering() -> TestResult {
    use kargu_core::edit::types::EditPath;
    use kargu_core::sensors::mentions::{
        ContextAttachment, MentionLexer, MentionTarget, ResolutionStatus,
    };
    use kargu_core::sensors::types::SensorText;
    use std::path::PathBuf;

    let input = "Check @file:\"src/nested path/foo.rs\" and @sym:calculate with @git:diff inside code ``` @file:ignore.rs ``` user@domain.com";
    let lexer = MentionLexer::new(input);
    let mentions = lexer.parse();
    assert_eq!(mentions.len(), 3);
    assert_eq!(
        mentions[0].target,
        MentionTarget::File {
            path: EditPath::try_from("src/nested path/foo.rs".to_string())?
        }
    );
    assert_eq!(
        mentions[1].target,
        MentionTarget::Symbol {
            name: "calculate".to_string()
        }
    );
    assert_eq!(mentions[2].target, MentionTarget::GitDiff);

    let attachment = ContextAttachment {
        target_id: "mention-1".to_string(),
        target: mentions[0].target.clone(),
        status: ResolutionStatus::Resolved,
        path: Some(PathBuf::from("/workspace/foo.rs")),
        document_id: None,
        revision: Some(3),
        hash: None,
        range: None,
        content: SensorText::try_from("fn foo() -> bool { true }".to_string())?,
        dirty: false,
        truncated: false,
        byte_count: 26,
        token_estimate: ContextAttachment::estimate_tokens(26),
    };

    let xml = attachment.render_xml();
    assert!(xml.contains("<context_attachment target_id=\"mention-1\""));
    assert!(xml.contains("fn foo() -&gt; bool { true }"));
    assert!(xml.contains("</context_attachment>"));
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
