# Independent Review & Adversarial Stress-Test Report (Wave 0)

**Reviewer**: `reviewer_wave0_2` (Wave 0 Independent Reviewer 2)  
**Date**: 2026-10-21  
**Target Milestone**: Wave 0: Coordinator Boundaries & Fixtures  
**Subject Under Review**: Wave 0 implementation and test deliverables produced by `worker_wave0_1`  

---

## 1. Review Summary

**Verdict**: **APPROVE**  
**Integrity Assessment**: **CLEAN (NO INTEGRITY VIOLATION)**  
**Overall Risk Assessment**: **LOW**

All acceptance criteria for Wave 0 set forth in `parallel-plan.md` §3 and `ORIGINAL_REQUEST.md` have been met and independently verified:
- Single-active-run invariant (ARCH-01/ARCH-12) is enforced in both `kargu-application-set-active-run` and `kargu-application-claim`.
- Dual-application isolation fixtures and test suites verify complete isolation between coordinator instances.
- Cross-boundary private function invocation in `kargu/tools/diff/track.el` is eliminated via the new public `kargu-file-current-revision` in `kargu/files.el`.
- Public contracts in `kargu/contract.el` load cleanly in isolated subprocesses without runtime or adapter dependencies.
- Full ERT test suite passes 100% (948 of 948 tests passed).
- Zero byte-compilation warnings with `(setq byte-compile-error-on-warn t)`.
- No lingering `.elc` artifacts in the repository.
- Exhaustive TLA+/TLC model checking passes with 0 errors across 5,958 mode states and 160 edit states.
- Git repository working tree governance for `skills.md`, `.gitignore`, and `.agents/` is respected.

---

## 2. Integrity Verification

As mandated by system integrity instructions, an adversarial check for cheating or fake implementations was conducted:
1. **Hardcoded test results / expected outputs**: Verified that production code in `kargu/application/coordinator.el`, `kargu/files.el`, `kargu/contract.el`, and `kargu/tools/diff/track.el` contains dynamic, generic logic and zero hardcoded test inputs or canned outputs.
2. **Dummy / facade implementations**: Verified that `kargu-file-current-revision` reads real `file-attributes` from disk, supports both buffer and path targets, checks file existence, and filters remote and empty paths. Verified that `kargu-application-claim` generates real claim structs, mutates status and generation, and validates busy states.
3. **Shortcuts bypassing tasks**: Verified that subprocess tests (`kargu-module-all-contracts-independent-test` and `kargu-module-dual-application-isolation-test`) spawn authentic `emacs -Q` batch subprocesses and verify feature isolation against forbidden runtime symbols.
4. **Verification artifact authenticity**: Independent runs of ERT tests, byte-compilation, and TLC scripts executed directly by this reviewer confirmed all results reported by upstream workers.

---

## 3. Findings

### [Minor / Advisory for Wave 1 Package A] Finding 1: Claim-App Slot Verification in `kargu-application-release`
- **What**: When releasing a claim, `kargu-application-release` matches the claim's `run-id` against the target application's active run, but does not verify whether the claim token's `:app` reference matches the target application.
- **Where**: `kargu/application/coordinator.el:230-240`
- **Why**: If two distinct `kargu-application` instances (`app-a` and `app-b`) both have an active run with identical run ID strings (e.g., `"run-1"`), calling `(kargu-application-release app-a claim-b)` where `claim-b` belongs to `app-b` (`(kargu-application-claim-app claim-b) == app-b`) succeeds in releasing `app-a`.
- **Stress-Test Evidence**:
  ```elisp
  (let ((app-a (kargu-application-create :status :idle :generation 0))
        (app-b (kargu-application-create :status :idle :generation 0)))
    (let ((claim-a (kargu-application-claim app-a :run-id "same-run"))
          (claim-b (kargu-application-claim app-b :run-id "same-run")))
      (kargu-application-release app-a claim-b))) ; Returns t and clears app-a!
  ```
- **Risk Assessment**: Low for Wave 0, as applications generated via `kargu-test-with-dual-applications` start with distinct generation offsets (0 and 100), ensuring unique automatic run IDs.
- **Suggestion**: In Wave 1 Package A, tighten `kargu-application-release` to ensure `(or (null (kargu-application-claim-app claim)) (eq (kargu-application-claim-app claim) target))`.

### [Informational] Finding 2: Result Type Framing in Target Specification vs Wave 0 Implementation
- **What**: In `architecture-contracts.md` §1.4, target signatures show `kargu-application-claim` returning `(kargu-ok kargu-application-claim)` and `kargu-application-release` returning `(kargu-ok t)`. The Wave 0 coordinator implementation returns raw claim structs or signals errors (with `:no-error` returning nil).
- **Where**: `architecture-contracts.md:89-95` vs `kargu/application/coordinator.el:200-240`
- **Why**: As documented in `parallel-plan.md` §3 ("Aşağıdaki adlar hedef sözleşme adlarıdır, mevcut API varmış gibi çağrılmaz; gerçek imzalar ilk consumer testleriyle burada sabitlenir"), Wave 0 establishes foundational boundaries and fixtures without breaking existing consumers. Full migration to Result-wrapped claim calls will occur in Wave 1 Package A when callers (`kargu/loop.el`, `kargu/chat.el`) are refactored.
- **Suggestion**: Worker Wave 1 Package A should adopt the Result-wrapped signature during caller migration.

---

## 4. Adversarial Review & Stress-Test Results

| Test Scenario | Expected Behavior | Actual Behavior | Result |
|---------------|-------------------|-----------------|--------|
| **ARCH-01 Multiple Active Runs**: Call `kargu-application-set-active-run` with second run on busy instance | Signal error (ARCH-01) | Signaled `error: Kargu: application already has an active run (ARCH-01): ...` | **PASS** |
| **ARCH-01 Claim Re-entrancy**: Call `kargu-application-claim` on already claimed application | Signal error (ARCH-01) | Signaled `error: Kargu: application already has an active run (ARCH-01): ...` | **PASS** |
| **ARCH-01 Claim Re-entrancy with `:no-error t`**: Call `kargu-application-claim` with `:no-error t` on busy app | Return `nil` safely | Returned `nil` | **PASS** |
| **Release Mismatched Claim**: Call `kargu-application-release` with different claim token | Return `nil`, retain active run | Returned `nil`, active run remained intact | **PASS** |
| **Clean Subprocess Module Isolation**: Load each of the 8 contract modules in `emacs -Q` batch without runtime | Load cleanly with 0 dependencies | All 8 contract modules loaded independently with 0 runtime features | **PASS** |
| **`kargu-file-current-revision` on Missing File**: Pass nonexistent file path | Return `nil` without error | Returned `nil` | **PASS** |
| **`kargu-file-current-revision` on Remote Path**: Pass TRAMP-like path `/ssh:host:/path` | Return `nil` (fail closed against hang) | Returned `nil` | **PASS** |
| **`kargu-file-current-revision` on Unvisiting Buffer**: Pass scratch buffer | Return `nil` | Returned `nil` | **PASS** |
| **`kargu-file-current-revision` on Live File Buffer**: Pass buffer visiting disk file | Return valid `kargu-file-revision` | Returned valid `kargu-file-revision` record | **PASS** |
| **Dual-Application Teardown Unwind**: Signal error inside `kargu-test-with-dual-applications` | `unwind-protect` resets both instances | Both instances cleanly reset via `kargu-application-reset` | **PASS** |

---

## 5. Verified Claims Summary

1. **Full ERT Test Suite**:
   - Command: `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
   - Claimed: 948 passed, 0 failed, 0 errors.
   - Verified: **948 passed, 0 failed, 0 errors (46.74 sec)**. Status: **PASS**.
2. **Byte-Compilation under `byte-compile-error-on-warn t`**:
   - Command: Byte-compile all 8 modified and new Elisp files under `(setq byte-compile-error-on-warn t)`.
   - Claimed: 0 warnings, 0 errors.
   - Verified: **0 warnings, 0 errors**. Status: **PASS**.
3. **No Artifact Leftovers**:
   - Command: `find . -name "*.elc"`
   - Claimed: Empty.
   - Verified: **Empty**. Status: **PASS**.
4. **TLC Model Checking**:
   - Command: `bash proof/run_tlc.sh --mode` and `bash proof/run_tlc.sh --edit-transaction`.
   - Claimed: 0 errors (5958 states, 160 states).
   - Verified: **Both exited code 0, 0 errors**. Status: **PASS**.
5. **Git Tree Protection**:
   - Command: `git status --short`, `git diff .gitignore`, `ls -la --time-style=full-iso .gitignore skills.md`
   - Claimed: `skills.md`, `.gitignore`, and `.agents/` remain unstaged and untouched by Wave 0.
   - Verified: **Untouched by Wave 0**. Modification timestamps on `.gitignore` (2026-10-18) and `skills.md` (2026-10-17) predate commit `262850b` and Wave 0. Status: **PASS**.

---

## 6. Conclusion

Wave 0 is complete, correct, and robust. The single-active-run invariant and dual-application fixtures provide the necessary bedrock for parallel execution in Wave 1. The orchestrator may proceed immediately to Wave 1.
