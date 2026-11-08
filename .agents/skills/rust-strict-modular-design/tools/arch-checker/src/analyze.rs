//! Applying the architecture rules to one parsed file.  Pure: no I/O.

use crate::{
    config::Config,
    finding::{Finding, Rule},
    nesting, types,
};
use std::collections::BTreeSet;
use syn::{Attribute, Fields, Signature, UseTree, Visibility, spanned::Spanned, visit::Visit};

/// Paths a pure domain module must never reach.
const IMPURE: &[&str] = &[
    "std::fs",
    "std::net",
    "std::process",
    "std::env",
    "std::io",
    "std::thread",
    "std::time::SystemTime::now",
    "std::time::Instant::now",
    "tokio",
    "async_std",
    "reqwest",
    "hyper",
    "ureq",
    "rand",
    "getrandom",
    "chrono::Utc",
    "chrono::Local",
];
/// Clock reads through an imported type name (`use std::time::Instant;`).
/// Holding or comparing a time value is pure; reading the clock is not.
const CLOCK_READS: &[&str] = &["Instant::now", "SystemTime::now"];
/// Macros that write to the outside world or splice in unchecked source.
const IMPURE_MACROS: &[&str] = &[
    "println",
    "print",
    "eprintln",
    "eprint",
    "dbg",
    "include",
    "include_str",
    "include_bytes",
];
/// Crate roots whose renaming would hide an impure path from the checker.
const ROOTS: &[&str] = &[
    "std",
    "core",
    "alloc",
    "tokio",
    "async_std",
    "reqwest",
    "hyper",
    "rand",
    "chrono",
];
/// Macros and methods that can panic.
const PANIC_MACROS: &[&str] = &["panic", "todo", "unimplemented", "unreachable"];
const PANIC_METHODS: &[&str] = &[
    "unwrap",
    "expect",
    "unwrap_err",
    "expect_err",
    "unwrap_unchecked",
];
/// Types that make a `static` mutable global state.
const SHARED_STATE: &[&str] = &[
    "Mutex", "RwLock", "RefCell", "Cell", "OnceCell", "OnceLock", "LazyLock", "LazyCell",
];

/// Tuple structs with exactly one field: their own impls are the parse/render edge.
pub fn newtypes(file: &syn::File) -> BTreeSet<String> {
    file.items
        .iter()
        .filter_map(|item| match item {
            syn::Item::Struct(node) => {
                matches!(&node.fields, Fields::Unnamed(f) if f.unnamed.len() == 1)
                    .then(|| node.ident.to_string())
            }
            _ => None,
        })
        .collect()
}

/// Files of out-of-line `#[cfg(test)] mod name;` declarations in the file at
/// `path`, as `name.rs` and `name/` prefixes relative to the crate root.
pub fn test_module_files(path: &str, file: &syn::File) -> Vec<String> {
    let parent = module_dir(path);
    file.items
        .iter()
        .filter_map(|item| match item {
            syn::Item::Mod(node) if node.content.is_none() && is_test(&node.attrs) => {
                Some(node.ident.to_string())
            }
            _ => None,
        })
        .flat_map(|name| [format!("{parent}{name}.rs"), format!("{parent}{name}/")])
        .collect()
}

/// Directory holding the children of the module defined at `path`.
fn module_dir(path: &str) -> String {
    let (dir, file) = path.rsplit_once('/').unwrap_or(("", path));
    let prefix = if dir.is_empty() {
        String::new()
    } else {
        format!("{dir}/")
    };
    match file.strip_suffix(".rs") {
        Some("mod" | "lib" | "main") | None => prefix,
        Some(stem) => format!("{prefix}{stem}/"),
    }
}

/// Every violation in `file` at `path`.
pub fn check(
    path: &str,
    file: &syn::File,
    config: &Config,
    newtypes: &BTreeSet<String>,
) -> Vec<Finding> {
    let mut checker = Checker {
        path,
        config,
        newtypes,
        domain: config.is_domain(path),
        edge: config.is_edge(path),
        impls: Vec::new(),
        findings: Vec::new(),
    };
    checker.visit_file(file);
    checker.findings
}

/// What kind of `impl` block surrounds the current item.
#[derive(Clone, Copy)]
enum ImplKind {
    Trait,
    Newtype,
    Inherent,
}

struct Checker<'a> {
    path: &'a str,
    config: &'a Config,
    newtypes: &'a BTreeSet<String>,
    domain: bool,
    edge: bool,
    impls: Vec<ImplKind>,
    findings: Vec<Finding>,
}

impl Checker<'_> {
    fn report(&mut self, span: proc_macro2::Span, rule: Rule, message: String) {
        self.findings
            .push(Finding::new(self.path, span, rule, message));
    }

    fn check_function(&mut self, vis: &Visibility, sig: &Signature, block: &syn::Block) {
        self.check_size(sig, block);
        let boundary = !matches!(vis, Visibility::Inherited)
            && !matches!(self.impls.last(), Some(ImplKind::Trait));
        if boundary {
            self.check_boundary(sig);
        }
    }

    fn check_size(&mut self, sig: &Signature, block: &syn::Block) {
        let name = &sig.ident;
        let statements = block.stmts.len();
        if statements > self.config.max_statements() {
            let limit = self.config.max_statements();
            self.report(
                sig.ident.span(),
                Rule::TooManyStatements,
                format!("`{name}` has {statements} statements (max {limit}); split it"),
            );
        }
        let params = sig
            .inputs
            .iter()
            .filter(|input| matches!(input, syn::FnArg::Typed(_)))
            .count();
        if params > self.config.max_params() {
            let limit = self.config.max_params();
            self.report(
                sig.ident.span(),
                Rule::TooManyParameters,
                format!(
                    "`{name}` takes {params} parameters (max {limit}); introduce a parameter type"
                ),
            );
        }
        let depth = nesting::depth(block);
        if depth > self.config.max_nesting() {
            let limit = self.config.max_nesting();
            self.report(
                sig.ident.span(),
                Rule::TooDeep,
                format!("`{name}` nests {depth} levels (max {limit}); extract a function"),
            );
        }
    }

    fn check_boundary(&mut self, sig: &Signature) {
        let name = &sig.ident;
        let exempt = self.edge || matches!(self.impls.last(), Some(ImplKind::Newtype));
        if !exempt && signature_mentions_primitive(sig) {
            self.report(
                sig.ident.span(),
                Rule::PrimitiveBoundary,
                format!("`{name}` exposes a primitive across a module boundary; use a domain type"),
            );
        }
        if self.domain && matches!(sig.output, syn::ReturnType::Default) && !mutates_self(sig) {
            self.report(
                sig.ident.span(),
                Rule::UnitReturn,
                format!(
                    "`{name}` returns nothing: a pure function must return a value or a `Result`"
                ),
            );
        }
    }

    fn check_path(&mut self, span: proc_macro2::Span, joined: &str) {
        let impure = IMPURE.iter().any(|prefix| starts_with_path(joined, prefix))
            || CLOCK_READS.iter().any(|read| ends_with_path(joined, read));
        if self.domain && impure {
            self.report(
                span,
                Rule::ImpureDependency,
                format!("domain module reaches `{joined}`; move the effect behind a port"),
            );
        }
    }
}

impl<'ast> Visit<'ast> for Checker<'_> {
    fn visit_item_mod(&mut self, node: &'ast syn::ItemMod) {
        if !is_test(&node.attrs) {
            syn::visit::visit_item_mod(self, node);
        }
    }

    fn visit_item_fn(&mut self, node: &'ast syn::ItemFn) {
        if !is_test(&node.attrs) {
            self.check_function(&node.vis, &node.sig, &node.block);
            syn::visit::visit_item_fn(self, node);
        }
    }

    fn visit_impl_item_fn(&mut self, node: &'ast syn::ImplItemFn) {
        if !is_test(&node.attrs) {
            self.check_function(&node.vis, &node.sig, &node.block);
            syn::visit::visit_impl_item_fn(self, node);
        }
    }

    fn visit_item_impl(&mut self, node: &'ast syn::ItemImpl) {
        if is_test(&node.attrs) {
            return;
        }
        let kind = if node.trait_.is_some() {
            ImplKind::Trait
        } else if type_name(&node.self_ty).is_some_and(|name| self.newtypes.contains(&name)) {
            ImplKind::Newtype
        } else {
            ImplKind::Inherent
        };
        self.impls.push(kind);
        syn::visit::visit_item_impl(self, node);
        self.impls.pop();
    }

    fn visit_item_struct(&mut self, node: &'ast syn::ItemStruct) {
        for field in node
            .fields
            .iter()
            .filter(|field| !matches!(field.vis, Visibility::Inherited))
        {
            let name = field
                .ident
                .as_ref()
                .map_or_else(|| "tuple field".to_owned(), ToString::to_string);
            let owner = &node.ident;
            self.report(
                field.span(),
                Rule::PubField,
                format!(
                    "`{owner}`: field `{name}` is visible; keep fields private and expose accessors"
                ),
            );
        }
        syn::visit::visit_item_struct(self, node);
    }

    fn visit_item_use(&mut self, node: &'ast syn::ItemUse) {
        if !matches!(node.vis, Visibility::Inherited) && has_glob(&node.tree) {
            self.report(
                node.span(),
                Rule::GlobReexport,
                "glob re-export; re-export the public surface by name".to_owned(),
            );
        }
        for joined in flatten(&node.tree, String::new()) {
            self.check_path(node.span(), &joined);
        }
        if self.domain && renames_root(&node.tree) {
            self.report(
                node.span(),
                Rule::ImpureDependency,
                "renaming a crate root hides its paths from review".to_owned(),
            );
        }
    }

    fn visit_path(&mut self, node: &'ast syn::Path) {
        self.check_path(node.span(), &join(node));
        syn::visit::visit_path(self, node);
    }

    fn visit_item_static(&mut self, node: &'ast syn::ItemStatic) {
        let shared = type_name(&node.ty).is_some_and(|name| {
            SHARED_STATE.contains(&name.as_str()) || name.starts_with("Atomic")
        });
        if self.domain && (matches!(node.mutability, syn::StaticMutability::Mut(_)) || shared) {
            let name = &node.ident;
            self.report(
                node.span(),
                Rule::GlobalState,
                format!("domain static `{name}` is mutable global state"),
            );
        }
        syn::visit::visit_item_static(self, node);
    }

    fn visit_macro(&mut self, node: &'ast syn::Macro) {
        let name = node
            .path
            .segments
            .last()
            .map(|segment| segment.ident.to_string())
            .unwrap_or_default();
        if PANIC_MACROS.contains(&name.as_str()) {
            self.report(
                node.span(),
                Rule::Panic,
                format!("`{name}!` can panic; return a `Result`/`Option`"),
            );
        } else if self.domain && name.starts_with("include") {
            self.report(
                node.span(),
                Rule::ImpureDependency,
                format!("`{name}!` splices unchecked source or data into a domain module"),
            );
        } else if self.domain && IMPURE_MACROS.contains(&name.as_str()) {
            self.report(
                node.span(),
                Rule::ImpureDependency,
                format!("`{name}!` writes to the outside world from a domain module"),
            );
        } else if self.domain && name == "thread_local" {
            self.report(
                node.span(),
                Rule::GlobalState,
                "`thread_local!` is mutable global state".to_owned(),
            );
        }
        syn::visit::visit_macro(self, node);
    }

    fn visit_expr_method_call(&mut self, node: &'ast syn::ExprMethodCall) {
        let name = node.method.to_string();
        if PANIC_METHODS.contains(&name.as_str()) {
            self.report(
                node.method.span(),
                Rule::Panic,
                format!("`.{name}()` can panic; propagate with `?` or a combinator"),
            );
        }
        syn::visit::visit_expr_method_call(self, node);
    }
}

fn signature_mentions_primitive(sig: &Signature) -> bool {
    let inputs = sig.inputs.iter().any(|input| match input {
        syn::FnArg::Typed(typed) => types::mentions_primitive(&typed.ty),
        syn::FnArg::Receiver(_) => false,
    });
    let output = match &sig.output {
        syn::ReturnType::Type(_, ty) => types::mentions_primitive(ty),
        syn::ReturnType::Default => false,
    };
    inputs || output
}

/// A `&mut self` method is a state transition of its owner, not a hidden effect.
fn mutates_self(sig: &Signature) -> bool {
    sig.receiver()
        .is_some_and(|receiver| receiver.reference.is_some() && receiver.mutability.is_some())
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

fn type_name(ty: &syn::Type) -> Option<String> {
    match ty {
        syn::Type::Path(path) => path
            .path
            .segments
            .last()
            .map(|segment| segment.ident.to_string()),
        _ => None,
    }
}

fn join(path: &syn::Path) -> String {
    path.segments
        .iter()
        .map(|segment| segment.ident.to_string())
        .collect::<Vec<_>>()
        .join("::")
}

fn starts_with_path(joined: &str, prefix: &str) -> bool {
    joined == prefix
        || joined
            .strip_prefix(prefix)
            .is_some_and(|rest| rest.starts_with("::"))
}

fn ends_with_path(joined: &str, suffix: &str) -> bool {
    joined == suffix
        || joined
            .strip_suffix(suffix)
            .is_some_and(|rest| rest.ends_with("::"))
}

/// Whether the tree renames a crate root (`use std as s;`), at the top level.
fn renames_root(tree: &UseTree) -> bool {
    match tree {
        UseTree::Rename(rename) => ROOTS.contains(&rename.ident.to_string().as_str()),
        UseTree::Group(group) => group.items.iter().any(renames_root),
        UseTree::Path(_) | UseTree::Name(_) | UseTree::Glob(_) => false,
    }
}

fn has_glob(tree: &UseTree) -> bool {
    match tree {
        UseTree::Glob(_) => true,
        UseTree::Path(path) => has_glob(&path.tree),
        UseTree::Group(group) => group.items.iter().any(has_glob),
        UseTree::Name(_) | UseTree::Rename(_) => false,
    }
}

/// Every full path a `use` tree imports, e.g. `std::fs::read`.
fn flatten(tree: &UseTree, prefix: String) -> Vec<String> {
    let extend = |name: String| {
        if prefix.is_empty() {
            name
        } else {
            format!("{prefix}::{name}")
        }
    };
    match tree {
        UseTree::Path(path) => flatten(&path.tree, extend(path.ident.to_string())),
        UseTree::Name(name) => vec![extend(name.ident.to_string())],
        UseTree::Rename(rename) => vec![extend(rename.ident.to_string())],
        UseTree::Glob(_) => vec![prefix],
        UseTree::Group(group) => group
            .items
            .iter()
            .flat_map(|item| flatten(item, prefix.clone()))
            .collect(),
    }
}
