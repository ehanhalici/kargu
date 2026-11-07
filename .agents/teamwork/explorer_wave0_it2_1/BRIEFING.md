# BRIEFING — 2026-10-21T21:13:30Z

## Mission
Investigate and design remediation for Coordinator invariants defects (BUG-04, BUG-05, BUG-06) in kargu/application/coordinator.el with test assertions and code blocks.

## 🔒 My Identity
- Archetype: explorer
- Roles: investigator, synthesis
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_it2_1
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Wave 0 Remediation (Coordinator Invariants)

## 🔒 Key Constraints
- Read-only investigation — do NOT implement
- Write only to /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_it2_1
- No source code or tests in .agents/teamwork/

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-21T21:13:30Z

## Investigation State
- **Explored paths**:
  - `kargu/application/coordinator.el` (functions `kargu-application-claim`, `kargu-application-release`, `kargu-application-work-active-p`)
  - `tests/test-application-context.el` (coordinator context isolation tests)
  - `tests/test-helpers.el` (`kargu-test-with-dual-applications`, `kargu-test--isolate`)
  - `challenger_wave0_1/challenge_report.md` and `handoff.md`
- **Key findings**:
  - BUG-04: `cl-incf` in `let*` of `kargu-application-claim` desynchronizes generation before `kargu-logical-request-live-p` checks in-flight requests.
  - BUG-05: Failed claims mutate coordinator generation before validation.
  - BUG-06: `kargu-application-release` fails to check `(eq (kargu-application-claim-app claim) target)`, allowing cross-application release.
- **Unexplored areas**: None for coordinator invariants scope.

## Key Decisions Made
- Defer generation increment and default `run-id` binding into the granted branch of `kargu-application-claim`.
- Add `(eq (kargu-application-claim-app claim) target)` to `kargu-application-release`.
- Formulated two dedicated ERT tests for `tests/test-application-context.el` covering BUG-04, BUG-05, and BUG-06.

## Artifact Index
- `DISPATCH.md` — Initial dispatch instructions
- `BRIEFING.md` — Situational awareness and working memory
- `progress.md` — Agent heartbeat and step tracking
- `coordinator_remediation_report.md` — Comprehensive analysis, before/after code, unified diff patch, and test specifications
- `handoff.md` — 5-component handoff report for Project Orchestrator
