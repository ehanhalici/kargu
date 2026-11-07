---
name: verification-and-testing
description: Procedures and runbooks for running Kargu test suites (Cargo, ERT, Clippy, Checkdoc) and formal TLA+/TLC verification rules. Use when verifying code changes, running tests, or checking regression safety.
---

# Kargu Verification & Testing Runbook

This skill outlines the mandatory test execution and verification procedures for the Kargu codebase.

## 1. Golden Rules & Invariants

> [!IMPORTANT]
> **TLA+ / TLC Model Checking Rule**:
> TLA+/TLC is ONLY executed when TLA+ specifications under `proof/` (`proof/*.tla`, `proof/*.cfg`) are modified.
> **DO NOT** execute TLC to re-verify an unchanged model or just to reconfirm a previous result.

> [!WARNING]
> **Commit Policy**:
> Do NOT create git commits (`asla commit atma`) unless the user explicitly requests one.
> Always preserve the user's other staged and unstaged work in the workspace.

---

## 2. Test Execution Commands

### 2.1 Rust Core Tests (`kargu-core`)

Run all unit and integration tests:
```bash
cargo test -p kargu-core
```

Run doc tests and compile-fail suites:
```bash
cargo test -p kargu-core --doc
```

Run strict Clippy and formatting checks:
```bash
cargo clippy -p kargu-core --all-targets -- -D warnings
cargo fmt --check
```

### 2.2 Emacs Lisp Test Suite (ERT)

Run the full headless ERT test suite via batch Emacs:
```bash
emacs -Q --batch -L . -l tests/run-tests.el
```

Run individual test files when focusing on specific contracts:
```bash
# Verify fundamental laws and change contracts (Law A-F)
emacs -Q --batch -L . -l tests/test-laws.el -f ert-run-tests-batch-and-exit

# Verify provider catalog and RPC connections
emacs -Q --batch -L . -l tests/test-catalog-connection.el -f ert-run-tests-batch-and-exit

# Verify dynamic model selection and reasoning
emacs -Q --batch -L . -l tests/test-dynamic-models.el -f ert-run-tests-batch-and-exit
```

### 2.3 Elisp Linting & Byte Compilation

Check for byte-compilation warnings or missing declarations:
```bash
emacs -Q --batch -L . --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile kargu/*.el
```

Check documentation standards (`checkdoc`):
```bash
emacs -Q --batch -L . --eval "(checkdoc-file \"kargu.el\")"
```

---

## 3. Parity & End-to-End Verification

When a feature is ported from Elisp to Rust:
1. **Behavioral Equivalence**: Validate that the Rust RPC command produces the exact same outcomes, error structures, and event sequences as the original Elisp implementation.
2. **DTO Contract Integrity**: Ensure all fields in DTOs serialized by `kargu-core/src/host.rs` align with Elisp reader functions.
3. **Cancellation & Error Handling**: Test that cancellation (`cancel`) and timeouts gracefully unwind without leaving orphan processes or locked UI states.
4. **Clean Removal**: Once parity is proven by green tests, safely remove the deprecated Elisp domain functions.
