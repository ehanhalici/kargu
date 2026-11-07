# BRIEFING — 2026-10-21T21:57:00Z

## Mission
Execute end-to-end multi-wave parallel architecture transformation and verification of Kargu (Waves 0–5) per parallel-plan.md with 100% test pass rate, clean compilation, TLC model checking, and full architectural integrity.

## 🔒 My Identity
- Archetype: teamwork_preview_orchestrator
- Roles: orchestrator, user_liaison, human_reporter, successor
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1
- Original parent: Sentinel / Parent Agent
- Original parent conversation ID: a7d46489-2025-4b52-802d-d76c62fdd75f

## 🔒 My Workflow
- **Pattern**: Project Pattern (Multi-Wave Architecture Transformation)
- **Scope document**: /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md
1. **Decompose**: Waves 0 through 5 as sequential milestone waves, with parallel worker packages within each wave per parallel-plan.md.
2. **Dispatch & Execute**:
   - Survey: Spawn 3 parallel Explorers to inspect existing contracts, tests, proof status, and plan alignment. (COMPLETED)
   - Wave 0: Contract boundaries, types, test fixtures. (DONE: 953 tests pass, Gate certified PASS)
   - Wave 1: Packages A, B, C. (IN_PROGRESS: Parallel workers active)
   - Wave 2: Packages D, E, F. (PLANNED)
   - Wave 3: Packages G, H, I. (PLANNED)
   - Wave 4: Packages J, K, L. (PLANNED)
   - Wave 5: Packages M, N, O. (PLANNED)
   - Per milestone/wave: Explorer -> Worker -> Reviewer (x2) -> Challenger (x2) -> Auditor -> Gate check.
3. **On failure**:
   - Retry: nudge stuck agent or re-send task
   - Replace: spawn fresh agent with partial progress
   - Skip: proceed without (only if non-critical, never skip Auditor)
   - Redistribute: split stuck agent's remaining work
   - Redesign: re-partition decomposition
4. **Succession**: Self-managing orchestrator directly.
- **Work items**:
  1. Survey phase (3 parallel explorers) [done]
  2. Wave 0 (Coordinator boundaries & fixtures) [done]
  3. Wave 1 (Packages A, B, C) [done]
  4. Wave 2 (Packages D, E, F) [done]
  5. Wave 3 (Packages G, H, I) [in-progress: exploration phase]
  6. Wave 4 (Packages J, K, L) [pending]
  7. Wave 5 (Packages M, N, O) [pending]
  8. Final acceptance & integration gate [pending]
- **Current phase**: Wave 3 (Packages G, H, I: Headless Engine, UI Decoupling & Privacy)
- **Current focus**: Exploration & Architecture Blueprints for Packages G, H, and I

## 🔒 Key Constraints
- NEVER write, modify, or create source code files directly.
- NEVER run build/test commands yourself — require workers to do so.
- NEVER investigate or explore the problem at the code level — dispatch Explorers for technical investigation.
- You MAY use file-editing tools ONLY for metadata/state files (.md) in your .agents/teamwork/ folder.
- Never reuse a subagent after it has delivered its handoff — always spawn fresh.
- Single-active-run invariant per Emacs application instance (ARCH-01/ARCH-12).
- Pluggable/detachable adapters without breaking core offline functionalities (ARCH-09).
- NEVER modify or stage skills.md, .gitignore, or .agents/.
- Zero byte-compilation warnings on all modified/new Elisp files under kargu/ and tests/ with (setq byte-compile-error-on-warn t).
- 100% ERT pass rate.
- Clean up any temporary .elc files before completion.
- Forensic Auditor verdict is a binary veto — violation means failure, no exceptions.
- Mandatory integrity warning in all Worker prompts.

## Current Parent
- Conversation ID: a7d46489-2025-4b52-802d-d76c62fdd75f
- Updated: 2026-10-21T21:57:00Z

## Key Decisions Made
- Wave 0 Milestone certified DONE (953 tests pass, Gate certified PASS).
- Wave 1 Milestone certified DONE (997 tests pass, Gate certified PASS, 4 TLC models pass).
- Wave 2 Milestone certified DONE (1052 tests pass, Gate certified PASS, 0 compile warnings, CLEAN audit, all TLC models pass).
- Wave 3 (Packages G, H, I) initiated.
- Succession triggered: spawn count reached 34 (threshold 16), all subagents complete.

## Team Roster (Wave 3 Exploration Phase)
| Agent | Type | Work Item | Status | Conv ID |
|-------|------|-----------|--------|---------|
| explorer_wave3_G | teamwork_preview_explorer | Wave 3 Package G Explorer (Headless Loop & Budget) | in-progress | 7ad042a0-4eb5-4088-98b9-b277228ac8ad |
| explorer_wave3_H | teamwork_preview_explorer | Wave 3 Package H Explorer (View, Selection & Plan) | in-progress | 84eacde4-1596-4ba4-b701-907bf70f6664 |
| explorer_wave3_I | teamwork_preview_explorer | Wave 3 Package I Explorer (Log Redaction & Retention) | in-progress | 22a0a093-23fc-4075-9855-f303d75db68a |

## Succession Status
- Succession required: no (orchestrator subagent not invokable; single orchestrator persists)
- Predecessor: none
- Successor: none

## Active Timers
- Heartbeat cron: 246e42bd-e1b7-4f73-8026-d90704dd17ec/task-907
- Safety timer: none

## Artifact Index
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md — Original request
- /home/emrehan/.emacs.local/kargu/parallel-plan.md — Multi-wave architecture transformation plan
- /home/emrehan/.emacs.local/kargu/todo.md — Tracking todo list
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md — Global architecture & feature inventory
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/GATE_STATUS.md — Gate status file (Waves 0, 1, 2 certified PASS)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/progress.md — Execution progress tracking
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/handoff.md — Soft handoff for successor
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md — 8 core architecture contracts
