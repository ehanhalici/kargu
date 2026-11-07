# Wave 0 Independent Review & Adversarial Challenge Report

**Reviewer**: `reviewer_wave0_1` (Reviewer & Adversarial Critic)  
**Date**: 2026-10-21  
**Milestone**: Wave 0: Coordinator Boundaries & Fixtures  
**Subject**: Wave 0 implementation deliverables by `worker_wave0_1`  

---

## 1. Quality Review

### Review Summary

**Verdict**: APPROVE

All Wave 0 coordinator deliverables assigned in `parallel-plan.md` §3 and the dispatch instructions have been correctly, completely, and cleanly implemented without integrity violations, shortcuts, or regressions. All 948 ERT tests pass (an increase of +6 tests covering contract isolation and application lifecycle), byte-compilation with `byte-compile-error-on-warn t` produces zero warnings across all modified and new files, checkdoc produces zero warnings, zero `.elc` files remain, and TLA+/TLC model checking passes cleanly.

### Integrity Assessment

- **Hardcoded test results or expected outputs embedded in source code**: NONE.
- **Dummy or facade implementations**: NONE. All functions implement authentic logic with invariant checking.
- **Shortcuts or task bypasses**: NONE. Requirements implemented from scratch in designated locations.
- **Fabricated verification outputs or logs**: NONE. All test and compiler commands were independently executed and verified.
- **Self-certifying work without independent verification**: REJECTED. Independent reproduction completed in isolated subshells.

### Findings

#### [Major] Finding 1: Premature `file-exists-p` in `kargu-file-current-revision` Triggers Tramp on Remote Paths

- **What**: `(kargu-file-current-revision path)` triggers Tramp network access and signals an unhandled `file-error` when given a remote path string (e.g., `"/ssh:user@remote:/some/file"`).
- **Where**: `kargu/files.el:149-160`
- **Why**: In `kargu/files.el`, the `cond` branch checks `((and (stringp path) (file-exists-p path)) path)` before reaching the validation `(not (file-remote-p target))`. Because `file-exists-p` on a remote path invokes Tramp and sits outside the `condition-case` at line 160, an unhandled `file-error ("Tramp failed to connect...")` escapes, violating the docstring guarantee that `kargu-file-current-revision` returns `nil` for absent or unreadable targets.
- **Suggestion**: In Wave 4 Package L (which owns the filesystem writer contract and file revision enhancements), reorder the check to filter `(and (stringp path) (file-remote-p path))` before invoking `file-exists-p`, or wrap the entire resolution inside `condition-case`.

#### [Minor] Finding 2: Result Type Envelope Formalization Scheduled for Wave 1 Package A

- **What**: `kargu-application-claim` returns the `kargu-application-claim` struct directly (or `nil` with `:no-error t`) and `kargu-application-release` returns boolean `t`/`nil`, whereas `architecture-contracts.md` §1.4 describes Result envelopes (`(kargu-ok ...)` / `(kargu-err ...)`).
- **Where**: `kargu/application/coordinator.el:200-240` vs `architecture-contracts.md:89-95`
- **Why**: Per `parallel-plan.md` §3 lines 84-86, the contract names in the inventory are target interfaces to be finalized by consumer tests. The worker faithfully implemented the interim bootstrap signature requested in `worker_wave0_1/DISPATCH.md` Task 4. Full Result envelope integration is explicitly scheduled for Wave 1 Package A (`kargu/application/coordinator.el` refactor).
- **Suggestion**: Wave 1 Package A should transition `kargu-application-claim` and `kargu-application-release` to `kargu-ok` / `kargu-err` Result records as specified in `architecture-contracts.md`.

#### [Minor] Finding 3: Application Struct Fields Synchronization

- **What**: `kargu-application` struct definition was extended with `session-id` and `run-id` slots, but `kargu-application-claim` only mutates `active-run` and `status` without setting `session-id` and `run-id` on the target application instance.
- **Where**: `kargu/application/coordinator.el:128-129, 221-222`
- **Why**: `active-run` is currently used as the single-run gatekeeper, but leaving `session-id` and `run-id` unset on the instance means consumers reading those slots directly will see `nil`.
- **Suggestion**: In Wave 1 Package A, ensure `kargu-application-claim` populates `(setf (kargu-application-run-id target) run-id)` and `(setf (kargu-application-session-id target) session-id)`.

---

## 2. Adversarial Challenge Report

### Challenge Summary

**Overall risk assessment**: LOW

The Wave 0 deliverables provide robust isolation barriers. The single-active-run invariant strictly prevents duplicate concurrent claims on an application instance, and dual-application instances maintain isolated generation counters, statuses, and run claims.

### Challenges

#### [Medium] Challenge 1: Remote Tramp Path Stress in File Revision Bootstrap

- **Assumption challenged**: `kargu-file-current-revision` safely returns `nil` for any unvisitable or unreadable input.
- **Attack scenario**: Calling `(kargu-file-current-revision "/ssh:user@remote:/some/file")`.
- **Blast radius**: Tramp attempts an SSH handshake, which hangs on interactive prompts or crashes with `(file-error "Tramp failed to connect...")`.
- **Mitigation**: Move `(file-remote-p path)` check before any `file-exists-p` invocation.

#### [Low] Challenge 2: In-Flight Logical Request Collision on Application Claim

- **Assumption challenged**: An application coordinator cannot be claimed while background transport requests are in flight.
- **Attack scenario**: Application status is `:idle`, `active-run` is `nil`, but a live `kargu-logical-request` is in flight.
- **Result**: PASSED. `kargu-application-claim` checks `(or (kargu-application-active-run target) (kargu-application-work-active-p target))`. Because `work-active-p` inspects `(kargu-logical-request-live-p ...)`, the claim is correctly rejected with an error.

#### [Low] Challenge 3: Cross-Instance Application Mutation

- **Assumption challenged**: Setting active run, generation, or resetting on Application A cannot affect Application B.
- **Attack scenario**: Two instances `app-a` and `app-b` created via `kargu-test-make-dual-applications`. Mutate status, run, generation, and trigger `kargu-application-reset` on `app-a`.
- **Result**: PASSED. `app-b` retains its generation, run, and status intact. Subprocess isolation tests in `tests/test-modules.el` confirm this holds across clean Emacs processes.

---

## 3. Verified Claims

1. **ERT Test Suite Expansion**:
   - Claim: 948 tests passing (from 942 baseline).
   - Verification: Ran both directory glob require loop and `tests/run-tests.el`.
   - Result: **PASS** (948 passed, 0 failed, 0 errors, ~44s runtime).

2. **Byte-Compilation Hygiene**:
   - Claim: Zero byte-compilation warnings on all modified and new Elisp files with `(setq byte-compile-error-on-warn t)`.
   - Verification: Executed `byte-compile-file` across all 8 Elisp files with warning-as-error enabled.
   - Result: **PASS** (0 warnings, 0 errors, exit code 0).

3. **Checkdoc Hygiene**:
   - Claim: Zero checkdoc warnings across modified and new files.
   - Verification: Executed batch checkdoc across all 8 files checking `*checkdoc-warnings*`.
   - Result: **PASS** (0 warnings).

4. **Zero Leftover `.elc` Files**:
   - Claim: No `.elc` files left in tree.
   - Verification: Ran `find . -name "*.elc"`.
   - Result: **PASS** (0 files found).

5. **TLA+/TLC Model Checking**:
   - Claim: Mode and Edit Transaction models check cleanly without error.
   - Verification: Executed `bash proof/run_tlc.sh --mode` (5,958 distinct states) and `bash proof/run_tlc.sh --edit-transaction` (160 distinct states).
   - Result: **PASS** (both completed with 0 errors).

6. **Working Tree Protection**:
   - Claim: `skills.md`, `.gitignore`, and `.agents/` remain untouched and unstaged by Wave 0.
   - Verification: Checked `git status --short`. Verified that `M .gitignore` was a pre-existing modification present before Wave 0 started (documented in `explorer_survey_1`). No Wave 0 files staged.
   - Result: **PASS**.

---

## 4. Coverage Gaps & Unverified Items

- **Coverage Gaps**: None for Wave 0 scope.
- **Unverified Items**: None. All production code paths, fixtures, and models touched in Wave 0 were verified directly.
