## 2026-10-21T23:23:49Z
You are explorer_wave2_E, working as Wave 2 Package E Explorer (Bounded Transport & Circuit Breakers).
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 5: Dalga 2, Package E)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Contract 6: Budget Accounting, Contract 4: Connection Snapshot)
- /home/emrehan/.emacs.local/kargu/todo.md (MOD-04, RISK-02, DEEP-09/12/14, ARCH-15/16/17/19)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

Scope & Tasks:
1. Analyze existing transport and API files:
   - `kargu/api.el`, `kargu/api/client.el`, `kargu/api/http.el`, `kargu/api/request.el`, `kargu/api/retry.el`, `kargu/api/response.el`, `kargu/api/parameters.el`, `kargu/api/sse.el`, `kargu/api/stream.el`, `kargu/api/wire.el`, `kargu/api/tool-calls.el`, `kargu/api/cache.el`, `kargu/api/circuit.el`.
   - Tests: `tests/test-api.el`, `tests/test-stream.el`, `tests/test-tool-calls.el`, `tests/test-parameters.el`, `tests/test-cache.el`.
   - Proof: `proof/KarguCircuit.tla`, `proof/CircuitMC.tla`, `proof/CircuitMC.cfg`.
2. Design bounded transport architecture:
   - Create requests using Application (Package A) and Connection Snapshot (Package C) handles. Single logical handle owns all process/retry/watch resources.
   - Every attempt and retry debits from Package A's `kargu-run-budget` (`kargu/application/budget.el`).
   - Provider/connection-scoped circuit breaker (`circuit.el`).
   - Bounded parser & buffer drains for raw output, incomplete UTF-8/lines, SSE events, and tool-call accumulation (`sse.el`, `stream.el`, `wire.el`).
   - Typed error callbacks; TLS/redirect/origin security verification.
   - Address RISK-02 requirements.
3. Design new test suites: `tests/test-transport-contract.el` and `tests/test-stream-pressure.el`.
4. Design formal model: `proof/KarguTransport.tla`, `proof/TransportMC.tla`, `proof/TransportMC.cfg`, update `proof/run_tlc.sh`.
5. Provide concrete before/after code blocks for Worker E.
6. Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/package_E_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/handoff.md`.
7. Send completion message to caller via send_message.
