## 2026-10-22T03:56:35Z
You are reviewer_wave2_2, working as Wave 2 Reviewer 2 (focus: Package F Process/Job Lifecycle & Overall ERT Integration).
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/reviewer_wave2_2

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 5: Dalga 2, Package F & Integration)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_F/handoff.md
- All changes across Wave 2 in `kargu/tools/process.el`, `kargu/tools/bash/jobs.el`, `kargu/tools/process/session.el`, `tests/test-job-owner.el`, `tests/test-process-stress.el`, `tests/test-process-session.el`, `tests/test-process.el`

Scope & Tasks:
1. Review implementation correctness and robustness for Package F and full repo integration:
   - Verify RISK-01 fix: `(accept-process-output nil 0.02)` during wait loops prevents CPU busy-spin starvation of other sentinels; negative PGID signaling `(- pgid)` kills child process trees and prevents orphan processes.
   - Verify `kargu-job-service` struct isolates jobs per project root while maintaining backwards compatibility variables.
   - Verify interactive session transport in `kargu/tools/process/session.el` with bounded memory and idle timeout.
2. Run independent test and verification commands:
   - Run Package F ERT tests (44 tests):
     `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-process) (require 'tests/test-job-owner) (require 'tests/test-process-stress) (require 'tests/test-process-session))" -f ert-run-tests-batch-and-exit`
   - Run the FULL repository ERT test suite from ORIGINAL_REQUEST:
     `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
     Confirm that ALL 1049 tests pass with 0 failures and 0 errors!
   - Byte-compile with `(setq byte-compile-error-on-warn t)` on modified/new files: 0 warnings.
   - Checkdoc on modified/new files: 0 warnings.
   - Confirm zero `.elc` files remain.
   - Confirm repository hygiene: `git status --porcelain skills.md .gitignore .agents/` is empty outside `.agents/teamwork/`.
3. Deliver your verdict: APPROVE or REQUEST_CHANGES.
4. Write your review report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/reviewer_wave2_2/review_report.md` and handoff with verdict to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/reviewer_wave2_2/handoff.md`.
5. Send completion message to caller via send_message with your verdict and paths.
