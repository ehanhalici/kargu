//! Acceptance sources; deferred with the final 3/4/5 gate.
use super::*;
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;
fn range(start: u64, end: u64) -> Value {
    json!({"start":{"line":start,"column":0},"end":{"line":end,"column":0}})
}
fn node(name: &str, start: u64, end: u64) -> Value {
    json!({"name":name,"kind":"function","range":range(start,end),"children":[]})
}
fn tree(nodes: Vec<Value>, truncated: bool) -> Result<DocumentSymbols, serde_json::Error> {
    serde_json::from_value(json!({"symbols":nodes,"truncated":truncated}))
}
fn name(value: &str) -> Result<SymbolName, CoreError> {
    SymbolName::try_from(value.to_owned())
}

#[test]
fn document_tree_limits_include_hidden_nodes_and_exact_selection_ranges() -> TestResult {
    let mut root = node("root", 1, 4);
    root["children"] = json!([node("foreign", 5, 6)]);
    assert!(tree(vec![root], false).is_err());
    let mut node = node("alpha", 1, 4);
    node["selection_range"] = range(3, 6);
    assert!(tree(vec![node], false).is_err());
    assert!(tree(vec![self::node("alpha\nforged output", 1, 2)], false).is_err());
    assert!(
        tree(
            vec![self::node("alpha", 1, 2); limits::SENSOR_SYMBOLS.saturating_add(1)],
            false
        )
        .is_err()
    );
    let mut nested = self::node("deep", 1, 2);
    for _ in 0..limits::SENSOR_SYMBOL_DEPTH.saturating_add(1) {
        let mut parent = self::node("parent", 1, 2);
        parent["children"] = json!([nested]);
        nested = parent;
    }
    assert!(tree(vec![nested], false).is_err());
    let large = "x".repeat(limits::SENSOR_SYMBOL_NAME_BYTES);
    assert!(tree(vec![self::node(&large, 1, 2); 160], false).is_err());
    assert!(format!("{:?}", name("secret_identifier")?).contains("REDACTED"));
    Ok(())
}

#[test]
fn native_selection_never_chooses_a_first_ambiguous_or_truncated_match() -> TestResult {
    let mut a = node("A", 1, 8);
    a["kind"] = json!("class");
    a["children"] = json!([node("compute", 2, 4)]);
    let mut b = node("B", 9, 18);
    b["kind"] = json!("struct");
    b["children"] = json!([node("compute", 10, 12)]);
    let symbols = tree(vec![a, b], false)?;
    let ambiguous = symbols.select(&name("COMPUTE")?, Some("Function"))?;
    assert!(matches!(&ambiguous,SymbolLookup::Ambiguous(items) if items.len()==2));
    assert!(ambiguous.refusal_text().contains("A::compute"));
    assert!(ambiguous.refusal_text().contains("B::compute"));
    let SymbolLookup::Unique(selected) = symbols.select(&name("A.compute")?, Some("function"))?
    else {
        return Err("qualified symbol was not selected".into());
    };
    assert_eq!(selected.range.start().line.get(), 2);
    assert!(matches!(
        symbols.select(&name("missing")?, Some("type"))?,
        SymbolLookup::NotFound
    ));
    let clipped = tree(vec![node("alpha", 1, 2)], true)?;
    assert!(matches!(
        clipped.select(&name("alpha")?, None)?,
        SymbolLookup::Truncated
    ));
    let mut empty = node("empty", 1, 1);
    empty["range"] = json!({"start":{"line":1,"column":0},"end":{"line":1,"column":0}});
    assert!(
        tree(vec![empty], false)?
            .select(&name("empty")?, None)
            .is_err()
    );
    Ok(())
}

#[test]
fn rendered_output_is_bounded_without_discarding_the_selection_graph() -> TestResult {
    let nodes = (0..160)
        .map(|index| node(&format!("name_{index}_{}", "a".repeat(180)), 1, 2))
        .collect();
    let symbols = tree(nodes, false)?;
    let output = symbols.render_tree();
    assert!(output.len() <= limits::SENSOR_TEXT_BYTES);
    assert!(output.contains("truncated"));
    let query = format!("name_159_{}", "a".repeat(180));
    assert!(matches!(
        symbols.select(&name(&query)?, None)?,
        SymbolLookup::Unique(_)
    ));
    Ok(())
}

#[test]
fn source_document_and_transport_generation_must_match_before_rendering() -> TestResult {
    let doc = json!({"path":"file.rs","document_id":"doc","tick":7});
    let source = json!({"kind":"eglot","server":"transport-1","version":3,"encoding":"utf-16"});
    let mut value = json!({"requested":doc,"observed":doc,"source":source,"observed_source":source,
        "symbols":{"symbols":[node("alpha",1,2)],"truncated":false}});
    let expected_doc: DocumentStamp = serde_json::from_value(doc)?;
    let expected_source: LanguageSource = serde_json::from_value(source)?;
    assert!(
        serde_json::from_value::<SymbolSnapshot>(value.clone())?
            .fresh_for(&expected_doc, &expected_source)
    );
    for (key, field, replacement) in [
        ("observed", "tick", json!(8)),
        ("observed_source", "version", json!(4)),
        ("observed_source", "server", json!("transport-2")),
        ("observed_source", "encoding", json!("utf-8")),
    ] {
        let mut stale = value.clone();
        stale[key][field] = replacement;
        assert!(
            !serde_json::from_value::<SymbolSnapshot>(stale)?
                .fresh_for(&expected_doc, &expected_source)
        );
    }
    value["observed"]["document_id"] = json!("replacement-document");
    assert!(
        !serde_json::from_value::<SymbolSnapshot>(value)?
            .fresh_for(&expected_doc, &expected_source)
    );
    Ok(())
}

#[test]
fn symbol_body_counts_unicode_scalars_and_rejects_false_full_or_foreign_spans() -> TestResult {
    let doc: DocumentStamp =
        serde_json::from_value(json!({"path":"file.rs","document_id":"doc","tick":7}))?;
    let source: LanguageSource =
        serde_json::from_value(json!({"kind":"imenu","provider":"provider-1"}))?;
    let selected = SelectedSymbol {
        name: name("alpha")?,
        kind: SymbolKind::Function,
        range: serde_json::from_value(
            json!({"start":{"line":2,"column":3},"end":{"line":3,"column":1}}),
        )?,
    };
    let value = json!({"document":doc,"source":source,"range":selected.range,"text":"🦀\r\nβ","truncated":false});
    let body: SymbolBody = serde_json::from_value(value.clone())?;
    assert!(body.render(&doc, &source, &selected)?.contains("🦀\r\nβ"));
    for wrong in ["🦀", "🦀\r\nβx"] {
        let mut changed = value.clone();
        changed["text"] = json!(wrong);
        assert!(
            serde_json::from_value::<SymbolBody>(changed)?
                .render(&doc, &source, &selected)
                .is_err()
        );
    }
    let mut clipped = value.clone();
    clipped["text"] = json!("🦀");
    clipped["truncated"] = json!(true);
    assert!(
        serde_json::from_value::<SymbolBody>(clipped)?
            .render(&doc, &source, &selected)?
            .contains("truncated")
    );
    let mut foreign = value;
    foreign["source"]["provider"] = json!("provider-2");
    assert!(
        serde_json::from_value::<SymbolBody>(foreign)?
            .render(&doc, &source, &selected)
            .is_err()
    );
    Ok(())
}
