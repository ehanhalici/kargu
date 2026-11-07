# Wave 0 Empirical Challenge Report

**Agent**: `challenger_wave0_2` (Wave 0 Empirical Challenger 2)  
**Date**: 2026-10-21  
**Milestone**: Wave 0  
**Verdict**: **APPROVE**

---

## Challenge Summary

**Overall risk assessment**: **LOW**

Formal TLA+ model checks, contract module isolation fixtures, full ERT suites (948 tests), and byte-compilation cleanliness checks were executed directly and empirically reproduced. The coordinator foundations for Wave 0 establish strict contract boundaries without breaking offline capabilities or leaking mutable state.

---

## 1. Formal Proofs & Model Checking (TLC)

Empirical execution of TLC model checking across specifications using the Nix-backed TLA+ tools:

| Model Flag | Specification | States Generated | Distinct States | Search Depth | Status |
|---|---|---|---|---|---|
| `--mode` | `ModeMC.tla` (`KarguMode`) | 20,179 | 5,958 | 17 | **PASSED** (0 errors) |
| `--edit-transaction` | `EditMC.tla` (`KarguEdit`) | 425 | 160 | 10 | **PASSED** (0 errors) |
| `--restore` | `RestoreMC.tla` (`KarguRestore`) | 115 | 54 | 6 | **PASSED** (0 errors) |
| `--plan` | `PlanMC.tla` (`KarguPlan`) | 22,231 | 6,293 | 25 | **PASSED** (0 errors) |
| `--approval` | `ApprovalMC.tla` (`KarguApproval`) | 8,194 | 1,536 | 11 | **PASSED** (0 errors) |
| `--selection` | `SelectionMC.tla` (`KarguSelection`) | 3,690,151 | 640,440 | 19 | **PASSED** (0 errors) |
| `--process` | `ProcessMC.tla` (`KarguProcess`) | 535 | 179 | 9 | **PASSED** (0 errors) |
| `--verification` | `VerificationMC.tla` (`KarguVerification`) | 439 | 68 | 7 | **PASSED** (0 errors) |

All 8 checked models completed exhaustively with zero invariant violations, deadlocks, or errors.

---

## 2. Contract Module Independence & Subprocess Matrix

Executed `tests/test-modules.el` via clean subprocess batch Emacs:
- **Command**: `emacs -Q --batch -L . -l tests/test-modules.el -f ert-run-tests-batch-and-exit`
- **Result**: **49/49 tests passed** (0 failures, 0 errors, 30.34s runtime).

### Key Invariants Empirically Confirmed:
1. **Contract Autonomy (`kargu-module-all-contracts-independent-test`)**: All public contract features (`kargu/contract`, `kargu/contract/constants`, `kargu/contract/types`, `kargu/contract/result`, `kargu/contract/assert`, `kargu/contract/file-window`, `kargu/contract/history`, `kargu/contract/selection`) load in `emacs -Q` without initializing or loading any runtime modules (`kargu/core`, `kargu/state`, `kargu/chat`, `kargu/loop`, `kargu/ui`).
2. **Dual-Application Isolation (`kargu-module-dual-application-isolation-test`)**: Two distinct application coordinators run independently in the same Emacs process without sharing status, run ID, or generation state. A second active run on an application instance is strictly rejected (ARCH-01/ARCH-12).
3. **Detachable Adapters & Missing Sources**: Removal matrices confirm chat and core reading/editing survive when LSP, Dape, Diff, Search, Git, Bash, Skill, or Webfetch are physically removed from the package tree.

---

## 3. Byte-Compilation & Artifact Cleanliness

### A. Modified & New Wave 0 Files (Isolated Compilation)
All 8 modified and new files under `kargu/` and `tests/` were compiled individually in isolated batch Emacs with `(setq byte-compile-error-on-warn t)`:
- `kargu/application/coordinator.el`: **PASSED** (exit 0, 0 warnings, 0 errors)
- `kargu/contract.el`: **PASSED** (exit 0, 0 warnings, 0 errors)
- `kargu/files.el`: **PASSED** (exit 0, 0 warnings, 0 errors)
- `kargu/tools/diff/track.el`: **PASSED** (exit 0, 0 warnings, 0 errors)
- `tests/run-tests.el`: **PASSED** (exit 0, 0 warnings, 0 errors)
- `tests/test-helpers.el`: **PASSED** (exit 0, 0 warnings, 0 errors)
- `tests/test-modules.el`: **PASSED** (exit 0, 0 warnings, 0 errors)
- `tests/test-application-context.el`: **PASSED** (exit 0, 0 warnings, 0 errors)

### B. Full Repository Compilation (154 Production + 70 Test Files)
- **154 Production Files**: Tested with `(setq byte-compile-error-on-warn t)` in standard package environment (`(require 'kargu)`). **154/154 compiled cleanly with 0 failures, 0 warnings, 0 errors**.
- **70 Test Files**: Tested with `(setq byte-compile-error-on-warn t)` in test harness environment (`(require 'tests/test-helpers)`). **70/70 compiled cleanly with 0 failures, 0 warnings, 0 errors**.
- **Leftover Artifacts**: Verified via `find . -name "*.elc"` returning 0 files. Zero `.elc` remnants exist in the working tree.

---

## 4. Adversarial Challenges & Stress Tests

### [Low] Challenge 1: Isolated File Compilation vs. Package Loading Order
- **Assumption challenged**: Every single historical production file compiles in a bare `emacs -Q` subprocess without requiring `kargu` first.
- **Empirical observation**: When compiling in 100% isolation without prior `(require 'kargu)`:
  - `kargu/chat/complete.el` calls `(kargu-eglot-connected-p)` without declaring it via `declare-function`.
  - `kargu/tools/lsp/skeleton.el` references `kargu-lsp--kind-label` defined in `symbols.el`.
  - 15 legacy test files have unresolved symbol references without `test-helpers.el`.
- **Blast radius**: None for Wave 0. In standard package loading order or when `(require 'kargu)` is loaded, all 154 production files and all 70 test files compile cleanly with zero errors/warnings. Furthermore, historical test lint debt is already explicitly scheduled for resolution in Wave 5 Package O (`parallel-plan.md` Section 8).
- **Mitigation / Next Step**: Coordinator or Wave 4/J should add `(declare-function kargu-eglot-connected-p "kargu/tools/lsp/context" ())` to `kargu/chat/complete.el` when touching chat/lsp boundaries in later waves.

### [Low] Challenge 2: Boundary Robustness of `kargu-file-current-revision`
- **Assumption challenged**: `kargu-file-current-revision` might throw unhandled errors on malformed arguments, remote paths, dead buffers, or non-existent files.
- **Empirical observation**: Tested `kargu-file-current-revision` with:
  - Non-existent file path string -> returns `nil`.
  - Empty string `""` / whitespace string `"   "` -> returns `nil`.
  - `nil`, number `12345`, symbol `'foo` -> returns `nil`.
  - Live buffer not visiting file -> returns `nil`.
  - Dead buffer -> returns `nil`.
  - Live buffer visiting disk file -> returns valid `kargu-file-revision` matching disk attributes.
- **Blast radius**: Completely safe. The implementation wraps attribute fetching in `condition-case nil` and validates targets defensively.

### [Low] Challenge 3: Application Claim Lifecycle Reentrancy and Stale Tokens
- **Assumption challenged**: Concurrent claims, reentrant calls, or mismatched release tokens might corrupt coordinator state or leave the application permanently locked.
- **Empirical observation**:
  - Double-claiming an application instance without `:no-error` immediately signals an error with message: `"Kargu: application already has an active run (ARCH-01)"`.
  - Claiming with `:no-error t` safely returns `nil` without corrupting the existing run.
  - Releasing with a mismatched/fake claim token returns `nil` and preserves the active run.
  - Releasing with the valid token sets `active-run = nil` and transitions status to `:idle`.
  - Double release returns `nil` idempotently.
- **Blast radius**: Verified solid. Concurrency and claim ownership invariants hold.

---

## 5. Stress Test Results Summary

| Target / Scenario | Expected Behavior | Actual Behavior | Result |
|---|---|---|---|
| `bash proof/run_tlc.sh --mode` | Exhaustive check passes | 20,179 states, depth 17 | **PASS** |
| `bash proof/run_tlc.sh --edit-transaction` | Exhaustive check passes | 425 states, depth 10 | **PASS** |
| `tests/test-modules.el` | 49/49 ERT tests pass in subprocess | 49/49 passed in 30.34s | **PASS** |
| Full ERT Test Suite | 948 tests pass (0 failures, 0 errors) | 948/948 passed in 44.37s | **PASS** |
| Wave 0 Modified/New Files Byte-Compile | Clean with `byte-compile-error-on-warn t` | 8/8 exit 0 | **PASS** |
| 154 Production Files Byte-Compile | Clean with `byte-compile-error-on-warn t` | 154/154 exit 0 | **PASS** |
| 70 Test Files Byte-Compile | Clean with `byte-compile-error-on-warn t` | 70/70 exit 0 | **PASS** |
| `.elc` Remnants Check | 0 `.elc` files remain in tree | 0 `.elc` files found | **PASS** |
| Checkdoc on Wave 0 Files | Clean docstrings and headers | 8/8 checkdoc CLEAN | **PASS** |
| `git diff --check` | Zero whitespace errors | Exit 0, output clean | **PASS** |

---

## 6. Unchallenged Areas

- **Wave 1 Implementation Packages (A, B, C)**: Out of scope for Wave 0 verification. Packages A, B, and C will be subjected to full empirical challenge during Wave 1.

---

## Conclusion & Verdict

**Verdict**: **APPROVE**  
Wave 0 meets all formal verification, architectural isolation, test suite integrity, and byte-compilation criteria specified in `ORIGINAL_REQUEST.md` and `parallel-plan.md`. The coordinator is cleared to proceed with Wave 1 dispatches.
