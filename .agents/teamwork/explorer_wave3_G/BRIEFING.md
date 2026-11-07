# BRIEFING — 2026-10-22T04:50:50Z

## Mission
Analyze existing loop and history files, design headless engine loop architecture, history queue/protocol wall, and unified budget consumption for Wave 3 Package G, producing package_G_report.md and handoff.md.

## 🔒 My Identity
- Archetype: explorer
- Roles: investigator, analyzer, synthesizer
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_G
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Wave 3 Package G

## 🔒 Key Constraints
- Read-only investigation — do NOT implement / modify source code directly
- Maintain owned queue in history/store.el, protocol wall in history/protocol.el
- Engine headless connection to Package A (kargu-application, coordinator, budget), Package D (tools/execution gate), Package E (api/request port)
- Single terminal :finish event, minimal immutable event payloads, safe delivery to registered observers (ARCH-07/ARCH-08)
- All retries, heal attempts, compaction calls, continue steps debit from kargu-run-budget (Contract 6)
- Report unknown for baseline diagnostics if unavailable, do not fabricate clean state
- Design test suites tests/test-headless-events.el and tests/test-budget-composition.el
- Review formal models in proof/

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-22T04:50:50Z

## Investigation State
- **Explored paths**:
  - `kargu/loop.el`, `kargu/loop/machine.el`, `kargu/loop/tools.el`, `kargu/loop/ui.el`, `kargu/loop/heal.el`, `kargu/loop/compact.el`
  - `kargu/history.el`, `kargu/history/store.el`, `kargu/history/protocol.el`, `kargu/history/repair.el`, `kargu/history/compact.el`
  - `kargu/prompt.el`, `kargu/prompt/default.txt`
  - `kargu/application/coordinator.el`, `kargu/application/budget.el`
  - `kargu/tools/execution.el`, `kargu/api/request.el`, `kargu/api/http.el`, `kargu/api/client.el`
  - `tests/test-loop.el`, `tests/test-history.el`, `tests/test-history-store.el`, `tests/test-heal.el`, `tests/test-compact.el`, `tests/test-fake-agent.el`, `tests/test-modules.el`
  - `proof/KarguLoop.tla`, `proof/KarguProtocol.tla`, `proof/KarguVerification.tla`, `proof/VerificationMC.tla`, `proof/BudgetMC.tla`, `proof/run_tlc.sh`
- **Key findings**:
  - Full baseline ERT test suite passes 100% (1052/1052 tests, 0 failures, 0 errors).
  - Loop currently lacks explicit `kargu-application-claim` binding, assumes `:chat-buffer` is a live buffer for hooks, and lacks structured event correlation IDs.
  - Compaction, healing, and continuations call `kargu-api-send` without passing `:debit-type`, leaving `kargu-run-budget` compaction counter untracked.
  - Tool execution in loop duplicates mode checks instead of routing directly to Package D's unified 13-stage `kargu-tool-gate-execute`.
  - Baseline diagnostics when unavailable need explicit `:unknown` classification in reports.
- **Unexplored areas**: None within Package G scope. Ready for Worker G dispatch.

## Key Decisions Made
- `kargu-loop-send` extended with optional keyword arguments `&key app budget chat-buffer mode observers` to maintain backwards compatibility while supporting full headless execution and explicit application claims.
- `kargu-loop-emit-event` designed with `kargu-event-id`, `kargu-passive-event`, monotonic sequence numbering, observer error trap, and single terminal `:run-finish` guarantee.
- Direct connection established between `kargu/loop/tools.el` and Package D's `kargu-tool-gate-execute` with `kargu-tool-execution-context`.
- Debit type routing (`:normal-request`, `:retry-attempt`, `:compaction-turn`, `:healing-turn`, `:continuation`) plumbed through `kargu-api-send` to `kargu--api-post`, ensuring all operations debit the unified `kargu-run-budget`.
- Defined two new test suites: `tests/test-headless-events.el` and `tests/test-budget-composition.el`.

## Artifact Index
- DISPATCH.md — Received dispatch instructions
- BRIEFING.md — Persistent working memory
- progress.md — Liveness heartbeat and status
- package_G_report.md — Comprehensive architectural analysis and implementation blueprint for Worker G
- handoff.md — 5-component hard handoff report
