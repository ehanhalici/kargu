# Review & Adversarial Critic Report: Wave 2 Package F & Full Integration

**Reviewer**: `reviewer_wave2_2` (Wave 2 Reviewer 2 — Process/Job Lifecycle & Overall ERT Integration)  
**Date**: 2026-10-22  
**Target**: Package F (`kargu/tools/process.el`, `kargu/tools/bash/jobs.el`, `kargu/tools/process/session.el`, `tests/test-job-owner.el`, `tests/test-process-stress.el`, `tests/test-process-session.el`, `tests/test-process.el`) and Repository-Wide ERT Integration (1049 tests).

---

## 1. Review Summary

**Verdict**: **APPROVE**

The implementation of Package F and its repository-wide integration fully satisfy all architectural, behavioral, and verification requirements set forth in `parallel-plan.md` and `ORIGINAL_REQUEST.md`:
1. **RISK-01 Resolution**:
   - The root cause of the test-suite deadline starvation anomaly was pinpointed to calling `(accept-process-output process 0.02)` on an already-killed process handle in `tests/test-process.el`. In Emacs's C core (`src/process.c`), `Faccept_process_output` on a non-live process returns immediately (~12μs) without calling `pselect`/`poll`. Switching to `(accept-process-output nil 0.02)` instructs Emacs to sleep on all pending file descriptors, preventing busy-spin starvation of other sentinels (e.g., stderr pipe processes).
   - In `kargu/tools/process.el`, process group signaling with negative PGID `(- pid)` ensures that child process subtrees (e.g., `(sleep 30 &) & echo $!; wait`) are cleanly terminated with `SIGINT`/`SIGKILL` on POSIX systems, preventing orphan process leaks to PID 1.
2. **Owned Job Architecture (`kargu-job-service`)**:
   - Encapsulates job tracking, monotonic counter generation, and active foreground process tracking inside a `kargu-job-service` struct keyed by canonical project root.
   - Fully preserves backwards-compatibility aliases (`kargu-bash--processes`, `kargu-bash--counter`, `kargu-bash--active-async-proc`), ensuring zero breakages across legacy callers.
   - Implements structured multi-phase cancellation (`kargu-job-cancel`) and bounded retention log pruning (`kargu-bash--prune-jobs`).
3. **Interactive Session Transport (`kargu/tools/process/session.el`)**:
   - Fulfills DEEP-05 for long-lived, interactive stdin processes without heavy PTY bloat.
   - Binds output buffer size via character truncation (`delete-region`) and enforces automatic idle timeouts via managed `run-at-time` timers, which are safely cancelled upon process termination.
4. **Independent Full-Suite Integration**:
   - All 44 Package F tests passed cleanly.
   - All 1049 ERT tests in the full repository test suite passed with 0 failures and 0 errors in 44.1 seconds.
   - Byte-compilation with `(setq byte-compile-error-on-warn t)` yielded 0 warnings and 0 errors.
   - Checkdoc yielded 0 warnings.
   - 0 `.elc` files remain.
   - Repository hygiene (`skills.md` and `.gitignore`) is pristine.
   - TLA+ TLC model checker (`proof/run_tlc.sh --process`) passed with 0 errors across 535 states.

---

## 2. Adversarial Integrity & Anti-Cheating Inspection

We subjected the code and test fixtures to an adversarial integrity audit:
- **Hardcoded test results / expected outputs**: Verified absent. Tool output is generated dynamically from live OS subprocesses (`sh`, `cat`, `sleep`, `ps`).
- **Dummy or facade implementations**: Verified absent. Structs, process filters, sentinels, process group signaling, and hash tables execute real OS and Emacs logic.
- **Shortcuts bypassing core work**: Verified absent. Process group signaling directly invokes `(signal-process (- pid) 'SIGKILL)` and handles both grace timers and dead-process fallback.
- **Fabricated verification outputs / self-certification**: Verified absent. All 44 Package F tests and all 1049 full-repo tests were executed independently by this reviewer agent in real Emacs batch subprocesses.

---

## 3. Findings & Detailed Analysis

### Finding 1 [Positive / Architectural Robustness]: RISK-01 Fix
- **Where**: `tests/test-process.el:234, 261`, `kargu/tools/process.el:126-155, 236`
- **Observation**:
  In `kargu-process-run`, `(process-put proc 'kargu-pgid (process-id proc))` records the PGID while the process is live. In `kargu-process-cancel`, POSIX negative PID signaling `(signal-process (- pid) ...)` is dispatched even if `(process-live-p process)` is already nil, ensuring any detached child processes in the same process group receive `SIGKILL`.
  In `tests/test-process.el`, substituting `(accept-process-output nil 0.02)` forces a real `pselect` pause, allowing asynchronous sentinels on stderr pipes to process incoming EOFs before the 2-second deadline expires.
- **Verdict**: Verified robust and correct.

### Finding 2 [Positive / Architectural Conformance]: Project Isolation & Compatibility
- **Where**: `kargu/tools/bash/jobs.el:23-77`
- **Observation**:
  `kargu-job-service-for-project` isolates job state per project root directory, preventing crosstalk between different workspace roots. When no project root is available, it gracefully falls back to `kargu-job--default-service`.
  Backwards compatibility synchronization (`kargu-bash--sync-service-compat`) ensures that legacy global variables (`kargu-bash--processes`, etc.) remain in sync for any callers still using them during the multi-wave migration.
- **Verdict**: Verified robust and correct.

### Finding 3 [Positive / Resource Bounding]: Interactive Session Transport
- **Where**: `kargu/tools/process/session.el:20-135`
- **Observation**:
  The `kargu-process-session` implementation properly manages:
  - Open stdin streaming with explicit `kargu-process-session-close` (EOF).
  - Memory bounds checking in the process filter:
    `(- (point-max) max-buf-bytes)` deletes oldest output to keep the live buffer within bounds.
  - Idle timer cleanup: the process sentinel explicitly cancels `idle-timer` when the process exits, preventing dangling timer references.
- **Verdict**: Verified robust and correct.

### Finding 4 [Adversarial Edge Case / Low Risk Consideration]: Windows Process Group Fallback
- **Where**: `kargu/tools/process.el:138-141`
- **Observation**:
  On `windows-nt` and `ms-dos`, negative PIDs are not supported by the OS kernel. The code explicitly checks `(memq system-type '(windows-nt ms-dos))` and invokes `(kill-process process)`. On Windows, grandchild processes spawned by cmd.exe/powershell may require OS job objects or taskkill to fully terminate.
- **Assessment**:
  The POSIX implementation is the primary target for GNU/Linux environments; the Windows fallback prevents runtime errors during cancellation. This limitation is noted in the worker's handoff caveats and is acceptable.

---

## 4. Independent Verification Results

### 1. Package F ERT Test Suite
Command:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-process) (require 'tests/test-job-owner) (require 'tests/test-process-stress) (require 'tests/test-process-session))" -f ert-run-tests-batch-and-exit
```
Result:
```
Ran 44 tests, 44 results as expected, 0 unexpected (1.541792 sec)
```

### 2. Full Repository ERT Test Suite
Command:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
```
Result:
```
Ran 1049 tests, 1049 results as expected, 0 unexpected (44.118373 sec)
```
- All 1049 tests passed with 0 failures, 0 errors, and 0 skips!

### 3. Byte-Compilation Hygiene (`byte-compile-error-on-warn t`)
Command:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (setq byte-compile-error-on-warn t) (dolist (f '(\"kargu/tools/process.el\" \"kargu/tools/bash/jobs.el\" \"kargu/tools/process/session.el\" \"tests/test-process.el\" \"tests/test-job-owner.el\" \"tests/test-process-stress.el\" \"tests/test-process-session.el\")) (message \"Compiling %s...\" f) (byte-compile-file f)) (dolist (f '(\"kargu/tools/process.elc\" \"kargu/tools/bash/jobs.elc\" \"kargu/tools/process/session.elc\" \"tests/test-process.elc\" \"tests/test-job-owner.elc\" \"tests/test-process-stress.elc\" \"tests/test-process-session.elc\")) (when (file-exists-p f) (delete-file f))))"
```
Result:
- 0 warnings, 0 errors. Exit code 0.

### 4. Checkdoc Style & Docstring Hygiene
Command:
```bash
emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'checkdoc) (dolist (f '(\"kargu/tools/process.el\" \"kargu/tools/bash/jobs.el\" \"kargu/tools/process/session.el\" \"tests/test-process.el\" \"tests/test-job-owner.el\" \"tests/test-process-stress.el\" \"tests/test-process-session.el\")) (message \"Checking %s...\" f) (checkdoc-file f)))"
```
Result:
- 0 warnings, exit code 0.

### 5. Repository Cleanup & Hygiene
- Leftover `.elc` files: 0 found (`find . -name "*.elc"` is completely empty).
- Protected files: `git status --porcelain skills.md .gitignore` is empty.
- Working tree: `.agents/teamwork/` holds only agent coordination metadata.

### 6. Formal TLA+ Model Checking
Command:
```bash
bash proof/run_tlc.sh --process
```
Result:
```
535 states generated, 179 distinct states found, 0 states left on queue.
TLC finished without error (exhaustive process-capture scan).
```

---

## 5. Conclusion

Wave 2 Package F (Process/Job Ownership & Cancellation Lifecycle) and the full repository ERT test integration have been independently verified and proven robust. The architectural changes are clean, performant, and fully backwards-compatible. All 1049 tests pass without flaw.

**Final Verdict: APPROVE**
