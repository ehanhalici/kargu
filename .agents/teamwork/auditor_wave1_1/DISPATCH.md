## 2026-10-21T22:33:48Z

You are auditor_wave1_1, working as Wave 1 Forensic Auditor.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/auditor_wave1_1

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 4: Wave 1 Packages A, B, C)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md
- All git changes introduced across Wave 1 in:
  - Package A: `kargu/application/budget.el`, `kargu/application/coordinator.el`, `kargu/application/reset.el`, `kargu/async.el`, `kargu/state/transitions.el`, `tests/test-run-budget.el`, `tests/test-application-context.el`, `tests/test-async.el`, `proof/KarguBudget.tla`, `proof/BudgetMC.tla`, `proof/BudgetMC.cfg`
  - Package B: `kargu/tools/diff/context.el`, `kargu/edit.el`, `kargu/tools/diff.el`, `kargu/tools/diff/stage.el`, `kargu/tools/diff/review.el`, `kargu/tools/diff/track.el`, `tests/test-edit-service.el`, `proof/KarguEdit.tla`, `proof/EditMC.cfg`
  - Package C: `kargu/config/worker.el`, `kargu/config/connection.el`, `kargu/config/schema.el`, `kargu/config/key.el`, `kargu/config.el`, `tests/test-connection-snapshot.el`, `proof/KarguConnection.tla`, `proof/ConnectionMC.tla`, `proof/ConnectionMC.cfg`
  - Common: `tests/run-tests.el`, `proof/run_tlc.sh`

Scope & Tasks:
1. Forensic integrity verification:
   - Verify that all implementations across Packages A, B, and C are GENUINE:
     - NO hardcoded return values matching test inputs/names
     - NO mock or dummy facades producing fake success without genuine business logic
     - NO weakened test assertions or skipped assertions
     - NO mock bypasses that circumvent real validation
   - Verify that `kargu-run-budget` contains genuine arithmetic, deadline checks, and single-compaction tracking.
   - Verify that `kargu-edit-service` genuinely scopes tables and performs real validation against document/policy revisions.
   - Verify that `kargu/config/worker.el` genuinely executes subprocesses and never leaks secrets in argv.
   - Verify that repository governance invariants hold:
     - `skills.md`, `.gitignore`, and `.agents/` outside `.agents/teamwork/` are completely UNTOUCHED and UNSTAGED.
     - ZERO `.elc` files exist in the repository tree.
2. Deliver your binary verdict: CLEAN or INTEGRITY VIOLATION.
3. Write your detailed forensic audit report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/auditor_wave1_1/audit_report.md` and handoff with verdict to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/auditor_wave1_1/handoff.md`.
4. Send completion message to caller via send_message.
