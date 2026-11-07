# Comprehensive Survey Report: Test, Compilation, Lint, and Formal Proof Systems

- **Date:** 2026-10-21
- **Author:** `teamwork_preview_explorer_survey_3` (Survey Test and Proof Explorer)
- **Working Directory:** `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_survey_3`
- **Integrity Mode:** Development / Read-Only Survey
- **Repository Revision:** `262850bcb8d1a882814e581f5f5d4696e51cc763`

---

## Executive Summary

1. **ERT Test Suite:**
   - **Baseline Test Count:** Exactly **942 / 942** ERT tests pass with **0 failures and 0 errors** in ~42.7 seconds.
   - **Files:** 65 files matching `tests/test-*.el` (including `test-helpers.el` and `test-modules.el`), plus 4 auxiliary files (`run-tests.el`, `module-boundaries.el`, `dape-fixtures.el`, `bench-process.el`) and 3 gitignored backup files (`*.el~`). Total 69 `.el` files under `tests/`.
   - **Batch Execution Command:** The batch test command specified in `ORIGINAL_REQUEST.md` was executed and independently verified:
     ```bash
     emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
     ```
   - **Critical Isolation Architecture:** `tests/test-helpers.el` establishes an `:around` advice on `ert-run-test` (`kargu-test--isolate`) that sandboxes every test inside a scratch directory (`kargu-test-scratch-root`), binds dynamic variables (`kargu-context-buffer`, `kargu-application--context`, `kargu--loop-run`, etc.), and isolates state. Running tests individually requires pre-initializing `package` and loading `kargu` and `tests/test-helpers`.

2. **Compilation and Lint Setup:**
   - **Byte-Compilation (`byte-compile-error-on-warn t`):**
     - All **69** test files compile with **0 errors and 0 warnings** under `(setq byte-compile-error-on-warn t)` when `kargu` and `tests/test-helpers` are preloaded.
     - All **154** production `.el` files compile with **0 errors and 0 warnings** when `kargu` is preloaded.
     - When compiled standalone in strict isolation without loading `kargu.el`, **152 of 154** production files compile cleanly; exactly **2** files have unstated external function declarations:
       - `kargu/chat/complete.el:373:11`: `kargu-eglot-connected-p` (defined in `kargu/tools/lsp/client.el`).
       - `kargu/tools/lsp/skeleton.el:139:24`: `kargu-lsp--kind-label` (defined in `kargu/tools/lsp/client.el`).
   - **Checkdoc Linting:**
     - Production code has minimal issues. Test files have pre-existing checkdoc debt (as recorded in `todo.md` TEST-01 / 73 warnings across 22 test files, missing `;;; Code:` sections in `test-contract.el` and `test-fake-agent.el`, unquoted symbols, and docstrings). This is slated for Wave 5 (Package O).
   - **Byte-Compiled `.elc` Files:** Verified **0** temporary `.elc` files present in source directories.

3. **TLA+ Formal Proof Setup:**
   - **Specifications:** Total **37** `.tla` files and **16** `.cfg` model configuration files under `proof/`.
   - **Runner Script (`proof/run_tlc.sh`):** Fully operational. Automatically bridges to `nix-shell ../shell.nix` if `tlc` is not in PATH, launching TLC 2.19 (rev: 5a47802) with 24 workers.
   - **Verified Models:** Multiple models were executed and verified exhaustive with 0 errors:
     - `RestoreMC` (`--restore`): 115 states, 54 distinct, depth 6, 0.2s.
     - `EditMC` (`--edit-transaction`): 425 states, 160 distinct, depth 10, 0.4s.
     - `VerificationMC` (`--verification`): 439 states, 68 distinct, depth 7, 0.4s.
     - `ModeMC` (`--mode`): 20,179 states, 5,958 distinct, depth 15, 1.2s.
     - `ApprovalMC` (`--approval`): 8,194 states, 1,536 distinct, depth 11, 0.8s.
     - `ProcessMC` (`--process`): 535 states, 179 distinct, depth 9, 0.3s.
     - `DebugStartupMC` (`--debug-startup`): 8,465 states, 1,544 distinct, depth 12, 1.1s.
     - `DebugCloseMC` (`--debug-close`): 71 states, 20 distinct, depth 7, 0.2s.
     - `DebugWatchMC` (`--debug-watch`): 1,053 states, 412 distinct, depth 10, 0.4s.
     - `DebugExecutionMC` (`--debug-execution`): 2,297 states, 936 distinct, depth 9, 0.6s.
     - `DebugReadinessMC` (`--debug-readiness`): 1,450 states, 464 distinct, depth 8, 0.5s.
     - `DebugSelectionMC` (`--debug-selection`): 4,553 states, 934 distinct, depth 8, 0.8s.
   - **Subsystem Coverage Map:** Formally identifies which subsystems are model-checked in TLA+ vs bounded via ERT contract suites.

---

## 1. ERT Test Suite Deep Dive

### 1.1 Test File Inventory (`tests/`)

There are 72 files in the `tests/` directory:
- **65 test suite files matching `^test-.*\.el$`**:
  - `tests/test-address.el`
  - `tests/test-api.el`
  - `tests/test-async.el`
  - `tests/test-attach.el`
  - `tests/test-cache.el`
  - `tests/test-chat.el`
  - `tests/test-chat-state.el`
  - `tests/test-compact.el`
  - `tests/test-config.el`
  - `tests/test-confirm.el`
  - `tests/test-contract.el`
  - `tests/test-dape-admission.el`
  - `tests/test-dape-commands.el`
  - `tests/test-dape-compile.el`
  - `tests/test-dape-execution.el`
  - `tests/test-dape-lifecycle.el`
  - `tests/test-dape-readiness.el`
  - `tests/test-dape-selection.el`
  - `tests/test-dape-startup.el`
  - `tests/test-dape-watch.el`
  - `tests/test-dape-workspace.el`
  - `tests/test-deps.el`
  - `tests/test-dynamic-models.el`
  - `tests/test-edit-transaction.el`
  - `tests/test-fake-agent.el`
  - `tests/test-file-window.el`
  - `tests/test-fs.el`
  - `tests/test-git.el`
  - `tests/test-heal.el`
  - `tests/test-helpers.el` (Fixture and isolation infrastructure)
  - `tests/test-history.el`
  - `tests/test-history-store.el`
  - `tests/test-integration.el`
  - `tests/test-json.el`
  - `tests/test-languages.el`
  - `tests/test-laws.el`
  - `tests/test-loop.el`
  - `tests/test-lsp.el`
  - `tests/test-lsp-project-diagnostics.el`
  - `tests/test-lsp-settle.el`
  - `tests/test-metadata.el`
  - `tests/test-mode-ownership.el`
  - `tests/test-model-store.el`
  - `tests/test-modules.el` (Isolated sub-process module boundary matrix)
  - `tests/test-parameters.el`
  - `tests/test-patch.el`
  - `tests/test-permission.el`
  - `tests/test-permission-operation.el`
  - `tests/test-plan.el`
  - `tests/test-plan-async.el`
  - `tests/test-process.el`
  - `tests/test-providers.el`
  - `tests/test-security.el`
  - `tests/test-selection.el`
  - `tests/test-session.el`
  - `tests/test-session-restore.el`
  - `tests/test-session-routing.el`
  - `tests/test-session-storage.el`
  - `tests/test-session-validate.el`
  - `tests/test-state.el`
  - `tests/test-stream.el`
  - `tests/test-tool-calls.el`
  - `tests/test-tool-registry.el`
  - `tests/test-tools.el`
  - `tests/test-webfetch.el`
- **4 auxiliary support files**:
  - `tests/run-tests.el`: Master runner requiring all 65 test modules and executing `(ert-run-tests-batch-and-exit "^kargu-")`.
  - `tests/module-boundaries.el`: Legacy facade dependency budget definition (`kargu-module-test--legacy-dependencies`).
  - `tests/dape-fixtures.el`: Mock DAP adapter server and client fixtures.
  - `tests/bench-process.el`: Process output benchmark harness.
- **3 editor backup files** (ignored by git):
  - `test-dape-compile.el~`, `test-dape-readiness.el~`, `test-file-window.el~`.

### 1.2 `tests/run-tests.el` Analysis

`tests/run-tests.el` (97 lines):
- Lines 6–15: Dynamic load-path calculation finding repository root and appending `.` and `tests` to `load-path`.
- Line 17: Sets `(setq load-prefer-newer t)`.
- Lines 19–20: Requires `ert` and `kargu`.
- Lines 21–86: Explicitly requires `tests/test-helpers`, `tests/test-modules`, and all 63 test suites.
- Lines 87–90: Defines interactive runner `kargu-run-all-tests` with selector `"^kargu-"`.
- Lines 92–93: In batch mode (`noninteractive`), runs `(ert-run-tests-batch-and-exit "^kargu-")`.

### 1.3 Verifying Full Batch Test Execution

The command specified in `ORIGINAL_REQUEST.md`:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
```
**Observation & Output:**
```
Ran 942 tests, 942 results as expected, 0 unexpected (2026-10-21 20:08:55+0000, 42.662087 sec)
Exit Code: 0
```
- **Total Test Count:** Exactly **942 tests**.
- **All 942 pass** with 0 unexpected failures and 0 skipped.
- **Duration:** 42.66 seconds on this machine.

### 1.4 How Tests Can Be Run Individually or Per Module

#### The Isolation Trap (Why naive `-l tests/test-xxx.el` fails)
In `tests/test-helpers.el`:
```elisp
(defun kargu-test--isolate (run-test &rest args)
  (let ((default-directory (kargu-test-scratch-root))
        (kargu-permission--override-root (kargu-test-scratch-root))
        (kargu--state-store (copy-tree kargu--state-store))
        (kargu-session--context (kargu-test-session-with-history))
        (kargu--session-id kargu--session-id)
        (kargu-context-buffer kargu-context-buffer)
        (kargu--loop-run kargu--loop-run)
        (kargu--busy kargu--busy)
        (kargu--generation (bound-and-true-p kargu--generation))
        ...)
    (apply run-test args)))

(advice-add 'ert-run-test :around #'kargu-test--isolate)
```
1. `ert-run-test` is advised to execute within `kargu-test--isolate`.
2. `kargu-test--isolate` reads `kargu-context-buffer` and `kargu--state-store`. In an uninitialized Emacs where `kargu.el` was not loaded, `kargu-context-buffer` is void, causing `Debugger entered--Lisp error: (void-variable kargu-context-buffer)`.
3. Furthermore, `kargu.el` requires third-party packages installed in ELPA/package (e.g. `plz`). Running `emacs -Q` without `package-initialize` will cause `(error "Cannot open load file: plz")`.

#### Verified Correct Invocation for Individual Suites:
To run a single test suite (e.g., `test-patch.el`):
```bash
emacs -Q --batch -L . \
  --eval "(progn (require 'package) (package-initialize))" \
  -l kargu \
  -l tests/test-helpers.el \
  -l tests/test-patch.el \
  -f ert-run-tests-batch-and-exit
```
- **Execution Time:** **0.41 seconds** (16 tests passed).
- Compared to 42.66 seconds for the full test suite, running focused tests during wave development provides a **100x speedup**.

#### Verified Correct Invocation with a Name/Regex Selector:
```bash
emacs -Q --batch -L . \
  --eval "(progn (require 'package) (package-initialize))" \
  -l kargu \
  -l tests/test-helpers.el \
  -l tests/test-patch.el \
  --eval '(ert-run-tests-batch-and-exit "^kargu-patch-add")'
```
- **Execution Time:** **0.08 seconds** (1 test passed).

---

## 2. Compilation and Lint Verification Setup

### 2.1 Byte-Compilation Verification

**Requirements:**
- Zero byte-compilation warnings on all modified and new Elisp files under `kargu/` and `tests/` with `(setq byte-compile-error-on-warn t)`.
- No temporary byte-compiled `.elc` files left in source directories.

#### Verification of Test Files (69 files under `tests/`):
All 69 test files were compiled individually in batch mode with:
```bash
emacs -Q --batch -L . -L tests \
  --eval "(progn (require 'package) (package-initialize) (require 'kargu) (require 'tests/test-helpers) (setq byte-compile-error-on-warn t))" \
  -f batch-byte-compile <test-file>
```
**Result:** **69 / 69 passed** cleanly with zero errors and zero warnings.

#### Verification of Production Code (154 files under `kargu/` + `kargu.el`):
When compiled with `(require 'kargu)` preloaded:
**Result:** **154 / 154 passed** with zero warnings and zero errors.

#### Standalone Strict Compilation (Isolated File without `(require 'kargu)`):
When all 154 files are compiled in total isolation (each file starting from a fresh `emacs -Q` without preloading `kargu.el`):
- **152 / 154 files pass cleanly.**
- Exactly **2 files** produce compiler warnings/errors due to unstated declarations of functions defined in sibling modules:
  1. `kargu/chat/complete.el:373:11`:
     `Error: the function ‘kargu-eglot-connected-p’ is not known to be defined.`
     (Function is defined in `kargu/tools/lsp/client.el`).
  2. `kargu/tools/lsp/skeleton.el:139:24`:
     `Error: the function ‘kargu-lsp--kind-label’ is not known to be defined.`
     (Function is defined in `kargu/tools/lsp/client.el`).

#### Standard Production Byte-Compilation Command:
Workers should verify modified files using:
```bash
emacs -Q --batch -L . -L tests \
  --eval "(progn (require 'package) (package-initialize) (require 'kargu) (setq byte-compile-error-on-warn t))" \
  -f batch-byte-compile <modified-file.el> && rm -f <modified-file.elc>
```

### 2.2 Checkdoc Verification

**Requirements & Context:**
`skills.md` and `parallel-plan.md` require clean checkdoc on new and modified files, while maintaining existing fixture false-positives.

#### Verified Batch Checkdoc Command:
```bash
emacs -Q --batch --eval '
(progn
  (require (quote checkdoc))
  (dolist (f command-line-args-left)
    (with-current-buffer (find-file-noselect f)
      (let ((checkdoc-diagnostic-buffer "*checkdoc-log*"))
        (when (get-buffer "*checkdoc-log*")
          (kill-buffer "*checkdoc-log*"))
        (checkdoc-current-buffer t)
        (when (get-buffer "*checkdoc-log*")
          (with-current-buffer "*checkdoc-log*"
            (let* ((lines (split-string (buffer-string) "\n"))
                   (warns (seq-filter (lambda (l)
                                        (and (not (string-prefix-p "*** " l))
                                             (not (string-prefix-p "\x0c" l))
                                             (not (string-empty-p (string-trim l)))))
                                      lines)))
              (when warns
                (message "CHECKDOC_WARN: %s\n%s" f (string-join warns "\n")))))))))
  (setq command-line-args-left nil))' <files...>
```

#### Pre-existing Checkdoc Debt:
As documented in `todo.md` line 382 (TEST-01):
- A known baseline of ~73 checkdoc warnings exists across 22 older test files (e.g. missing `;;; Code:` headers in `test-contract.el`, missing argument documentation in docstrings in `test-fake-agent.el`).
- Wave 5 (Package O) is explicitly scheduled to clean up this technical debt. Workers in Waves 0–4 must ensure they do not introduce **new** checkdoc warnings in modified or created files.

### 2.3 Status of Temporary `.elc` Files

A repository-wide scan was conducted:
```bash
find . -name "*.elc"
```
**Result:** **0** `.elc` files found. Source tree is completely clean of compilation artifacts.

---

## 3. TLA+ Formal Proof Setup Deep Dive

### 3.1 Inventory of Specifications and Models (`proof/`)

The `proof/` directory contains:
- **37 `.tla` files**
- **16 `.cfg` model configuration files**
- **1 runner script** (`run_tlc.sh`)
- **1 documentation file** (`README.md`)

#### Complete File Inventory:
| Model Configuration | TLA+ Harness | Underlying Domain Specification(s) | Primary Purpose |
|---|---|---|---|
| `MC.cfg` | `MC.tla` | `KarguLoop.tla`, `KarguProtocol.tla`, `KarguCircuit.tla`, `KarguTools.tla`, `KarguState.tla`, `KarguContract.tla` | Full agent loop, circuit breaker, protocol wall, tool gates, state store coherence. |
| `ModeMC.cfg` | `ModeMC.tla` | `KarguMode.tla` | Session mode preparation, ownership isolation, frozen mode during active work. |
| `EditMC.cfg` | `EditMC.tla` | `KarguEdit.tla` | Reviewed batch edit transactions, single delivery, foreign content rollback. |
| `RestoreMC.cfg` | `RestoreMC.tla` | `KarguRestore.tla` | Session restore, paired publication, failure preservation, revision checking. |
| `SelectionMC.cfg` | `SelectionMC.tla` | `KarguSelection.tla` | Owned immutable selection, picker callbacks, session epoch matching. |
| `ApprovalMC.cfg` | `ApprovalMC.tla` | `KarguApproval.tla` | Tool/permission execution approval, stale authority invalidation, single claim. |
| `ProcessMC.cfg` | `ProcessMC.tla` | `KarguProcess.tla` | Bounded process execution, output capture, stream EOF, deadlines, cancellation. |
| `DiagnosticsMC.cfg` | `DiagnosticsMC.tla` | `KarguDiagnostics.tla` | Diagnostic wait ownership, Flymake/Eglot freshness, version matching. |
| `VerificationMC.cfg` | `VerificationMC.tla` | `KarguVerification.tla` | Verification-batch ownership of pending edits, batch cleanup, replacement isolation. |
| `PlanMC.cfg` | `PlanMC.tla` | `KarguPlan.tla` | Plan artifact workflow, claim/dispatch lifecycle, rejection and cancellation. |
| `DebugStartupMC.cfg` | `DebugStartupMC.tla` | `KarguDebugStartup.tla` | Debugger adapter startup, dependency probing, deferred compilation, single delivery. |
| `DebugReadinessMC.cfg` | `DebugReadinessMC.tla` | `KarguDebugReadiness.tla` | Debugger readiness wait, token/project matching, adapter ambiguity rejection. |
| `DebugWatchMC.cfg` | `DebugWatchMC.tla` | `KarguDebugWatch.tla` | Debugger watch expression evaluation, origin checking, connection scoping. |
| `DebugExecutionMC.cfg` | `DebugExecutionMC.tla` | `KarguDebugExecution.tla` | Debugger execution wait, context collection, state generation tracking. |
| `DebugSelectionMC.cfg` | `DebugSelectionMC.tla` | `KarguDebugSelection.tla` | Debugger thread/frame selection, navigation consent, cache invalidation. |
| `DebugCloseMC.cfg` | `DebugCloseMC.tla` | `KarguDebugClose.tla` | Scoped debugger shutdown, resource release before completion, termination fallback. |

### 3.2 Analysis of `proof/run_tlc.sh`

`run_tlc.sh` (137 lines) operates as follows:
1. **Directory Context:** Automatically switches to the `proof/` directory (`cd "${SCRIPT_DIR}"`).
2. **Binary Resolution:** Checks for `tlc` binary in `PATH`. If missing, it transparently executes via `nix-shell "${SCRIPT_DIR}/../shell.nix" --run "bash run_tlc.sh <args>"`.
   - On this system, `nix-shell` resolves TLC to `/nix/store/2gfqp5bphf7kdy2p6nb4crb8q8x7jccb-tlaplus-1.7.4/bin/tlc` (TLC2 Version 2.19, 24 workers).
3. **Temporary Working Space:** Creates a fresh temporary directory `mktemp -d "${TMPDIR:-/tmp}/kargu-tlc.XXXXXX"`, passes `-metadir`, and traps `EXIT` to remove the directory cleanly.
4. **Command Routing:**
   - `./run_tlc.sh`: Exhaustive scan of `MC.tla`.
   - Focused flags: `--plan`, `--mode`, `--restore`, `--selection`, `--approval`, `--process`, `--diagnostics`, `--debug-startup`, `--debug-close`, `--debug-watch`, `--debug-execution`, `--edit-transaction`, `--verification`, `--debug-selection`, `--debug-readiness`.
   - Simulation: `--simulate [N]` (Monte Carlo exploration; smoke test only, not an exhaustive proof).
5. **Success / Failure Criteria:** Strict validation (`pipefail`). Fails if TLC exit code != 0, if output contains `Error:`, `Invariant .* is violated`, `Deadlock reached`, or if `Model checking completed. No error has been found` is absent.

### 3.3 Empirical Model Verification Results

During this survey, 12 models were executed and independently validated:

| Option / Model | States Generated | Distinct States | Search Depth | Time | Verdict |
|---|---|---|---|---|---|
| `--restore` | 115 | 54 | 6 | 0.2s | **PASSED (0 errors)** |
| `--edit-transaction` | 425 | 160 | 10 | 0.4s | **PASSED (0 errors)** |
| `--verification` | 439 | 68 | 7 | 0.4s | **PASSED (0 errors)** |
| `--mode` | 20,179 | 5,958 | 15 | 1.2s | **PASSED (0 errors)** |
| `--approval` | 8,194 | 1,536 | 11 | 0.8s | **PASSED (0 errors)** |
| `--process` | 535 | 179 | 9 | 0.3s | **PASSED (0 errors)** |
| `--debug-startup` | 8,465 | 1,544 | 12 | 1.1s | **PASSED (0 errors)** |
| `--debug-close` | 71 | 20 | 7 | 0.2s | **PASSED (0 errors)** |
| `--debug-watch` | 1,053 | 412 | 10 | 0.4s | **PASSED (0 errors)** |
| `--debug-execution` | 2,297 | 936 | 9 | 0.6s | **PASSED (0 errors)** |
| `--debug-readiness` | 1,450 | 464 | 8 | 0.5s | **PASSED (0 errors)** |
| `--debug-selection` | 4,553 | 934 | 8 | 0.8s | **PASSED (0 errors)** |

*Note on Full Main Loop (`MC.tla`)*:
The full main loop model (`MC.tla` / `MC.cfg`) encompasses the entire state space of `KarguLoop`, `KarguProtocol`, `KarguCircuit`, `KarguTools`, and `KarguState`. Its exhaustive verification explores **729,094,900 states** (85,318,093 distinct states, depth 43) and takes ~10 minutes on 24 cores. Per `parallel-plan.md` Section 9, it is required at final wave integration merge gates when loop/protocol FSM transitions are modified, while individual workers rely on their respective focused model flags during development.

### 3.4 Subsystem to Model Mapping

The following table provides the definitive mapping of Kargu architectural subsystems to formal verification models:

| Subsystem | Wave & Package | TLA+ Specification / Harness | TLC Option | Status & Boundaries |
|---|---|---|---|---|
| **Mode** | Wave 0 / Wave 1 (A) | `KarguMode.tla` (`ModeMC`) | `--mode` | **Fully Modeled**: Single delivery, intent supersession, mode freeze during active work. |
| **Edit** | Wave 1 (B) / Wave 4 (L) | `KarguEdit.tla` (`EditMC`) | `--edit-transaction` | **Fully Modeled**: Process-local reviewed batch, single delivery, foreign content rollback. (CAS/OS crash recovery is ERT). |
| **Connection** | Wave 1 (C) | None (Integrated) | N/A | **Partial / ERT**: Credential/config snapshot and discovery are verified via ERT (`test-config.el`, `test-providers.el`). Connection epoch checked in `SelectionMC`. |
| **Approval** | Wave 1 (B) / Wave 2 (D) | `KarguApproval.tla` (`ApprovalMC`) | `--approval` | **Fully Modeled**: Single claim, authority staleness, cancellation before continuation. |
| **Tools** | Wave 2 (D) | `KarguTools.tla` (`MC`) | Default (`MC.tla`) | **Fully Modeled**: Single gate, doom loop detection, tool registration/policy invariants. |
| **Circuit** | Wave 2 (E) | `KarguCircuit.tla` (`MC`) | Default (`MC.tla`) | **Fully Modeled**: Breaker states (CLOSED, OPEN, HALF_OPEN, PROBING), canary claim/release, cooldown. |
| **Transport** | Wave 2 (E) | None (Abstracted) | N/A | **ERT Bound**: SSE parser, buffer growth, chunking, and HTTP streaming are bounded at loop ingress and proven via ERT (`test-stream.el`, `test-webfetch.el`). |
| **Process** | Wave 2 (F) | `KarguProcess.tla` (`ProcessMC`) | `--process` | **Fully Modeled**: Output limits, buffer bounds, timeout/deadline, cancellation before/after startup. |
| **Loop** | Wave 3 (G) | `KarguLoop.tla` (`MC`) | Default (`MC.tla`) | **Fully Modeled**: Core 13-state machine (`IDLE` to `DONE`/`STOPPED`), action dispatch, transitions. |
| **Protocol** | Wave 3 (G) | `KarguProtocol.tla` (`MC`) | Default (`MC.tla`) | **Fully Modeled**: Protocol wall, turn merging, orphan tool response handling, compaction repair. |
| **Selection** | Wave 3 (H) | `KarguSelection.tla` (`SelectionMC`) | `--selection` | **Fully Modeled**: Immutable selection, picker callback epoch matching, lock during work. |
| **Plan** | Wave 3 (H) | `KarguPlan.tla` (`PlanMC`) | `--plan` | **Fully Modeled**: Artifact claim/dispatch, rejection, single owner dispatch, invalidation on close. |
| **Diagnostics** | Wave 4 (J) | `KarguDiagnostics.tla` (`DiagnosticsMC`) | `--diagnostics` | **Fully Modeled**: Diagnostic freshness, server version matching, buffer closure, cancellation. |
| **Verification** | Wave 4 (J) | `KarguVerification.tla` (`VerificationMC`) | `--verification` | **Fully Modeled**: Changed-file batch ownership, setup failure, replacement edit isolation. |
| **Debug** | Wave 4 (K) | 6 dedicated models: `DebugStartupMC`, `DebugReadinessMC`, `DebugWatchMC`, `DebugExecutionMC`, `DebugSelectionMC`, `DebugCloseMC` | `--debug-*` | **Fully Modeled**: Complete 6-phase DAP lifecycle modeled and verified exhaustively. |
| **Restore** | Wave 4 (L) | `KarguRestore.tla` (`RestoreMC`) | `--restore` | **Fully Modeled**: Session restore, paired publication, revision matching, rollback on error. |
| **Writer** | Wave 4 (L) | None (Integrated) | N/A | **ERT Bound**: Filesystem persistence contracts, conflict detection, and directory walks proven in ERT (`test-fs.el`, `test-patch.el`). |
| **Backend** | Wave 5 (M) | None | N/A | **ERT Contract Suite**: Fake agent backend verified via `tests/test-fake-agent.el`. |
| **Budget / Log** | Wave 1 (A) / Wave 3 (I) | None | N/A | **ERT Bound**: Token accounting and log minimization/redaction proven via ERT (`test-state.el`, `test-chat.el`). |

---

## 4. Guidance for Wave Workers and Coordinator

1. **Test Execution Protocol during Development:**
   - **Do NOT run the entire 942-test batch suite on every incremental edit** (saves 42 seconds per run).
   - Pre-initialize `package`, preload `kargu` and `tests/test-helpers`, and run only the test file you are editing:
     ```bash
     emacs -Q --batch -L . \
       --eval "(progn (require 'package) (package-initialize))" \
       -l kargu \
       -l tests/test-helpers.el \
       -l tests/<your-test>.el \
       -f ert-run-tests-batch-and-exit
     ```
   - Before handing off a wave or package, run the complete 942-test batch suite to ensure 0 regressions.

2. **Byte-Compilation Checks:**
   - Always verify new and modified files with `(setq byte-compile-error-on-warn t)`.
   - Preload `kargu.el` so that inter-module function definitions are resolved.
   - Always delete generated `.elc` files immediately after compiling:
     ```bash
     emacs -Q --batch -L . -L tests \
       --eval "(progn (require 'package) (package-initialize) (require 'kargu) (setq byte-compile-error-on-warn t))" \
       -f batch-byte-compile <modified-files> && rm -f <modified-files-elc>
     ```

3. **Checkdoc Discipline:**
   - Run checkdoc on modified production files. Ensure headers have `;;; Code:`, docstrings document all arguments in capitals, and function symbols in docstrings are enclosed in curved quotes (e.g. \`symbol\').
   - Do not attempt to silence existing test fixture checkdoc warnings outside Wave 5 (Package O).

4. **TLA+ Model Checks:**
   - If modifying state machines or ownership protocols in a subsystem, identify the corresponding model in Section 3.4 and run `proof/run_tlc.sh --<subsystem>`.
   - Never commit state machine changes without verifying that the corresponding TLC model passes exhaustively.
