## 2026-10-21T23:23:49Z
Sender: 246e42bd-e1b7-4f73-8026-d90704dd17ec
Priority: MESSAGE_PRIORITY_HIGH

You are explorer_wave2_F, working as Wave 2 Package F Explorer (Process/Job Ownership & Cancellation Lifecycle).
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_F

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 5: Dalga 2, Package F)
- /home/emrehan/.emacs.local/kargu/todo.md (RISK-01, DEEP-05/12/15, ARCH-17/18)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

Scope & Tasks:
1. Analyze existing process and bash execution files:
   - `kargu/tools/process.el`, `kargu/tools/bash.el`, `kargu/tools/bash/jobs.el`, `kargu/tools/toolchain.el`.
   - Tests: `tests/test-process.el`, `tests/test-tools.el`.
   - Proof: `proof/KarguProcess.tla`, `proof/ProcessMC.tla`, `proof/ProcessMC.cfg`.
2. Investigate RISK-01 (Process cancellation / stderr close stress anomaly):
   - Analyze how `interrupt-process`, child process groups, stdout/stderr drains, and `accept-process-output` interact.
   - Design an anomaly reproduction and verification harness.
3. Design owned job lifecycle:
   - Move job table, counter, and foreground process into explicit project/session service.
   - Structured process tree cancellation: graceful close, deadline, and force kill (`delete-process`).
   - Clean batch stdin EOF handling. If interactive stdin is required, evaluate `kargu/tools/process/session.el`.
4. Design new test suites: `tests/test-job-owner.el`, `tests/test-process-stress.el`.
5. Check formal model `proof/KarguProcess.tla` and TLC model checking via `proof/run_tlc.sh`.
6. Provide concrete before/after code blocks for Worker F.
7. Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_F/package_F_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_F/handoff.md`.
8. Send completion message to caller via send_message.
