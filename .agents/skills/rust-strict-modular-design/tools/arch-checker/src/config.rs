//! The per-crate `arch-checker.conf` contract.

use std::fmt;

/// The role a source path plays; the longest matching configured prefix wins.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Role {
    /// Pure core: no I/O, clock, randomness, globals or printing.
    Domain,
    /// Protocol edge: may expose primitives (parsing input, rendering output).
    Edge,
    /// Imperative shell: performs effects; every other rule still applies.
    Shell,
}

/// Where each rule applies and how small a function must be.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    roles: Vec<(String, Role)>,
    max_statements: usize,
    max_params: usize,
    max_nesting: usize,
}

/// Why a configuration file was rejected.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ConfigError {
    /// A line is neither a comment nor `key = value`.
    Syntax(usize),
    /// A key is not part of the contract.
    UnknownKey(usize),
    /// A limit is not a positive integer.
    InvalidLimit(usize),
    /// No domain path was declared, so purity would check nothing.
    NoDomain,
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Syntax(line) => write!(f, "line {line}: expected `key = value`"),
            Self::UnknownKey(line) => write!(f, "line {line}: unknown key"),
            Self::InvalidLimit(line) => write!(f, "line {line}: limit must be a positive integer"),
            Self::NoDomain => f.write_str("`domain` must list at least one pure path"),
        }
    }
}

impl std::error::Error for ConfigError {}

impl Config {
    /// Parse the whole configuration text once.
    pub fn parse(text: &str) -> Result<Self, ConfigError> {
        let mut config = Self {
            roles: Vec::new(),
            max_statements: 15,
            max_params: 3,
            max_nesting: 3,
        };
        for (index, raw) in text.lines().enumerate() {
            let number = index.saturating_add(1);
            let line = raw.split('#').next().unwrap_or_default().trim();
            if !line.is_empty() {
                config.apply(line, number)?;
            }
        }
        if !config.roles.iter().any(|(_, role)| *role == Role::Domain) {
            return Err(ConfigError::NoDomain);
        }
        Ok(config)
    }

    fn apply(&mut self, line: &str, number: usize) -> Result<(), ConfigError> {
        let (key, value) = line.split_once('=').ok_or(ConfigError::Syntax(number))?;
        let words = |role| {
            value
                .split_whitespace()
                .map(move |path| (path.to_owned(), role))
        };
        match key.trim() {
            "domain" => self.roles.extend(words(Role::Domain)),
            "edge" => self.roles.extend(words(Role::Edge)),
            "shell" => self.roles.extend(words(Role::Shell)),
            "max-statements" => self.max_statements = limit(value, number)?,
            "max-params" => self.max_params = limit(value, number)?,
            "max-nesting" => self.max_nesting = limit(value, number)?,
            _ => return Err(ConfigError::UnknownKey(number)),
        }
        Ok(())
    }

    /// The role of the longest configured prefix of `path`, if any.
    fn role(&self, path: &str) -> Option<Role> {
        self.roles
            .iter()
            .filter(|(prefix, _)| covers(prefix, path))
            .max_by_key(|(prefix, _)| prefix.len())
            .map(|(_, role)| *role)
    }

    /// Whether `path` (relative to the crate root) must stay pure.
    pub fn is_domain(&self, path: &str) -> bool {
        self.role(path) == Some(Role::Domain)
    }

    /// Whether `path` is an edge module that may expose primitives.
    pub fn is_edge(&self, path: &str) -> bool {
        self.role(path) == Some(Role::Edge)
    }

    /// Maximum statements in one function body.
    pub fn max_statements(&self) -> usize {
        self.max_statements
    }

    /// Maximum parameters, excluding `self`.
    pub fn max_params(&self) -> usize {
        self.max_params
    }

    /// Maximum nested control-flow depth.
    pub fn max_nesting(&self) -> usize {
        self.max_nesting
    }
}

/// `src/a` covers `src/a`, `src/a.rs` and everything under `src/a/`, but not `src/ab.rs`.
fn covers(prefix: &str, path: &str) -> bool {
    path.strip_prefix(prefix).is_some_and(|rest| {
        rest.is_empty() || rest == ".rs" || rest.starts_with('/') || prefix.ends_with('/')
    })
}

fn limit(value: &str, number: usize) -> Result<usize, ConfigError> {
    value
        .trim()
        .parse::<usize>()
        .ok()
        .filter(|limit| *limit > 0)
        .ok_or(ConfigError::InvalidLimit(number))
}
