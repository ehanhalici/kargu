## 2026-10-22T04:40:12Z
You are explorer_wave3_G, working as Wave 3 Package G Explorer (Headless Loop, History Protocol Wall & Unified Budget Consumption).
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_G

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 6: Dalga 3, Package G)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Contract 1: Application, Contract 5: Tool Execution, Contract 6: Budget Accounting, Contract 7: Events)
- /home/emrehan/.emacs.local/kargu/todo.md (MOD-01, ARCH-07, ARCH-08, ARCH-11, ARCH-14, ARCH-16, DEEP-01, DEEP-02, DEEP-04, DEEP-09)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/handoff.md

Scope & Tasks:
1. Analyze existing loop and history files:
   - `kargu/loop.el`, `kargu/loop/machine.el`, `kargu/loop/tools.el`, `kargu/loop/ui.el`, `kargu/loop/heal.el`, `kargu/loop/compact.el`
   - `kargu/history.el`, `kargu/history/store.el`, `kargu/history/protocol.el`, `kargu/history/repair.el`, `kargu/history/compact.el`
   - `kargu/prompt.el`, `kargu/prompt/default.txt`
   - Tests: `tests/test-loop.el`, `tests/test-history.el`, `tests/test-history-store.el`, `tests/test-heal.el`, `tests/test-compact.el`, `tests/test-fake-agent.el`
   - Proof: `proof/KarguLoop.tla`, `proof/KarguProtocol.tla`, `proof/KarguVerification.tla`, `proof/VerificationMC.tla`, `proof/VerificationMC.cfg`
2. Design headless engine loop architecture:
   - Engine connects directly to Package A's `kargu-application` and execution context (`kargu/application/coordinator.el`), Package D's unified gate (`kargu/tools/execution.el`), and Package E's request port (`kargu/api/request.el`).
   - Remove any requirement for UI buffers, chat helpers, or global UI pending lists when running headless.
   - Structured event emission: single terminal `:finish` event, minimal immutable event payloads, safe delivery to registered observers (ARCH-07/ARCH-08).
3. Unified Run Budget Consumption (Contract 6):
   - All retries, heal attempts, compaction calls, and continue steps must debit from Package A's `kargu-run-budget` (`kargu/application/budget.el`).
   - Guard against second overflow and failed/empty summary paths. Ensure single-compaction default is maintained.
4. History Queue & Protocol Wall:
   - Maintain owned queue in `kargu/history/store.el`.
   - Every outbound request must pass through the protocol wall (`kargu/history/protocol.el`).
   - Measure cost of new turns without full re-encoding of entire history where possible.
5. Baseline Diagnostics:
   - When baseline diagnostics are unavailable, report `unknown` rather than fabricating clean state or new regressions.
6. Design new test suites:
   - `tests/test-headless-events.el` (verifying full tool turn without chat/UI buffers using fake model, clean single finish event, observer Stop)
   - `tests/test-budget-composition.el` (verifying that normal requests, retries, heal, and compact all consume the unified budget)
7. Formal Models & TLC:
   - Inspect `proof/KarguLoop.tla`, `proof/KarguProtocol.tla`, `proof/KarguVerification.tla`, `proof/run_tlc.sh`. Verify configuration requirements.
8. Output:
   - Provide concrete before/after code blocks, signatures, and implementation blueprint for Worker G.
   - Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_G/package_G_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_G/handoff.md`.
   - Send completion message to caller via send_message.
