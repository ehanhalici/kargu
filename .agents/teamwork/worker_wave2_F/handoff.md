# Handoff Report: Wave 2 Package F (Process/Job Ownership & Cancellation Lifecycle)

## 1. Observation

1. **RISK-01 Reproduction & Root Cause Identification**:
   - In `tests/test-process.el`, lines 228 and 255: `(accept-process-output process 0.02)` was called on process handles that were already killed by `kargu-process-cancel`. In Emacs C source (`src/process.c`), `Faccept_process_output` on a dead process returns immediately (~12 microseconds) without sleeping in `pselect`/`poll`. In a tight loop, it executed ~75,500 iterations in 0.5s, starving asynchronous sentinels on other file descriptors (like the stderr pipe process sentinel).
   - In `kargu/tools/process.el`, `kargu-process-cancel` only called `(when (process-live-p process) (kill-process process))`. When a shell script spawned a background child `(sleep 30 &) & echo $!; wait` and exited, `(process-live-p process)` was `nil`, skipping cancellation entirely and leaking the orphan child process to PID 1.

2. **Job Management Refactoring**:
   - Refactored `kargu/tools/bash/jobs.el` to introduce `kargu-job-service` struct encapsulating job table, monotonic counter, and active foreground process, keyed by canonical project root (`(kargu-job-service-for-project)`).
   - Preserved backwards compatibility bridge variables `kargu-bash--processes`, `kargu-bash--counter`, and `kargu-bash--active-async-proc`.
   - Implemented structured multi-phase cancellation `(kargu-job-cancel job &optional grace-seconds)`.
   - Implemented bounded retention pruning in `(kargu-bash--prune-jobs &optional service)`.

3. **Interactive Session Transport (DEEP-05)**:
   - Implemented `kargu/tools/process/session.el` with `kargu-process-session` struct, `kargu-process-session-start`, `kargu-process-session-send`, `kargu-process-session-close`, and `kargu-process-session-kill`.
   - Automatically bounds buffer memory via `(delete-region (point-min) (- (point-max) max-buf-bytes))` and enforces idle timeout.

4. **Test Suite Results**:
   - Added `tests/test-job-owner.el` (6 tests).
   - Added `tests/test-process-stress.el` (4 tests).
   - Added `tests/test-process-session.el` (5 tests).
   - Updated `tests/test-process.el` (29 tests).
   - Ran `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-process) (require 'tests/test-job-owner) (require 'tests/test-process-stress) (require 'tests/test-process-session))" -f ert-run-tests-batch-and-exit`:
     `Ran 44 tests, 44 results as expected, 0 unexpected (1.65 sec)`

5. **Byte-Compilation, Lint & Model Checking**:
   - Byte-compiled all modified/new files with `(setq byte-compile-error-on-warn t)`: 0 warnings, 0 errors.
   - Run checkdoc on all modified/new files: 0 warnings.
   - Checked for leftover `.elc` files: 0 found.
   - Ran `bash proof/run_tlc.sh --process`: Model checking completed with 0 errors (535 states generated, 179 distinct states found).
   - Checked `git status --porcelain skills.md .gitignore`: clean and untouched.

## 2. Logic Chain

1. **From Observation 1 to RISK-01 Resolution**:
   - Calling `(accept-process-output nil 0.02)` instead of passing the dead process handle forces Emacs to poll all file descriptors and sleep in `pselect`, allowing stderr sentinels to execute without CPU starvation.
   - Storing `kargu-pgid` as `(process-id proc)` at launch and signaling `(- pgid)` with `SIGINT`/`SIGKILL` in `kargu-process-cancel` terminates the entire process tree on POSIX systems even after the main process handle is no longer live, eliminating orphan process leaks.

2. **From Observation 2 to Owned Job Architecture (ARCH-17, ARCH-18)**:
   - Grouping jobs by canonical project root ensures that Project A cannot inspect, view, or cancel jobs belonging to Project B.
   - Synchronizing compatibility variables on every change ensures zero breakage for existing interactive commands or test fixtures.

3. **From Observation 3 to Interactive Session Transport (DEEP-05)**:
   - While batch tools (`rg`, `git`, `diff`) require immediate stdin EOF, interactive streaming tools need open stdin with explicit EOF, idle timeout watchers, and clean kill lifecycle without heavy PTY bloat. `session.el` fulfills this contract.

4. **From Observation 4 and 5 to Completeness**:
   - All 44 tests pass cleanly, formal verification confirms resource safety, and zero byte-compile or checkdoc warnings remain.

## 3. Caveats

- On non-POSIX systems (`windows-nt` and `ms-dos`), negative-PID process group signaling is unsupported by the OS kernel. `kargu-process-cancel` falls back to standard `kill-process` for the main process.
- No files outside our exclusive allowlist were touched. `skills.md` and `.gitignore` were strictly protected.

## 4. Conclusion

Wave 2 Package F is complete. RISK-01 is empirically and architecturally resolved. The owned job service and interactive process session transport are fully implemented and verified with 44 passing ERT tests, 100% clean checkdoc and byte-compilation, and formal TLA+ proof verification.

## 5. Verification Method

1. **Package F ERT Test Suite**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-process) (require 'tests/test-job-owner) (require 'tests/test-process-stress) (require 'tests/test-process-session))" -f ert-run-tests-batch-and-exit
   ```
   *Expected result*: 44/44 tests pass with 0 failures, 0 unexpected.

2. **Byte-Compilation Hygiene**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (setq byte-compile-error-on-warn t) (dolist (f '(\"kargu/tools/process.el\" \"kargu/tools/bash/jobs.el\" \"kargu/tools/process/session.el\" \"tests/test-process.el\" \"tests/test-job-owner.el\" \"tests/test-process-stress.el\" \"tests/test-process-session.el\")) (byte-compile-file f)) (dolist (f '(\"kargu/tools/process.elc\" \"kargu/tools/bash/jobs.elc\" \"kargu/tools/process/session.elc\" \"tests/test-process.elc\" \"tests/test-job-owner.elc\" \"tests/test-process-stress.elc\" \"tests/test-process-session.elc\")) (when (file-exists-p f) (delete-file f))))"
   ```
   *Expected result*: 0 warnings, 0 errors, exit code 0.

3. **Checkdoc Lint**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'checkdoc) (dolist (f '(\"kargu/tools/process.el\" \"kargu/tools/bash/jobs.el\" \"kargu/tools/process/session.el\" \"tests/test-process.el\" \"tests/test-job-owner.el\" \"tests/test-process-stress.el\" \"tests/test-process-session.el\")) (checkdoc-file f)))"
   ```
   *Expected result*: 0 warnings, exit code 0.

4. **Zero Leftover `.elc` Files**:
   ```bash
   find . -name "*.elc"
   ```
   *Expected result*: Empty output.

5. **Formal Model Checking**:
   ```bash
   bash proof/run_tlc.sh --process
   ```
   *Expected result*: 535 states generated, 179 distinct states found, 0 errors.

6. **Repository Hygiene**:
   ```bash
   git status --porcelain skills.md .gitignore
   ```
   *Expected result*: Empty output.
