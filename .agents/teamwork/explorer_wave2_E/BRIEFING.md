# BRIEFING — 2026-10-21T23:34:30Z

## Mission
Analyze and design Wave 2 Package E (Bounded Transport & Circuit Breakers) for Kargu, covering handle-owned transport, budget debiting, connection-scoped circuit breakers, bounded stream parsers/drains, TLS/redirect verification, formal TLA+ specifications, and test suites.

## 🔒 My Identity
- Archetype: explorer
- Roles: investigation, synthesis
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Wave 2 Package E (Bounded Transport & Circuit Breakers)

## 🔒 Key Constraints
- Read-only investigation — do NOT implement source files directly
- Propose concrete before/after code blocks, architecture designs, test suites, and formal models for Worker E
- Write package_E_report.md and handoff.md in working directory
- Send completion message to parent (246e42bd-e1b7-4f73-8026-d90704dd17ec)

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-21T23:34:30Z

## Investigation State
- **Explored paths**:
  - `kargu/api.el`, `kargu/api/*.el` (`client.el`, `http.el`, `request.el`, `retry.el`, `response.el`, `parameters.el`, `sse.el`, `stream.el`, `wire.el`, `tool-calls.el`, `cache.el`, `circuit.el`)
  - `tests/test-api.el`, `tests/test-stream.el`, `tests/test-tool-calls.el`, `tests/test-parameters.el`, `tests/test-cache.el`
  - `proof/KarguCircuit.tla`, `proof/CircuitMC.tla`, `proof/KarguBudget.tla`, `proof/KarguConnection.tla`, `proof/run_tlc.sh`
- **Key findings**:
  - `circuit.el` uses global mutable variables; failures on one provider trip the circuit globally for all providers (MOD-05).
  - `retry.el` retries without debiting from Package A's `kargu-run-budget` (Contract 6, DEEP-09).
  - `sse.el` and `stream.el` lack hard upper limits on incomplete line buffers, raw process buffers, and tool-call argument concatenation (DEEP-12).
  - String regex matching used for retry decisions instead of typed Result contracts (ARCH-16).
  - Missing cross-origin redirect credential stripping (DEEP-14).
  - Sampling parameter selection lacks reasoning effort compatibility guard (RISK-02).
- **Unexplored areas**: None within Package E scope. All architectural boundaries and contracts verified.

## Key Decisions Made
- Define `kargu-circuit-breaker` struct and registry table keyed by provider name/endpoint for provider isolation.
- Tie transport initial request and retries to `kargu-budget-debit` (`:normal-request` and `:retry-attempt`).
- Establish strict byte bounds on stream: incomplete line (64KB), raw buffer (4MB), single event (1MB), tool call arguments (512KB), and max tool calls (64).
- Add cooperative event loop yielding for SSE burst processing.
- Design `KarguTransport.tla` formal specification and verify with TLC (1,810 states, 0 errors).

## Artifact Index
- `DISPATCH.md` — incoming dispatch instructions
- `BRIEFING.md` — persistent situational awareness
- `progress.md` — liveness heartbeat
- `package_E_report.md` — comprehensive architecture exploration report
- `handoff.md` — 5-component handoff report for Worker E
- `proposed_KarguTransport.tla` — verified TLA+ transport specification
- `proposed_TransportMC.tla` — TLC model checking harness
- `proposed_TransportMC.cfg` — TLC configuration
- `proposed_run_tlc.patch` — diff to add `--transport` to `proof/run_tlc.sh`
- `proposed_test_transport_contract.el` — contract compliance test suite
- `proposed_test_stream_pressure.el` — stream backpressure test suite
