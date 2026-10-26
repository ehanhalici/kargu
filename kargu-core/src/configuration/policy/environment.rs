//! Bounded single-pass reference expansion. Missing names never echo source.

use super::domain::{EnvironmentSnapshot, EnvironmentVariable};
use crate::{configuration::domain::ConfigText, error::CoreError};
use std::collections::BTreeSet;
use zeroize::Zeroizing;

fn reference(rest: &str) -> Option<(EnvironmentVariable, &str)> {
    let (name, tail) = rest.split_once('}')?;
    if !name
        .chars()
        .next()
        .is_some_and(|ch| ch.is_alphabetic() || ch == '_')
    {
        return None;
    }
    Some((EnvironmentVariable::try_from(name.to_owned()).ok()?, tail))
}
pub(super) fn names(source: &str, names: &mut BTreeSet<EnvironmentVariable>) {
    let mut rest = source;
    while let Some((_, tail)) = rest.split_once("${") {
        if let Some((name, _)) = reference(tail) {
            names.insert(name);
        }
        rest = tail;
    }
}
pub(super) fn expand(
    source: &ConfigText,
    environment: &EnvironmentSnapshot,
    missing: &mut BTreeSet<EnvironmentVariable>,
) -> Result<Option<ConfigText>, CoreError> {
    let mut output = Zeroizing::new(String::new());
    let mut rest = source.as_str();
    let mut unavailable = false;
    while let Some((prefix, tail)) = rest.split_once("${") {
        output.push_str(prefix);
        if let Some((name, after)) = reference(tail) {
            if let Some(value) = environment.get(&name) {
                output.push_str(value.as_str());
            } else {
                missing.insert(name);
                unavailable = true;
            }
            rest = after;
        } else {
            output.push_str("${");
            rest = tail;
        }
        if output.len() > 64 * 1024 {
            return Err(CoreError::Limit);
        }
    }
    output.push_str(rest);
    if unavailable {
        return Ok(None);
    }
    ConfigText::try_from(output.to_string())
        .map(Some)
        .map_err(|_| CoreError::Limit)
}
