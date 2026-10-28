//! Side-effect-free literal replacement; no regex, case-folding or guessed match.

use super::{EditError, types::EditText};

/// Prepare exactly one case-sensitive, non-overlapping literal replacement.
/// The whole result remains bounded; an error never publishes a partial prefix.
pub fn replace(base: &EditText, old: &EditText, new: &EditText) -> Result<EditText, EditError> {
    if old.as_str().is_empty() {
        return Err(EditError::MissingMatch);
    }
    let mut matches = base.as_str().match_indices(old.as_str());
    let (start, _) = matches.next().ok_or(EditError::MissingMatch)?;
    if matches.next().is_some() {
        return Err(EditError::AmbiguousMatch);
    }
    let end = start
        .checked_add(old.as_str().len())
        .ok_or(EditError::Limit)?;
    let size = base
        .as_str()
        .len()
        .checked_sub(old.as_str().len())
        .and_then(|n| n.checked_add(new.as_str().len()))
        .ok_or(EditError::Limit)?;
    if size > crate::constants::limits::EDIT_TEXT_BYTES {
        return Err(EditError::Limit);
    }
    let mut result = String::with_capacity(size);
    result.push_str(
        base.as_str()
            .get(..start)
            .ok_or(EditError::InvalidEvidence)?,
    );
    result.push_str(new.as_str());
    result.push_str(base.as_str().get(end..).ok_or(EditError::InvalidEvidence)?);
    EditText::try_from(result)
}
