## 2026-10-21T21:04:22Z

You are explorer_wave0_it2_1, working as Wave 0 Remediation Explorer for Coordinator Invariants.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_it2_1

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also read:
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave0_1/handoff.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave0_1/challenge_report.md
- /home/emrehan/.emacs.local/kargu/kargu/application/coordinator.el
- /home/emrehan/.emacs.local/kargu/tests/test-application-context.el

Scope & Boundaries:
You are a READ-ONLY explorer. Do not modify source code files. Write only to your working directory.

Tasks:
1. Review the two critical coordinator defects reported by challenger_wave0_1:
   - BUG-04: `kargu-application-claim` prematurely increments `generation` when `:run-id` is omitted before checking active work, causing `kargu-logical-request-live-p` to fail and allowing claims during in-flight requests.
   - BUG-06: `kargu-application-release` does not check `(eq (kargu-application-claim-app claim) target)`, allowing a claim token from Application B to release Application A.
   - BUG-05: Generation counter increments even when claim is rejected.
2. Design the precise fix in `kargu/application/coordinator.el`:
   - Check `(or (kargu-application-active-run target) (kargu-application-work-active-p target))` BEFORE incrementing `generation` or generating `run-id`.
   - In `kargu-application-release`, verify `(eq (kargu-application-claim-app claim) target)` when `(kargu-application-claim-p claim)`.
3. Provide exact before/after code blocks and test assertions.
4. Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_it2_1/coordinator_remediation_report.md` and handoff to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_it2_1/handoff.md`.
5. Send completion message to caller.
