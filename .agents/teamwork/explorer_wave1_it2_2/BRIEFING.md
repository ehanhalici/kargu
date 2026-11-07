# BRIEFING — 2026-10-21T22:58:45Z

## Mission
Analyze downstream callers and call paths for the 26 failing ERT regression tests caused by coordinator status transitions, and recommend how coordinator.el should handle them without modifying test files or weakening safety.

## 🔒 My Identity
- Archetype: explorer
- Roles: investigator, synthesizer
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_2
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Wave 1 Remediation Downstream Callers Exploration

## 🔒 Key Constraints
- Read-only investigation — do NOT implement changes in source code
- Do not modify test files
- Do not weaken safety for Wave 1 packages
- Produce downstream_callers_report.md and handoff.md

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-21T22:46:30Z

## Investigation State
- **Explored paths**:
  - `kargu/application/coordinator.el`: `kargu-application-set-status`, `kargu-application-transition`, `kargu-application--transition-table`, `kargu-application-claim`
  - `kargu/state/store.el`, `kargu/state/transitions.el`: delegation to coordinator
  - `kargu/async.el`: `kargu-async-pending-p`, `kargu-async-start`, `kargu-async-finish`, `kargu-async-add-cleanup`
  - 26 failing test files: `tests/test-cache.el`, `tests/test-heal.el`, `tests/test-compact.el`, `tests/test-loop.el`, `tests/test-lsp-settle.el`, `tests/test-dape-execution.el`, `tests/test-dape-compile.el`, `tests/test-modules.el`
  - Wave 1 tests: `tests/test-application-context.el`, `tests/test-wave1-empirical-challenge.el`
- **Key findings**:
  - 23 tests fail due to `kargu-application-set-status` strictly enforcing `kargu-application-transition` on unclaimed default coordinators. Downstream tests do not invoke `kargu-application-claim`.
  - 3 tests fail due to `kargu-async-pending-p` using `equal` instead of `eq` on `kargu--loop-run` and using `"run-"` prefix heuristic fallback.
  - Recommended remedy: Make `kargu-application-set-status` validate transitions via `kargu-application-transition` only when an explicit `app` is provided or `(kargu-application-active-claim-token target)` is non-nil; otherwise directly record status on the unclaimed default singleton. In `kargu/async.el`, restore `(consp owner) (eq owner kargu--loop-run)`.
- **Unexplored areas**: None; all 26 test failures investigated, categorized, traced, and verified.

## Key Decisions Made
- Confirmed that zero of the 26 failing tests call `kargu-application-claim`.
- Verified empirically that dual remedy allows 100% of downstream tests and Wave 1 challenge tests to pass simultaneously.

## Artifact Index
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_2/DISPATCH.md — Dispatch log
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_2/BRIEFING.md — Persistent context
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_2/progress.md — Liveness heartbeat
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_2/downstream_callers_report.md — Detailed audit report
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave1_it2_2/handoff.md — 5-component handoff report
