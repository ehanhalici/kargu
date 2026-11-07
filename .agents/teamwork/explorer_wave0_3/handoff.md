# Handoff Report: Wave 0 Isolation Fixture Explorer

**Sender**: `teamwork_preview_explorer_wave0_3` (Wave 0 Isolation Fixture Explorer)  
**Recipient**: `teamwork_preview_orchestrator_1` / Wave 0 Coordinator Worker  
**Date**: 2026-10-21  
**Working Directory**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_3`  
**Reference Detailed Report**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_3/wave0_isolation_report.md`  

---

## 1. Observation

1. **Gate Invariant**: `parallel-plan.md` §3 lines 99-101 defines the Wave 0 acceptance gate verbatim:  
   `"İlk kapı: iki izole application fixture'ı birbirini değiştirmez; aynı application'da ikinci run reddedilir; opsiyonel modül yüklenmeden public sözleşmeler yüklenir. Salt tanım envanteri kod garantisi sayılmaz."`
2. **Current `kargu/application/coordinator.el` Active Run Implementation**:  
   Lines 173-180:
   ```elisp
   (defun kargu-application-set-active-run (run &optional app)
     "Set RUN as the active run on APP or the active coordinator."
     (let ((target (kargu-application-context app)))
       (setf (kargu-application-active-run target) run)
       (unless app
         (setq kargu--loop-run run))
       run))
   ```
   Direct execution test: Calling `(kargu-application-set-active-run "run-2" app)` when `app` already has active run `"run-1"` overwrites `"run-1"` without error or rejection.
   Grep check for `kargu-application-claim` across repository returned: `No results found`.
3. **Public Contract Modules & Requires**:  
   `kargu/contract.el` lines 14-17:
   ```elisp
   (require 'kargu/contract/constants)
   (require 'kargu/contract/result)
   (require 'kargu/contract/types)
   (require 'kargu/contract/assert)
   ```
   Files `file-window.el`, `history.el`, `selection.el` reside under `kargu/contract/` but are omitted from `kargu/contract.el`.
4. **Clean Module Loading Verification**:  
   Executed `kargu-module-test--load-foundation` on all 8 contract features (`kargu/contract` and all 7 submodules in `kargu/contract/*.el`). All 8 load in fresh batch Emacs sub-processes without pulling any forbidden features (`kargu/core`, `kargu/state`, `kargu/loop`, `kargu/chat`, `kargu/ui`, `kargu/tools/*`).
5. **Baseline Test Suite Performance**:  
   Executed baseline ERT batch test:
   `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
   Output: `Ran 942 tests, 942 results as expected, 0 unexpected (43.345623 sec)`.
   Adding single-active-run rejection to `kargu-application-set-active-run` in memory produced identical `942/942 passed, 0 failures` (41.454422 sec).

---

## 2. Logic Chain

1. From **Observation 1**, Wave 0 cannot pass its gate merely by listing definitions in markdown tables; it requires executable guarantees: dual-application isolation, second-run rejection, and clean contract loading without optional modules.
2. From **Observation 2**, `kargu-application-set-active-run` currently violates ARCH-01 / ARCH-12 because it overwrites an existing active run rather than rejecting a second run. Furthermore, `kargu-application-claim` and `release` do not yet exist.
3. Adding single-active-run validation to `kargu-application-set-active-run` and defining `kargu-application-claim` and `kargu-application-release` directly enforces ARCH-01 / ARCH-12. Per **Observation 5**, this causes zero regressions across the existing 942 tests because existing code correctly clears runs before starting new ones.
4. From **Observations 3 and 4**, all contract submodules are already strictly decoupled from the runtime. Adding `file-window`, `history`, and `selection` to `kargu/contract.el` completes the public contract facade without introducing any runtime or adapter dependencies.
5. By placing the fixture macro `kargu-test-with-dual-applications` in `tests/test-helpers.el`, subprocess boundary tests in `tests/test-modules.el`, and unit isolation tests in `tests/test-application-context.el`, all waves inherit a uniform, proven dual-application test harness.

---

## 3. Caveats

1. **Scope Boundaries**: As a read-only explorer, no source files were modified in place. All validations were executed in memory or sub-processes.
2. **Wave 1/A Ownership**: `kargu/application/coordinator.el` will be further extended in Wave 1/A with budget accounting and FSM transition tables. The changes recommended here are strictly limited to the Wave 0 gate contract boundary: struct definition, single-active-run enforcement, and claim/release lifecycle.
3. **No other caveats**: All conclusions are backed by direct, repeatable command executions on Linux.

---

## 4. Conclusion

The Wave 0 Acceptance Gate can be cleanly and definitively closed by applying the following concrete changes:
1. **`kargu/application/coordinator.el`**:
   - Add `session-id` and `run-id` fields to `kargu-application` struct.
   - Enforce single-active-run in `kargu-application-set-active-run` (signal error if already running and run is non-nil).
   - Add `kargu-application-claim` struct and constructor.
   - Add `kargu-application-claim` and `kargu-application-release` functions.
2. **`kargu/contract.el`**:
   - Add requires for `kargu/contract/file-window`, `kargu/contract/history`, and `kargu/contract/selection`.
3. **`tests/test-helpers.el`**:
   - Add `kargu-test-with-dual-applications` macro and `kargu-test-make-dual-applications`.
4. **`tests/test-modules.el`**:
   - Add `kargu-module-all-contracts-independent-test` and `kargu-module-dual-application-isolation-test`.
5. **`tests/test-application-context.el`**:
   - Create the new test suite containing:
     - `kargu-application-dual-instance-isolation-test`
     - `kargu-application-logical-request-isolation-test`
     - `kargu-application-single-active-run-rejected-test`
     - `kargu-application-claim-and-release-lifecycle-test`

---

## 5. Verification Method

To independently verify the implementation:
1. **Full ERT Suite Pass**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
   ```
   *Expected outcome*: 946+ tests passed (942 baseline + 4 new application context tests), 0 failures.
2. **Module Independence in Isolated Subprocess**:
   ```bash
   emacs -Q --batch -L . -L tests -l tests/test-modules.el -f ert-run-tests-batch-and-exit
   ```
   *Expected outcome*: `kargu-module-all-contracts-independent-test` and `kargu-module-dual-application-isolation-test` pass with 0 failures.
3. **Zero Byte-Compilation Warnings**:
   ```bash
   emacs -Q --batch -L . -L tests --eval "(progn (setq byte-compile-error-on-warn t) (byte-compile-file \"kargu/application/coordinator.el\") (byte-compile-file \"kargu/contract.el\") (byte-compile-file \"tests/test-helpers.el\") (byte-compile-file \"tests/test-application-context.el\"))"
   ```
   *Expected outcome*: Exits with code 0; zero warnings; clean removal of `.elc` files.
4. **Invalidation Condition**:
   If calling `(kargu-application-set-active-run "run-2" app)` when `app` already has an active run succeeds without error, or if mutations to Application A alter Application B, the gate is invalidated.
