## 2026-10-21T21:56:44Z
You are worker_wave1_A, working on Wave 1 Package A: Application/Coordinator/Budget/Async Ownership.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_A

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 4: Package A)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Application, Async scope, Budget contracts)
- /home/emrehan/.emacs.local/kargu/todo.md (ARCH-01, ARCH-11, ARCH-12, ARCH-16, ARCH-17, MOD-05, MOD-07, DEEP-09)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope & Exclusive Write Allowlist:
- kargu/application/coordinator.el
- kargu/application/mode.el
- kargu/application/reset.el
- kargu/core/session.el
- kargu/async.el
- kargu/state.el
- kargu/state/store.el
- kargu/state/selectors.el
- kargu/state/transitions.el
- kargu/state/hooks.el
- New: kargu/application/budget.el
- Tests: tests/test-state.el, tests/test-async.el, tests/test-mode-ownership.el, tests/test-application-context.el, new tests/test-run-budget.el
- Proof: proof/KarguMode.tla, proof/ModeMC.tla, proof/ModeMC.cfg, new proof/KarguBudget.tla, proof/BudgetMC.tla, proof/BudgetMC.cfg
- Register tests/test-run-budget in tests/run-tests.el (Coordinator coordination allows Wave 1 workers to register own test in run-tests.el).
NEVER modify or stage skills.md, .gitignore, or .agents/. Do NOT touch files owned by Package B or C.

Tasks:
1. Application Coordinator Context: Ensure explicit `kargu-application` handle with claim/transition/release, status transition table, and generation tracking. Do not wrap into another mutable global engine.
2. Async Scope & Reset: Explicit owner/parent/task in async scope. Reset ordering: clear application claim/run without clearing foreign runs, requests, or session state.
3. Budget Core: Implement `kargu/application/budget.el` with pure budget record and debit/consume API tracking request counts, deadlines, and token usage.
4. Test Suite: Add `tests/test-run-budget.el` testing budget debiting, deadline enforcement, multi-request accounting, and update existing tests.
5. Formal Model: Create `proof/KarguBudget.tla`, `proof/BudgetMC.tla`, `proof/BudgetMC.cfg`, update `proof/run_tlc.sh` if needed, and verify TLC model checking passes.
6. Verification:
   - Run ERT tests: `emacs -Q --batch -L . -l kargu -l tests/test-helpers.el -f ert-run-tests-batch-and-exit`
   - Byte-compilation with `(setq byte-compile-error-on-warn t)`: 0 warnings.
   - Checkdoc: 0 warnings on modified/new files.
   - Zero `.elc` files left in repo.
   - TLC model checks pass without errors.
7. Write detailed report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_A/worker_A_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_A/handoff.md`.
8. Send completion message to caller.
