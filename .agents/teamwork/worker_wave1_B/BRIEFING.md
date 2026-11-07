# BRIEFING — 2026-10-21T22:27:00Z

## Mission
Implement Wave 1 Package B: Single-Owner Edit Service and Approval Identity across kargu/edit.el and kargu/tools/diff/*.

## 🔒 My Identity
- Archetype: worker
- Roles: implementer, qa, specialist
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_B
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: wave1_package_B

## 🔒 Key Constraints
- Scope & Exclusive Write Allowlist:
  - kargu/edit.el
  - kargu/tools/diff.el
  - kargu/tools/diff/stage.el
  - kargu/tools/diff/review.el
  - kargu/tools/diff/track.el
  - New: kargu/tools/diff/context.el
  - Tests: tests/test-patch.el, tests/test-edit-transaction.el, new tests/test-edit-service.el
  - Proof: proof/KarguEdit.tla, proof/EditMC.tla, proof/EditMC.cfg
  - Register tests/test-edit-service in tests/run-tests.el.
- NEVER modify or stage skills.md, .gitignore, or .agents/.
- Do NOT touch files owned by Package A or C.
- DO NOT CHEAT: Genuine logic only, no hardcoded expected values, real state and behavior.
- Clean up any .elc files before completion.
- Byte-compile with `byte-compile-error-on-warn t` must pass with 0 warnings.
- Checkdoc 0 warnings on modified/new files.
- Run ERT tests and TLC model check.

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: not yet

## Task Summary
- **What to build**: Single-Owner Edit Service with isolated context struct, frozen approval token, unified outcome structure, Git safety (never touch user index, isolated git work area, async git apply), resource cleanup, full test suite and TLA+ model proof updates.
- **Success criteria**:
  - `kargu/tools/diff/context.el` created with `kargu-edit-service` struct.
  - Frozen approval policy verifying document revision and session/run identity.
  - Unified outcome structure handling save hooks, write effects, rollback.
  - Tests passing: test-patch, test-edit-transaction, test-edit-service.
  - TLC model check passing.
  - Byte-compile & checkdoc clean.
- **Interface contracts**: /home/emrehan/.emacs.local/kargu/architecture-contracts.md
- **Code layout**: /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

## Key Decisions Made
- `kargu-edit-service` owns isolated snapshots, changes, reviews, active plans, and owned resources (buffers, processes, timers, temp dirs).
- `kargu-diff--service-snapshots`, `kargu-diff--service-changes`, and `kargu-diff--service-reviews` prioritize explicit `service` arguments and `kargu-diff--active-service`, while keeping the default service dynamically synced with test harness let-bindings (`kargu-diff--snapshots`, etc.).
- `kargu-diff-submit-plan` provides unified execution of block, symbol, and Unified Diff plans, re-verifying policy revision, session ID, and document disk revision before apply.
- TLA+ model `proof/KarguEdit.tla` extended with `policyStale` and `serviceClosed` transitions and invariants `Safety_PolicyInvalidatedNoWrite` and `Safety_ClosedServiceNoOwnedWrites`.

## Artifact Index
- DISPATCH.md — assignment record
- BRIEFING.md — working memory and identity
- progress.md — liveness heartbeat
- worker_B_report.md — detailed deliverable report
- handoff.md — self-contained handoff report

## Change Tracker
- **Files modified**:
  - `kargu/tools/diff/context.el` (new): single-owner edit service context, plans, outcomes, resource cleanup, plan submission.
  - `kargu/edit.el`: fallback `kargu-edit-submit-plan` returning `:unavailable`.
  - `kargu/tools/diff.el`: patch workspace registration, async process tracking, advice setup and unload check.
  - `kargu/tools/diff/stage.el`: service-aware origin validation, buffer registration, commit recording.
  - `kargu/tools/diff/review.el`: service-aware review sessions and cleanup timer registration.
  - `kargu/tools/diff/track.el`: service-aware snapshot and rollback tracking.
  - `tests/test-edit-service.el` (new): 12 comprehensive unit and integration tests.
  - `tests/run-tests.el`: registered `test-edit-service`.
  - `proof/KarguEdit.tla`, `proof/EditMC.cfg`: formal verification of policy revision and service close invariants.
- **Build status**: PASS (0 byte-compile warnings with byte-compile-error-on-warn, 0 checkdoc warnings, 0 .elc files)
- **Pending issues**: none

## Quality Status
- **Build/test result**: PASS (12/12 test-edit-service, 41/41 edit/patch tests, TLC model check 100% PASS)
- **Lint status**: PASS (0 checkdoc warnings across all 7 modified/new files)
- **Tests added/modified**: `tests/test-edit-service.el` (12 tests)

## Loaded Skills
- None
