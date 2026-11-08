//! One rule violation, located in a source file.

use std::fmt;

/// Every rule the checker enforces.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Rule {
    /// A struct field is visible outside its module.
    PubField,
    /// A glob re-export widens a module's surface implicitly.
    GlobReexport,
    /// A primitive crosses a module boundary in a non-private signature.
    PrimitiveBoundary,
    /// A non-private domain function returns nothing (an effect in disguise).
    UnitReturn,
    /// A domain module reaches the outside world directly.
    ImpureDependency,
    /// A domain module holds mutable global state.
    GlobalState,
    /// Code can panic instead of returning `Result`/`Option`.
    Panic,
    /// A function body has more statements than one job needs.
    TooManyStatements,
    /// A function takes more parameters than one job needs.
    TooManyParameters,
    /// Control flow is nested deeper than one job needs.
    TooDeep,
}

impl Rule {
    /// Stable identifier printed in reports.
    pub fn id(self) -> &'static str {
        match self {
            Self::PubField => "pub-field",
            Self::GlobReexport => "glob-reexport",
            Self::PrimitiveBoundary => "primitive-boundary",
            Self::UnitReturn => "unit-return",
            Self::ImpureDependency => "impure-dependency",
            Self::GlobalState => "global-state",
            Self::Panic => "panic",
            Self::TooManyStatements => "too-many-statements",
            Self::TooManyParameters => "too-many-parameters",
            Self::TooDeep => "too-deep",
        }
    }
}

/// A located violation with a human explanation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Finding {
    file: String,
    line: usize,
    column: usize,
    rule: Rule,
    message: String,
}

impl Finding {
    /// Record a violation of `rule` at `span` in `file`.
    pub fn new(file: &str, span: proc_macro2::Span, rule: Rule, message: String) -> Self {
        let start = span.start();
        Self {
            file: file.to_owned(),
            line: start.line,
            column: start.column.saturating_add(1),
            rule,
            message,
        }
    }

    /// The violated rule.
    pub fn rule(&self) -> Rule {
        self.rule
    }

    /// A location-free identity for baselines: rule, file and the message with
    /// every number replaced, so moving code or changing a count keeps the key.
    pub fn key(&self) -> String {
        format!(
            "{}\t{}\t{}",
            self.rule.id(),
            self.file,
            without_numbers(&self.message)
        )
    }
}

fn without_numbers(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_number = false;
    for character in text.chars() {
        if character.is_ascii_digit() {
            if !in_number {
                out.push('N');
            }
            in_number = true;
        } else {
            out.push(character);
            in_number = false;
        }
    }
    out
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}:{} [{}] {}",
            self.file,
            self.line,
            self.column,
            self.rule.id(),
            self.message
        )
    }
}
