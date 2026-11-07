## 2026-10-22T03:12:22Z
You are worker_wave2_F, working on Wave 2 Package F: Process/Job Ownership & Cancellation Lifecycle.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_F

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_F/package_F_report.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_F/handoff.md
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 5: Package F)
- /home/emrehan/.emacs.local/kargu/todo.md (RISK-01, DEEP-05, DEEP-12, DEEP-15, ARCH-17, ARCH-18)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope & Exclusive Write Allowlist:
- `kargu/tools/process.el`
- `kargu/tools/bash.el`
- `kargu/tools/bash/jobs.el`
- `kargu/tools/toolchain.el`
- New: `kargu/tools/process/session.el`
- Tests: `tests/test-process.el`, `tests/test-tools.el`, new `tests/test-job-owner.el`, `tests/test-process-stress.el`, new `tests/test-process-session.el`
- Proof: `proof/KarguProcess.tla`, `proof/ProcessMC.tla`, `proof/ProcessMC.cfg`
NEVER modify or stage skills.md, .gitignore, or .agents/. Do NOT touch files owned by Package D or Package E.

Tasks:
1. Resolve RISK-01 (Process Cancellation / Stderr Close Stress Anomaly):
   - Replace tight busy-spin `(accept-process-output proc 0.02)` with `(accept-process-output nil 0.02)` during wait loops so sentinels and other process descriptors (like stderr pipe) can execute without CPU starvation.
   - Record process group ID (`kargu-pgid`) on process handles; signal `(- pgid)` with SIGINT/SIGKILL even when `(process-live-p proc)` is `nil` so orphaned child processes are cleanly eliminated.
2. Owned Job Lifecycle (`kargu/tools/bash/jobs.el`):
   - Implement `kargu-job-service` struct encapsulating job table, monotonic counter, and active foreground process, keyed by canonical project root.
   - Maintain compatibility variables for global access.
3. Interactive Session Transport (`kargu/tools/process/session.el`):
   - Implement interactive session transport for streaming tools with bounded idle timeouts, clean stdin EOF handling, and structured kill lifecycle (DEEP-05).
4. Test Suites:
   - Add `tests/test-job-owner.el`, `tests/test-process-stress.el`, and `tests/test-process-session.el`.
5. Verification:
   - Run ERT tests: `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
   - Run byte-compilation check with `(setq byte-compile-error-on-warn t)` on all modified/new files. Confirm 0 warnings.
   - Run checkdoc on modified/new files.
   - Confirm zero `.elc` files remain.
   - Run TLC: `bash proof/run_tlc.sh --process`.
   - Confirm repository hygiene: `git status --porcelain skills.md .gitignore .agents/` is empty.
6. Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_F/worker_F_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_F/handoff.md`.
7. Send completion message to caller via send_message.
