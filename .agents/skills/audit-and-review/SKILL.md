---
name: audit-and-review
description: Systematic process for conducting milestone reviews, compliance audits, and regression checks against todo.md and Kargu architectural contracts. Use when verifying a completed migration phase or auditing codebase health.
---

# Kargu Milestone Audit & Review Procedure

This skill defines the rigorous audit and evidence-gathering procedure for Kargu development tasks and migration phases.

## 1. Audit Principles

1. **Evidence-Based Acceptance**: A task is never marked complete merely because code compiles or a unit test passes. Real editor cutover, behavioral parity, and contract adherence must be proven.
2. **Sole Task Checklist**: Acceptance must align strictly with items in [todo.md](../../../todo.md).
3. **Rust Pattern Compliance**: Verify adherence to [01_RUST_CORE_PATTERNS.md](../coding-standards/references/01_RUST_CORE_PATTERNS.md) and [coding-standards](../coding-standards/SKILL.md) (no unwrap, no primitive obsession, typestate, bounded buffers).

---

## 2. Audit Execution Checklist

### Phase A: Static & Dynamic Verification
- [ ] Run full Rust tests: `cargo test -p kargu-core`
- [ ] Check Clippy: `cargo clippy -p kargu-core --all-targets -- -D warnings`
- [ ] Check formatting: `cargo fmt --check`
- [ ] Run ERT test suite: `emacs -Q --batch -L . -l tests/run-tests.el`
- [ ] Verify byte compilation without warnings: `emacs -Q --batch -L . --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile kargu/*.el`

### Phase B: Architectural Contract Review
- [ ] Verify Rust backend ownership: is config parsing, catalog discovery, loop control, and history in Rust?
- [ ] Verify thin Elisp bridge: is Elisp free of second decision engines or shadow state stores?
- [ ] Verify buffer/process hygiene: are all child processes isolated via PGID? Are all file paths canonicalized?
- [ ] Verify error classification: are all error branches typed and surfaced as actionable guidance?

---

## 3. Historical Audit Records

For historical audit evidence and precedents, see:
- [task3-audit-2026-10-29.md](references/task3-audit-2026-10-29.md)
- [migration-review-2026-11-01.md](references/migration-review-2026-11-01.md)
