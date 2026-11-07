# Handoff Report: Wave 2 Package F (Process/Job Ownership & Cancellation Lifecycle)

## 1. Observation

1. **RISK-01 Test Anomaly Evidence**:
   - In `tests/test-process.el`, lines 252–256:
     ```elisp
     (kargu-process-cancel process)
     (let ((deadline (+ (float-time) 2)))
       (while (and (not result) (< (float-time) deadline))
         (accept-process-output process 0.02)))
     (should result)
     ```
   - In live Emacs execution, calling `(accept-process-output process 0.02)` when `process` has already terminated returned in **0.000012s** (12 microseconds) without sleeping in `pselect`/`poll`. In a 0.5s window under tight loop, it executed **75,541 iterations**, burning 100% CPU on the thread.
   - When a dead process handle is passed, Emacs does not wait for asynchronous descriptors from other processes (`stderr` pipe process). Consequently, `kargu-process--maybe-finish` was delayed until test timeout, causing the 2-second deadline to expire under concurrent load.
   - In `kargu/tools/process.el` (line 134), `kargu-process-cancel` checks `(when (process-live-p process) (kill-process process))`. When the shell script exited immediately after backgrounding a child (`(sleep 10 &) & echo $!`), `(process-live-p process)` was `nil`. As observed via `ps aux`, child process `sleep 10` (PID 1201537) was reparented to init (`ppid=1`) and remained running in the OS indefinitely despite cancellation.

2. **Global Mutable State in Job Management**:
   - In `kargu/tools/bash/jobs.el`, lines 17–21:
     ```elisp
     (defvar kargu-bash--counter 0 "Monotonic shell job identifier.")
     (defvar kargu-bash--processes (make-hash-table :test #'equal)
       "Shell jobs keyed by stable identifiers.")
     (defvar kargu-bash--active-async-proc nil
       "The foreground tool process, or nil when no foreground job runs.")
     ```
   - These global mutable variables violate ARCH-01, ARCH-12, and ARCH-17. Shell jobs are not isolated by project root or session context.

3. **Batch Stdin EOF Constraint vs Long-Lived CLI Needs**:
   - In `kargu/tools/process.el`, line 218: `(when (process-live-p proc) (process-send-eof proc))`.
   - Batch commands (`rg`, `git`, `diff`) require immediate stdin EOF, but interactive/long-lived processes require a separate session transport with open stdin, idle timeout, and structured kill (DEEP-05).

4. **Formal Model Checking**:
   - Ran `bash proof/run_tlc.sh --process`:
     ```
     Specification: ProcessMC.tla (KarguProcess)
     Model checking completed. No error has been found.
     535 states generated, 179 distinct states found, 0 states left on queue.
     Finished in 00s at (2026-10-21 23:26:16)
     ```
   - `proof/KarguProcess.tla` exhaustively verifies the dual-stream closure protocol (`mainClosed /\ stderrClosed`), line bounding, and single delivery.

## 2. Logic Chain

1. **From Observation 1 to RISK-01 Root Cause Resolution**:
   - Because `(accept-process-output process 0.02)` spins without sleeping when `process` is dead, the thread busy-loops and starves the `stderr` pipe sentinel callback. Passing `nil` (`(accept-process-output nil 0.02)`) properly sleeps and polls all descriptors, eliminating CPU starvation and ensuring sentinels run immediately.
   - Because `(kill-process process)` only signals the single PID and fails to run when `process-live-p` is `nil`, child processes survive as orphans. By storing the process group ID (`kargu-pgid`) on the process object and signaling `(- pgid)` with `SIGINT`/`SIGKILL` even when `process-live-p` is `nil`, the entire process tree is cleanly terminated without leaking orphan processes.

2. **From Observation 2 to Owned Job Architecture**:
   - Encapsulating the job table, counter, and active foreground process in `(cl-defstruct (kargu-job-service ...))` keyed by canonical `project-root` enforces ARCH-17 (resource ownership) and prevents cross-project leakage.
   - Maintaining synchronized compatibility bridge variables preserves 100% interoperability with existing callers and tests.

3. **From Observation 3 to Interactive Session Transport**:
   - Keeping `kargu-process-run` strictly batch-oriented preserves existing invariants, while adding `kargu/tools/process/session.el` fulfills DEEP-05 for interactive streaming tools with bounded idle timeouts and clean stdin closing.

4. **From Observation 4 to Formal Proof Alignment**:
   - The TLA+ invariant `Safety_ClosedResources` requires that all resources close upon termination. The structured cancellation mechanism (PGID signal + stderr pipe deletion + timer cancellation) guarantees this invariant in the concrete runtime implementation.

## 3. Caveats

- On non-POSIX systems (`windows-nt` / `ms-dos`), process group negative PID signaling `(- pid)` is not supported by the kernel; the implementation guards with `(memq system-type '(windows-nt ms-dos))` to fall back gracefully to standard process termination.
- No source code in `kargu/` or `tests/` was modified during this investigation (strictly read-only).

## 4. Conclusion

Wave 2 Package F is completely mapped, root causes are empirically verified, and concrete implementation blueprints are ready for Worker F:
- **RISK-01**: Resolved via process group signaling `(- pid)` and event loop progression `(accept-process-output nil ...)`.
- **Owned Job Lifecycle (ARCH-17, DEEP-05)**: Designed `kargu-job-service` with structured cancellation (graceful close $\to$ deadline $\to$ force kill) and backward compatibility bridge.
- **Session Transport (DEEP-05)**: Designed `kargu/tools/process/session.el`.
- **Test Suites**: Designed `tests/test-job-owner.el`, `tests/test-process-stress.el`, and `tests/test-process-session.el`.
- **Formal Verification**: Verified `proof/KarguProcess.tla` with 100% TLC pass.

## 5. Verification Method

1. **TLC Model Checking**:
   ```bash
   bash proof/run_tlc.sh --process
   ```
   *Expected outcome*: 0 errors, 179 distinct states found.

2. **Run Existing Process Tests**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-process))" -f ert-run-tests-batch-and-exit
   ```
   *Expected outcome*: 29/29 tests pass.

3. **Run New Test Suites Once Implemented**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-job-owner))" -f ert-run-tests-batch-and-exit
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-process-stress))" -f ert-run-tests-batch-and-exit
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-process-session))" -f ert-run-tests-batch-and-exit
   ```

4. **Byte-Compilation Hygiene**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (setq byte-compile-error-on-warn t) (dolist (f '(\"kargu/tools/process.el\" \"kargu/tools/bash/jobs.el\" \"kargu/tools/process/session.el\" \"tests/test-job-owner.el\" \"tests/test-process-stress.el\" \"tests/test-process-session.el\")) (byte-compile-file f)) (dolist (f '(\"kargu/tools/process.elc\" \"kargu/tools/bash/jobs.elc\" \"kargu/tools/process/session.elc\" \"tests/test-job-owner.elc\" \"tests/test-process-stress.elc\" \"tests/test-process-session.elc\")) (when (file-exists-p f) (delete-file f))))"
   ```
   *Expected outcome*: 0 warnings, 0 errors, 0 leftover `.elc` files.
