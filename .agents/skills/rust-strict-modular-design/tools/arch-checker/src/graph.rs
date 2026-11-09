//! The crate-level rule: top-level modules form a layered, acyclic graph.
//!
//! A module is the first path segment under `src/` (`src/run.rs` and
//! `src/run/...` are both `run`). Every `crate::<module>` reference in
//! non-test code is an edge; each edge inside a strongly connected component
//! is reported at its first occurrence, so a cycle names both directions.

use crate::finding::{Finding, Rule};
use crate::sources::Source;
use std::collections::{BTreeMap, BTreeSet};
use syn::{Attribute, UseTree, spanned::Spanned, visit::Visit};

/// First reference from one module to another: file and span.
type Edges = BTreeMap<(String, String), (String, proc_macro2::Span)>;

/// Report every dependency edge that lies on a module cycle.
pub fn module_cycles(sources: &[Source]) -> Vec<Finding> {
    let edges = collect_edges(sources);
    let graph = adjacency(&edges);
    let components = strongly_connected(&graph);
    edges
        .iter()
        .filter_map(|((from, to), (file, span))| {
            let component = components.iter().find(|c| c.contains(from))?;
            component.contains(to).then(|| {
                let members: Vec<&str> = component.iter().map(String::as_str).collect();
                Finding::new(
                    file,
                    *span,
                    Rule::ModuleCycle,
                    format!(
                        "`{from}` depends on `{to}`, which depends back on it (cycle: {}); move the shared part below both",
                        members.join(", ")
                    ),
                )
            })
        })
        .collect()
}

fn collect_edges(sources: &[Source]) -> Edges {
    let mut edges = Edges::new();
    for source in sources {
        let Some(module) = module_of(source.path()) else {
            continue;
        };
        let mut visitor = References {
            module: &module,
            file: source.path(),
            edges: &mut edges,
        };
        visitor.visit_file(source.syntax());
    }
    edges
}

/// The top-level module a crate-relative source path belongs to.
fn module_of(path: &str) -> Option<String> {
    let rest = path.strip_prefix("src/")?;
    let first = rest.split('/').next()?;
    let name = first.strip_suffix(".rs").unwrap_or(first);
    (!matches!(name, "lib" | "main")).then(|| name.to_owned())
}

struct References<'a> {
    module: &'a str,
    file: &'a str,
    edges: &'a mut Edges,
}

impl References<'_> {
    fn record(&mut self, target: &syn::Ident, span: proc_macro2::Span) {
        let target = target.to_string();
        if target != self.module {
            self.edges
                .entry((self.module.to_owned(), target))
                .or_insert_with(|| (self.file.to_owned(), span));
        }
    }

    fn record_tree(&mut self, tree: &UseTree) {
        match tree {
            UseTree::Path(path) => self.record(&path.ident, path.ident.span()),
            UseTree::Name(name) => self.record(&name.ident, name.ident.span()),
            UseTree::Rename(rename) => self.record(&rename.ident, rename.ident.span()),
            UseTree::Group(group) => group.items.iter().for_each(|item| self.record_tree(item)),
            UseTree::Glob(_) => {}
        }
    }
}

impl<'ast> Visit<'ast> for References<'_> {
    fn visit_item_mod(&mut self, node: &'ast syn::ItemMod) {
        if !is_test(&node.attrs) {
            syn::visit::visit_item_mod(self, node);
        }
    }

    fn visit_item_fn(&mut self, node: &'ast syn::ItemFn) {
        if !is_test(&node.attrs) {
            syn::visit::visit_item_fn(self, node);
        }
    }

    fn visit_use_tree(&mut self, node: &'ast UseTree) {
        if let UseTree::Path(path) = node
            && path.ident == "crate"
        {
            self.record_tree(&path.tree);
            return;
        }
        syn::visit::visit_use_tree(self, node);
    }

    fn visit_path(&mut self, node: &'ast syn::Path) {
        let mut segments = node.segments.iter();
        if let (Some(root), Some(next)) = (segments.next(), segments.next())
            && root.ident == "crate"
        {
            self.record(&next.ident, node.span());
        }
        syn::visit::visit_path(self, node);
    }
}

fn is_test(attrs: &[Attribute]) -> bool {
    attrs.iter().any(|attr| {
        attr.path().is_ident("test")
            || (attr.path().is_ident("cfg")
                && attr
                    .parse_args::<syn::Ident>()
                    .is_ok_and(|ident| ident == "test"))
    })
}

fn adjacency(edges: &Edges) -> BTreeMap<String, BTreeSet<String>> {
    let mut graph: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (from, to) in edges.keys() {
        graph.entry(from.clone()).or_default().insert(to.clone());
        graph.entry(to.clone()).or_default();
    }
    graph
}

/// Components of more than one module (Tarjan), each as a sorted set.
fn strongly_connected(graph: &BTreeMap<String, BTreeSet<String>>) -> Vec<BTreeSet<String>> {
    let mut state = Tarjan::default();
    for node in graph.keys() {
        if !state.index.contains_key(node) {
            state.visit(graph, node);
        }
    }
    state.components
}

#[derive(Default)]
struct Tarjan {
    next: usize,
    index: BTreeMap<String, usize>,
    low: BTreeMap<String, usize>,
    stack: Vec<String>,
    on_stack: BTreeSet<String>,
    components: Vec<BTreeSet<String>>,
}

impl Tarjan {
    fn visit(&mut self, graph: &BTreeMap<String, BTreeSet<String>>, node: &str) {
        self.enter(node);
        for next in graph.get(node).into_iter().flatten() {
            if !self.index.contains_key(next) {
                self.visit(graph, next);
                self.lower(node, self.low.get(next).copied());
            } else if self.on_stack.contains(next) {
                self.lower(node, self.index.get(next).copied());
            }
        }
        if self.low.get(node) == self.index.get(node) {
            self.close(node);
        }
    }

    fn enter(&mut self, node: &str) {
        self.index.insert(node.to_owned(), self.next);
        self.low.insert(node.to_owned(), self.next);
        self.next += 1;
        self.stack.push(node.to_owned());
        self.on_stack.insert(node.to_owned());
    }

    fn lower(&mut self, node: &str, candidate: Option<usize>) {
        if let (Some(candidate), Some(low)) = (candidate, self.low.get_mut(node)) {
            *low = (*low).min(candidate);
        }
    }

    fn close(&mut self, node: &str) {
        let mut component = BTreeSet::new();
        while let Some(member) = self.stack.pop() {
            self.on_stack.remove(&member);
            let done = member == node;
            component.insert(member);
            if done {
                break;
            }
        }
        if component.len() > 1 {
            self.components.push(component);
        }
    }
}
