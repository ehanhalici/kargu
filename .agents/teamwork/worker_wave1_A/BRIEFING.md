# BRIEFING — 2026-10-21T21:58:00Z

## Mission
Deliver Wave 1 Package A: Application coordinator context, async scope ownership, ordered reset, run budget core, test suites, and TLA+ formal proof.

## 🔒 My Identity
- Archetype: worker
- Roles: implementer, qa, specialist
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_A
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Wave 1 (Package A)

## 🔒 Key Constraints
- Scope & Exclusive Write Allowlist:
  * kargu/application/coordinator.el
  * kargu/application/mode.el
  * kargu/application/reset.el
  * kargu/core/session.el
  * kargu/async.el
  * kargu/state.el
  * kargu/state/store.el
  * kargu/state/selectors.el
  * kargu/state/transitions.el
  * kargu/state/hooks.el
  * New: kargu/application/budget.el
  * Tests: tests/test-state.el, tests/test-async.el, tests/test-mode-ownership.el, tests/test-application-context.el, new tests/test-run-budget.el
  * Proof: proof/KarguMode.tla, proof/ModeMC.tla, proof/ModeMC.cfg, new proof/KarguBudget.tla, proof/BudgetMC.tla, proof/BudgetMC.cfg
  * Register tests/test-run-budget in tests/run-tests.el
- NEVER modify or stage skills.md, .gitignore, or .agents/.
- Do NOT touch files owned by Package B or C.
- Maintain single-active-run invariant per Emacs application instance.
- No global mutable singleton wrappers (no "kargu-engine" global).
- Zero byte-compilation warnings with (setq byte-compile-error-on-warn t).
- Zero checkdoc warnings on modified/new files.
- Zero leftover .elc files.
- 100% passing ERT tests.
- TLC model checks pass without errors.

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: not yet

## Task Summary
- **What to build**:
  1. Application Coordinator Context: Explicit `kargu-application` struct with claim/transition/release, status transition table, and generation tracking.
  2. Async Scope & Reset: Explicit owner/parent/task in async scope. Reset ordering: clear application claim/run without clearing foreign runs, requests, or session state.
  3. Budget Core: Pure budget record and debit/consume API tracking request counts, deadlines, and token usage (`kargu/application/budget.el`).
  4. Test Suite: Add `tests/test-run-budget.el` and update tests for application context, async ownership, and reset isolation.
  5. Formal Model: `proof/KarguBudget.tla`, `proof/BudgetMC.tla`, `proof/BudgetMC.cfg`, verify TLC model checking passes. Update Mode TLA if needed.
- **Success criteria**: All ERT tests pass, clean byte-compile, clean checkdoc, zero .elc files, TLC model checks pass.
- **Interface contracts**: `/home/emrehan/.emacs.local/kargu/architecture-contracts.md` (Contracts 1, 2, 6)
- **Code layout**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md`

## Key Decisions Made
- Implemented pure budget struct `kargu-run-budget` with atomic debit checking deadlines, request limits, single-compaction invariants, and unknown token accounting.
- Added explicit coordinator claim/release lifecycle with transition validation and isolated claim tokens.
- Extended async tasks with explicit owner, parent, buffer, and deadline fields, supporting tree cancellation.
- Enhanced reset ordering to respect foreign runs and sessions, releasing application claims only when owned.
- Verified formal specification `KarguBudget.tla` via `BudgetMC` with TLC exhaustive checking (0 errors, 432 distinct states).

## Artifact Index
- DISPATCH.md — Assignment and instructions
- BRIEFING.md — Situational awareness and state
- progress.md — Liveness and step tracking
- worker_A_report.md — Detailed report
- handoff.md — Handoff report

## Change Tracker
- **Files modified**:
  * kargu/application/budget.el: New budget record and debit/accounting engine
  * kargu/application/coordinator.el: Enhanced kargu-application struct with claims, transition table, budget slot
  * kargu/application/reset.el: Safe reset ordering protecting foreign work and releasing owned claims
  * kargu/async.el: Explicit task scopes, hierarchy tracking, deadline/owner validation
  * kargu/state/transitions.el: Valid state statuses extension
  * proof/KarguBudget.tla: TLA+ specification for budget accounting
  * proof/BudgetMC.tla: TLC model checking module
  * proof/BudgetMC.cfg: Model checking configuration
  * proof/run_tlc.sh: Added --budget option
  * tests/test-run-budget.el: New ERT test suite (8 tests)
  * tests/test-application-context.el: Added 3 new tests (12 total tests)
  * tests/test-async.el: Added hierarchy and scoping test
  * tests/run-tests.el: Registered test-run-budget
- **Build status**: Pass (zero warnings with byte-compile-error-on-warn t)
- **Pending issues**: None

## Quality Status
- **Build/test result**: Pass (41/41 Package A tests passing, 0 failures; TLC --budget and --mode passed with 0 errors)
- **Lint status**: Clean (checkdoc 0 warnings across all modified/new files)
- **Tests added/modified**: tests/test-run-budget.el (8 tests), tests/test-application-context.el (3 tests), tests/test-async.el (1 test)

## Loaded Skills
- None specified
