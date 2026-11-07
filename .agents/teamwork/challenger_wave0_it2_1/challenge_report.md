# Challenge Report: Wave 0 Iteration 2 Empirical Verification

**Date**: 2026-10-21T21:53:30Z  
**Agent**: `challenger_wave0_it2_1` (Wave 0 Iteration 2 Empirical Challenger)  
**Overall Risk Assessment**: **LOW** (All 5 previous defects fully resolved, verified empirically; zero regressions found across 953 test cases and TLC model checks).  
**Verdict**: **APPROVE**

---

## Challenge Summary

During Wave 0 Iteration 1, `challenger_wave0_1` identified 5 defects (BUG-01 through BUG-06, spanning remote path hangs, symlink lstat resolution, in-flight request claim bypass, premature generation bump, and cross-application claim token leakage).

Remediation worker `worker_wave0_it2_1` applied fixes across `kargu/application/coordinator.el`, `kargu/files.el`, and introduced 5 unit tests in `tests/test-application-context.el`.

This challenger independently executed the exact verification script, tested remote paths, symlink manipulation, circular symlinks, multi-hop symlinks, logical request states, claim token forgery, and 5-way cross-application claim isolation, alongside full ERT (953 tests), byte-compilation (`byte-compile-error-on-warn t`), checkdoc, and TLC model checks (`--mode`, `--edit-transaction`).

All empirical tests and stress harnesses passed completely.

---

## Verification of Wave 0 Iteration 1 Defects

### 1. BUG-01: Tramp Remote Path Network Blocking
- **Empirical Test**: Evaluated `(kargu-file-current-revision "/ssh:user@remote:/path")` and multiple Tramp syntax prefixes (`/sudo:`, `/scp:`, `/sshx:`).
- **Result**: Instantaneous evaluation (<0.035s), returning `nil` without opening network connections or raising `file-error`.
- **Verdict**: **RESOLVED**

### 2. BUG-02: Dangling Symlinks Return Revision Instead of Nil
- **Empirical Test**: Created dangling symlinks pointing to non-existent targets; queried both raw file path and visiting Emacs buffer.
- **Result**: Both return `nil` cleanly via `file-truename` and `file-exists-p` validation.
- **Verdict**: **RESOLVED**

### 3. BUG-03: Symlinks Stale on Target File Modification
- **Empirical Test**: Created target file, symlink, and multi-hop symlink (`link2 -> link1 -> target`). Queried revision before and after modifying target file.
- **Result**: Initial revisions matched across target and both links. Following edit, updated revisions across target and symlinks changed identically to reflect new byte size and modification time.
- **Verdict**: **RESOLVED**

### 4. BUG-04 & BUG-05: Premature Generation Bump & In-Flight Request Bypass
- **Empirical Test**: Ran exact verification check from `challenger_wave0_1/handoff.md`:
  ```elisp
  (let ((app (kargu-application-create :status :idle :generation 1)))
    (let ((req (kargu-logical-request-create :id "req-1" :generation 1 :state :in-flight)))
      (kargu-application-set-active-request req app)
      (let ((claim (kargu-application-claim app :no-error t)))
        (cl-assert (null claim) nil "BUG-04: Claim should be rejected while request is in-flight!"))))
  ```
- **Result**: Assertion passed. Claim was rejected (`nil`). Application generation remained at 1 without premature advancement.
- **Verdict**: **RESOLVED**

### 5. BUG-06: Cross-Application Claim Release Token Leakage
- **Empirical Test**: Ran exact verification check from `challenger_wave0_1/handoff.md`:
  ```elisp
  (let ((app-a (kargu-application-create :status :idle :generation 0))
        (app-b (kargu-application-create :status :idle :generation 0)))
    (let ((c-a (kargu-application-claim app-a))
          (c-b (kargu-application-claim app-b)))
      (cl-assert (null (kargu-application-release app-a c-b)) nil
                 "BUG-06: Claim from App B must NOT release App A!")))
  ```
- **Result**: Assertion passed. Cross-application release was rejected (`nil`). App A remained `:running` with run `"run-1"`.
- **Verdict**: **RESOLVED**

---

## Stress Test Results

| # | Stress Scenario | Expected Behavior | Actual Behavior | Result |
|---|-----------------|-------------------|-----------------|--------|
| 1 | Hostile inputs to `kargu-file-current-revision` (`nil`, `""`, whitespace, integer, symbol, vector, dead buffer) | Return `nil` gracefully without signaling error | All returned `nil` in <0.001s | **PASS** |
| 2 | Circular symlink loop (`link-a -> link-b` and `link-b -> link-a`) | Caught safely by `condition-case` and returns `nil` | Returned `nil` without hanging or error | **PASS** |
| 3 | Deep 30-hop symlink chain (`link-29 -> ... -> target`) | Correctly resolves to canonical target revision | Returned identical revision to target file | **PASS** |
| 4 | Deep broken 30-hop symlink chain | Safely returns `nil` when root target deleted | Returned `nil` without error | **PASS** |
| 5 | Rapid sequential claim/release cycle (50 iterations) with double-claim attempts | Each granted claim increments generation by 1; rejected claims do NOT increment generation | Generation accurately advanced from 0 to 50; 50 rejected claims did not increment | **PASS** |
| 6 | Repeated release on already released application | Returns `nil` (idempotent / non-damaging) | Returned `nil` | **PASS** |
| 7 | Request active state matrix (`:pending`, `:in-flight`, `:retrying`) | All active states block claim | All 3 active states rejected claims (`nil`) | **PASS** |
| 8 | Request terminal state matrix (`:finished`, `:cancelled`) | Terminal states permit claims | Both terminal states allowed claims | **PASS** |
| 9 | Stale request generation (req gen 19 on app gen 20) | Stale generation does not block claim | Claim succeeded and was released cleanly | **PASS** |
| 10 | Forged claim tokens (matching run-id but fake app pointer; matching app pointer but fake run-id) | Rejected (`nil`); genuine claim releases cleanly | Both forged claims rejected (`nil`); genuine claim succeeded | **PASS** |
| 11 | `kargu-application-reset` cleanup | Clears active run, active request, resets status to `:idle` | Clean state; subsequent claim succeeds | **PASS** |
| 12 | 5-way Application isolation matrix ($5 \times 5 = 25$ release combinations) | Only $c_i$ releases $app_i$; all cross-releases $i \neq j$ fail | All 20 cross-releases rejected; all 5 matching releases succeeded | **PASS** |
| 13 | Dedicated ERT suite `tests/test-application-context.el` | 9/9 tests pass | 9 passed, 0 unexpected (0.12s) | **PASS** |
| 14 | Full Project ERT suite (953 tests) | 953/953 pass | 953 passed, 0 unexpected (43.56s) | **PASS** |
| 15 | Byte-compilation with `byte-compile-error-on-warn t` | 0 warnings, 0 errors | Exit code 0, 0 warnings/errors | **PASS** |
| 16 | Checkdoc docstring and formatting linting | 0 warnings | Exit code 0, 0 warnings | **PASS** |
| 17 | TLC formal model checking (`--mode`, `--edit-transaction`) | No errors found | Both specifications passed (20,179 states / 425 states) | **PASS** |
| 18 | Repository hygiene (no `.elc` files, `skills.md` and `.gitignore` untouched) | Clean working tree | Zero `.elc` files found; governance files untouched | **PASS** |

---

## Unchallenged Areas

- **Wave 1 through Wave 5 feature implementations**: Intentionally out of scope for Wave 0 Iteration 2 (Wave 0 scope establishes core boundaries, types, and test fixtures only).

---

## Conclusion & Verdict

All defects reported in Wave 0 Iteration 1 have been completely remediated. Empirical adversarial testing confirmed that the application coordinator invariants (ARCH-01/ARCH-12) and file revision snapshot contracts are robust against malformed inputs, cross-application interference, and concurrency edge cases.

**Final Verdict**: **APPROVE**
