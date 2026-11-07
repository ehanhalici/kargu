# Progress — Wave 1 Package A

**Last visited:** 2026-10-21T22:20:00Z
**Current status:** Implementation, tests, formal verification, and quality gates complete. Writing final reports.

## Tasks
- [x] 0. Run baseline test suite and inspect current files
- [x] 1. Application Coordinator Context (`kargu/application/coordinator.el`, `kargu/application/mode.el`, `kargu/state/`, etc.)
- [x] 2. Async Scope & Reset (`kargu/async.el`, `kargu/application/reset.el`, `kargu/core/session.el`)
- [x] 3. Budget Core (`kargu/application/budget.el`)
- [x] 4. Test Suite (`tests/test-run-budget.el`, `tests/test-application-context.el`, etc.)
- [x] 5. Formal Verification (`proof/KarguBudget.tla`, `proof/BudgetMC.tla`, `proof/BudgetMC.cfg`)
- [x] 6. Verification (ERT, byte-compile, checkdoc, TLC, .elc cleanup)
- [x] 7. Reports and Handoff (`worker_A_report.md`, `handoff.md`)
