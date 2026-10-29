//! Bounded unified-context hunk measurement for non-patch and revised proposals.

use crate::{
    constants::limits,
    edit::types::{EditText, HunkCount},
};
use std::collections::HashMap;

const MAX_EDIT_DISTANCE: usize = 512;
const UNIFIED_CONTEXT_GAP: usize = 6;

pub(super) fn measure_hunks(
    base: &EditText,
    proposed: &EditText,
    unchanged: bool,
) -> Option<HunkCount> {
    if unchanged || base.as_str() == proposed.as_str() {
        return Some(HunkCount::default());
    }
    if base.as_str().is_empty() || proposed.as_str().is_empty() {
        return HunkCount::try_from(1).ok();
    }
    let base_lines: Vec<&str> = base.as_str().split_inclusive('\n').collect();
    let proposed_lines: Vec<&str> = proposed.as_str().split_inclusive('\n').collect();
    if base_lines.len() > limits::EDIT_PATCH_LINES
        || proposed_lines.len() > limits::EDIT_PATCH_LINES
    {
        return None;
    }
    let prefix = base_lines
        .iter()
        .zip(proposed_lines.iter())
        .take_while(|(left, right)| left == right)
        .count();
    let suffix = base_lines
        .get(prefix..)?
        .iter()
        .rev()
        .zip(proposed_lines.get(prefix..)?.iter().rev())
        .take_while(|(left, right)| left == right)
        .count();
    let base_end = base_lines.len().checked_sub(suffix)?;
    let proposed_end = proposed_lines.len().checked_sub(suffix)?;
    let left_slice = base_lines.get(prefix..base_end)?;
    let right_slice = proposed_lines.get(prefix..proposed_end)?;
    if left_slice.is_empty() || right_slice.is_empty() {
        return HunkCount::try_from(1).ok();
    }
    let mut table: HashMap<&str, u32> = HashMap::new();
    let mut left_ids = Vec::with_capacity(left_slice.len());
    for line in left_slice {
        let next = u32::try_from(table.len()).ok()?;
        let id = *table.entry(line).or_insert(next);
        left_ids.push(id);
    }
    let mut right_ids = Vec::with_capacity(right_slice.len());
    for line in right_slice {
        let next = u32::try_from(table.len()).ok()?;
        let id = *table.entry(line).or_insert(next);
        right_ids.push(id);
    }
    myers_hunks(&left_ids, &right_ids)
}

pub(super) fn sum_hunks(items: impl IntoIterator<Item = Option<HunkCount>>) -> Option<HunkCount> {
    let mut total = 0usize;
    for item in items {
        total = total.checked_add(item?.get())?;
    }
    HunkCount::try_from(total).ok()
}

fn myers_hunks(left: &[u32], right: &[u32]) -> Option<HunkCount> {
    let n = left.len();
    let m = right.len();
    let max_d = n.saturating_add(m).min(MAX_EDIT_DISTANCE);
    let offset = max_d.checked_add(1)?;
    let size = offset.checked_mul(2)?.checked_add(1)?;
    let mut v = vec![0usize; size];
    let mut trace: Vec<Vec<usize>> = Vec::with_capacity(max_d.checked_add(1)?);
    trace.push(v.clone());

    let mut reached_d = None;
    for d in 1..=max_d {
        let d_isize = isize::try_from(d).ok()?;
        let offset_isize = isize::try_from(offset).ok()?;
        for step in 0..=d {
            let step_isize = isize::try_from(step).ok()?;
            let k = -d_isize + 2 * step_isize;
            let idx = usize::try_from(offset_isize + k).ok()?;
            let down = k == -d_isize
                || (k != d_isize && v.get(idx.checked_sub(1)?)? < v.get(idx.checked_add(1)?)?);
            let mut x = if down {
                *v.get(idx.checked_add(1)?)?
            } else {
                v.get(idx.checked_sub(1)?)?.checked_add(1)?
            };
            let mut y = usize::try_from(isize::try_from(x).ok()? - k).ok()?;
            while x < n && y < m && left.get(x) == right.get(y) {
                x = x.checked_add(1)?;
                y = y.checked_add(1)?;
            }
            *v.get_mut(idx)? = x;
            if x >= n && y >= m {
                reached_d = Some(d);
                break;
            }
        }
        trace.push(v.clone());
        if reached_d.is_some() {
            break;
        }
    }

    let final_d = reached_d?;
    let offset_isize = isize::try_from(offset).ok()?;
    let mut cur_x = n;
    let mut cur_y = m;
    let mut hunks = 1usize;

    for d in (1..=final_d).rev() {
        let prev_v = trace.get(d.checked_sub(1)?)?;
        let d_isize = isize::try_from(d).ok()?;
        let k = isize::try_from(cur_x).ok()? - isize::try_from(cur_y).ok()?;
        let idx = usize::try_from(offset_isize + k).ok()?;
        let down = k == -d_isize
            || (k != d_isize
                && prev_v.get(idx.checked_sub(1)?)? < prev_v.get(idx.checked_add(1)?)?);
        let prev_k = if down { k + 1 } else { k - 1 };
        let prev_idx = usize::try_from(offset_isize + prev_k).ok()?;
        let prev_x = *prev_v.get(prev_idx)?;
        let prev_y = usize::try_from(isize::try_from(prev_x).ok()? - prev_k).ok()?;
        let mid_x = if down { prev_x } else { prev_x.checked_add(1)? };
        let snake_len = cur_x.checked_sub(mid_x)?;
        if snake_len > UNIFIED_CONTEXT_GAP {
            hunks = hunks.checked_add(1)?;
        }
        cur_x = prev_x;
        cur_y = prev_y;
    }

    HunkCount::try_from(hunks).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn measures_zero_single_multi_and_unproven_hunks() -> Result<(), crate::error::CoreError> {
        let base = EditText::try_from("a\n1\n2\n3\n4\n5\n6\n7\nb\n".to_owned())?;
        let same = EditText::try_from("a\n1\n2\n3\n4\n5\n6\n7\nb\n".to_owned())?;
        let single = EditText::try_from("A\n1\n2\n3\n4\n5\n6\n7\nb\n".to_owned())?;
        let merged = EditText::try_from("A\n1\n2\nB\n5\n6\n7\nb\n".to_owned())?;
        let multi = EditText::try_from("A\n1\n2\n3\n4\n5\n6\n7\nB\n".to_owned())?;

        assert_eq!(
            measure_hunks(&base, &same, true),
            Some(HunkCount::default())
        );
        assert_eq!(
            measure_hunks(&base, &single, false),
            Some(HunkCount::try_from(1)?)
        );
        assert_eq!(
            measure_hunks(&base, &merged, false),
            Some(HunkCount::try_from(1)?)
        );
        assert_eq!(
            measure_hunks(&base, &multi, false),
            Some(HunkCount::try_from(2)?)
        );

        let mut large_left = String::new();
        let mut large_right = String::new();
        for idx in 0..300 {
            large_left.push_str(&format!("left-{idx}\n"));
            large_right.push_str(&format!("right-{idx}\n"));
        }
        let left_text = EditText::try_from(large_left)?;
        let right_text = EditText::try_from(large_right)?;
        assert_eq!(measure_hunks(&left_text, &right_text, false), None);
        Ok(())
    }
    #[test]
    fn three_line_context_merges_exactly_six_unchanged_lines() -> Result<(), crate::error::CoreError>
    {
        for gap in [6, 7] {
            let middle = (0..gap)
                .map(|line| format!("context-{line}\n"))
                .collect::<String>();
            let base = EditText::try_from(format!("before\n{middle}after\n"))?;
            let proposed = EditText::try_from(format!("BEFORE\n{middle}AFTER\n"))?;
            assert_eq!(
                measure_hunks(&base, &proposed, false),
                Some(HunkCount::try_from(if gap == 6 { 1 } else { 2 })?)
            );
        }
        Ok(())
    }

    #[test]
    fn every_short_repeated_line_pair_has_one_or_zero_unified_hunks()
    -> Result<(), crate::error::CoreError> {
        let mut bodies = vec![String::new()];
        for length in 1..=5 {
            for bits in 0..(1usize << length) {
                let mut body = String::new();
                for position in 0..length {
                    body.push_str(if bits & (1usize << position) == 0 {
                        "a\n"
                    } else {
                        "b\n"
                    });
                }
                bodies.push(body);
            }
        }
        for left in &bodies {
            for right in &bodies {
                let left_text = EditText::try_from(left.clone())?;
                let right_text = EditText::try_from(right.clone())?;
                // At most five lines cannot separate two three-context hunks.
                let expected = HunkCount::try_from(usize::from(left != right))?;
                assert_eq!(
                    measure_hunks(&left_text, &right_text, left == right),
                    Some(expected)
                );
            }
        }
        Ok(())
    }
}
