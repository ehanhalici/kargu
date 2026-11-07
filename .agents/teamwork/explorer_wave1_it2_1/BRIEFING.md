# BRIEFING — 2026-10-21T23:03:00Z

## Mission
Investigate ERT regression failures caused by `kargu-application-set-status` and `kargu-application--transition-table` in `kargu/application/coordinator.el`, and formulate a precise remediation strategy for Wave 1 iteration 2.

## 🔒 My Identity
- Archetype: explorer
- Roles: Wave 1 Remediation Coordinator Transition Explorer
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_1
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: wave1_it2

## 🔒 Key Constraints
- Read-only investigation — do NOT implement directly in source files
- Must read full unfiltered audit report in `auditor_wave1_1/audit_report.md` and `ORIGINAL_REQUEST.md`
- Preserve strict state machine integrity for owned runs (`kargu-application-claim`)
- Ensure all 41 Package A tests, 41 Package B tests, 41 Package C tests, and 9 empirical challenge tests pass without regression
- Accommodate unmigrated downstream modules until Wave 3

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-21T23:03:00Z

## Investigation State
- **Explored paths**:
  - `kargu/application/coordinator.el` (transition table, transition validation, status accessors, run accessors)
  - `kargu/state/store.el` & `kargu/state/transitions.el` (delegation chain)
  - `kargu/async.el` (`kargu-async-pending-p` owner matching)
  - Failing test suites: `tests/test-cache.el`, `tests/test-heal.el`, `tests/test-loop.el`, `tests/test-dape-execution.el`, `tests/test-dape-compile.el`, `tests/test-lsp-settle.el`, `tests/test-modules.el`
  - Formal models: `proof/BudgetMC.tla`, `proof/ConnectionMC.tla`, `proof/EditMC.tla`
  - Empirical challenge runner: `tests/test-wave1-empirical-challenge.el`
- **Key findings**:
  - Primary Root Cause (23 failures): `kargu-application--transition-table` rejected lifecycle transitions used by unmigrated Wave 3 modules (`:idle -> :executing-tools, :verifying, :compacting, :stopped, :pause`, `:pause -> :waiting-model, :stopped, :error`, `:stopped -> :error, :requesting`, `:error -> :requesting, :waiting-model`, `:verifying -> :executing-tools`).
  - Secondary Root Cause (3 failures): `kargu-async-pending-p` in `kargu/async.el` used `(t (not (string-prefix-p "run-" (format "%s" owner))))` and `equal` instead of `eq`, misinterpreting replaced run objects as indefinitely live.
- **Unexplored areas**: None. Complete evidence chain established.

## Key Decisions Made
- Remediation strategy is two-fold:
  1. Expand `kargu-application--transition-table` with transitional statuses while keeping invalid transitions like `:idle -> :streaming` and `:idle -> :executing-tool` strictly forbidden.
  2. In `kargu-application-transition`, allow valid lifecycle statuses for the default unowned singleton without compromising owned runs (`kargu-application-claim`).
  3. Correct `kargu-async-pending-p` in `kargu/async.el` to use `eq` for `kargu--loop-run` and restrict `equal` to string run-ids.

## Artifact Index
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_1/DISPATCH.md` — Inbound instructions log
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_1/progress.md` — Liveness heartbeat and progress tracking
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_1/coordinator_transition_remediation_report.md` — Detailed remediation report
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_1/handoff.md` — Handoff report
