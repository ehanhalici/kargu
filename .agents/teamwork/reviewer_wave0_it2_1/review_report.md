# Wave 0 Iteration 2 Review & Adversarial Challenge Report

**Reviewer & Critic**: `reviewer_wave0_it2_1`  
**Milestone**: Wave 0 Iteration 2 Acceptance Gate  
**Date**: 2026-10-21  
**Verdict**: **APPROVE**

---

## 1. Executive Summary

A comprehensive quality review, adversarial stress-testing, and independent programmatic verification was conducted on the Wave 0 Iteration 2 remediation work produced by `worker_wave0_it2_1` in response to defects identified by `challenger_wave0_1`.

All 6 reported defects (BUG-01 through BUG-06) have been thoroughly and genuinely remediated:
1. **BUG-01**: Remote Tramp paths and buffers are intercepted before any filesystem I/O, preventing network hangs and returning `nil` in under 0.03s.
2. **BUG-02**: Dangling symlinks resolve target existence via `(file-truename target)` and `(file-exists-p truename)`, returning `nil` instead of the symlink's `lstat` data.
3. **BUG-03**: Valid symlinks resolve to the canonical target, ensuring target file updates immediately reflect in symlink revisions.
4. **BUG-04**: Active in-flight logical requests block execution claims before any state mutation occurs, preserving the ARCH-01 single-active-run invariant.
5. **BUG-05**: Rejected claims do not advance generation counters, preserving generation monotonicity and isolation.
6. **BUG-06**: Claims are strictly scoped to their issuing application instance via `(eq (kargu-application-claim-app claim) target)`, preventing cross-application releases even if default run IDs collide.

**Integrity Audit**: PASSED. No hardcoded test responses, dummy facade implementations, mock bypasses, or integrity violations exist in the codebase. All logic is genuine, clean, and complete.

---

## 2. Independent Verification Results

### 2.1 Full ERT Test Suite
Executed the exact canonical ERT batch command:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
```
- **Result**: `Ran 953 tests, 953 results as expected, 0 unexpected (2026-10-21 21:52:05+0000, 43.601719 sec)`
- **Exit Code**: `0` (Zero failures, zero errors).

Executed the project test runner:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize))" -l tests/run-tests.el
```
- **Result**: `Ran 953 tests, 953 results as expected, 0 unexpected (2026-10-21 21:54:13+0000, 42.807207 sec)`
- **Exit Code**: `0`.

### 2.2 Strict Byte-Compilation (`byte-compile-error-on-warn t`)
Byte-compiled all modified and newly introduced files:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (setq byte-compile-error-on-warn t))" -f batch-byte-compile kargu/application/coordinator.el kargu/files.el tests/test-application-context.el kargu/contract.el kargu/tools/diff/track.el tests/test-helpers.el tests/test-modules.el
```
- **Result**: Clean compilation, 0 warnings, 0 errors, exit code `0`.

### 2.3 Checkdoc Hygiene
Checked docstrings and formatting across modified files:
```bash
emacs -Q --batch --eval "(progn (require 'checkdoc) (checkdoc-file \"kargu/application/coordinator.el\") (checkdoc-file \"kargu/files.el\") (checkdoc-file \"tests/test-application-context.el\"))"
```
- **Result**: 0 checkdoc warnings, clean exit code `0`.

### 2.4 Artifact Hygiene
Checked for leftover `.elc` files:
```bash
find . -name "*.elc"
git status --ignored -s | grep elc
```
- **Result**: Zero `.elc` files present in source tree.

### 2.5 Formal Model Checking (TLC)
Ran the project's formal TLA+/TLC model checker scripts:
```bash
bash proof/run_tlc.sh --mode
```
- **Result**: `Model checking completed. No error has been found. 20179 states generated, 5958 distinct states found, 0 states left on queue.` Exit code `0`.

```bash
bash proof/run_tlc.sh --edit-transaction
```
- **Result**: `Model checking completed. No error has been found. 425 states generated, 160 distinct states found, 0 states left on queue.` Exit code `0`.

---

## 3. Adversarial Stress-Testing & Edge Case Analysis

| Challenge # | Target / Scenario | Attack Input / Condition | Observed Behavior | Status |
|:---:|---|---|---|:---:|
| **ADV-01** | `kargu-file-current-revision` Tramp blocking | Path strings with `/ssh:user@nohost:/path` and buffers visiting remote Tramp paths | `file-remote-p` checked before any `file-exists-p`; returns `nil` in 0.027s without network call | **PASS** |
| **ADV-02** | `kargu-file-current-revision` Dangling symlink | Symlink pointing to non-existent target `nonexistent.txt` | Target resolved via `file-truename`; returns `nil` instead of symlink's `lstat` | **PASS** |
| **ADV-03** | `kargu-file-current-revision` Symlink cache invalidation | Update target file size and mtime while observing via symlink | Symlink revision updates synchronously and identically matches target revision | **PASS** |
| **ADV-04** | `kargu-file-current-revision` Circular symlink attack | Circular symlink loop `a -> b -> a` | Trapped by `condition-case nil ... (error nil)`; returns `nil` cleanly without infinite loop or hang | **PASS** |
| **ADV-05** | `kargu-file-current-revision` Malformed / edge inputs | Killed buffer, unassociated scratch buffer, `nil`, integer, `""`, whitespace-only string | All return `nil` safely without signaling unhandled errors | **PASS** |
| **ADV-06** | `kargu-application-claim` In-flight request bypass | Claim on idle app with active request `:in-flight` and no explicit `:run-id` | `work-active-p` checked before generation increment; claim rejected; generation counter remains unchanged | **PASS** |
| **ADV-07** | `kargu-application-release` Cross-instance claim release | Dual applications at generation 0 issuing identical default `"run-1"`; release App A with App B's token | Scoped check `(eq (kargu-application-claim-app claim) target)` fails; returns `nil`; App A remains running | **PASS** |
| **ADV-08** | Multi-instance claim/release churn | 10 independent applications claimed concurrently with custom IDs, cross-released in mixed order | $10 \times 10$ cross-release matrix completely rejected ($i \neq j$); all legitimate releases succeeded | **PASS** |

---

## 4. Quality Review Dimensions

### 4.1 Correctness
- `kargu/application/coordinator.el`:
  - `kargu-application-claim` checks concurrency (`kargu-application-active-run` and `kargu-application-work-active-p`) before incrementing `kargu-application-generation` or constructing `run-id`.
  - When `:no-error` is non-nil, returns `nil` cleanly. When `:no-error` is omitted or nil, signals a descriptive error.
  - Generates immutable `kargu-application-claim` struct binding `:id`, `:app`, `:run-id`, `:session-id`.
  - `kargu-application-release` enforces handle ownership by validating `(eq (kargu-application-claim-app claim) target)` when `claim` is a claim struct, while preserving string run ID compatibility for single-instance or legacy usages.
- `kargu/files.el`:
  - `kargu-file-current-revision` ensures no remote paths or buffers are queried through filesystem primitives.
  - Resolves symlinks to canonical truenames, guards with `file-exists-p` on the canonical truename, and safely handles cycles with `condition-case`.
  - Backward compatibility is preserved via `kargu-file--file-revision` delegating directly to `kargu-file-current-revision`.

### 4.2 Logical Completeness
The remediation covers both the primary execution paths and the negative error handling paths. All tests in `tests/test-application-context.el` use `unwind-protect` to reliably clean up temporary files and reset application coordinator instances.

### 4.3 Interface Conformance
The changes strictly adhere to `PROJECT.md` contracts:
- ARCH-01 / ARCH-12 single-active-run invariant enforced.
- No global mutable singleton leakage into application instances.
- Public `kargu-file-current-revision` contract fulfilled for downstream consumption in Wave 1 Package B.
- No modifications made to `skills.md`, `.gitignore`, or `.agents/`.

---

## 5. Verdict

**APPROVE**

Wave 0 Iteration 2 is certified as fully passing all acceptance criteria, rigorous empirical challenges, strict compilation, clean documentation hygiene, and formal model verification. The repository is in an ideal state to proceed to Wave 1.
