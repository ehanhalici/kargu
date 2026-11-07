# BRIEFING — 2026-10-22T03:42:00Z

## Mission
Implement Wave 2 Package E: Bounded Transport & Circuit Breakers.

## 🔒 My Identity
- Archetype: implementer, qa, specialist
- Roles: implementer, qa, specialist
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_E
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Wave 2 Package E

## 🔒 Key Constraints
- Scope & Exclusive Write Allowlist:
  - `kargu/api.el`
  - `kargu/api/client.el`
  - `kargu/api/http.el`
  - `kargu/api/request.el`
  - `kargu/api/retry.el`
  - `kargu/api/response.el`
  - `kargu/api/parameters.el`
  - `kargu/api/sse.el`
  - `kargu/api/stream.el`
  - `kargu/api/wire.el`
  - `kargu/api/tool-calls.el`
  - `kargu/api/cache.el`
  - `kargu/api/circuit.el`
  - Tests: `tests/test-api.el`, `tests/test-stream.el`, `tests/test-tool-calls.el`, `tests/test-parameters.el`, `tests/test-cache.el`, new `tests/test-transport-contract.el`, `tests/test-stream-pressure.el`
  - Proof: `proof/KarguCircuit.tla`, `proof/CircuitMC.tla`, `proof/CircuitMC.cfg`, new `proof/KarguTransport.tla`, `proof/TransportMC.tla`, `proof/TransportMC.cfg`, `proof/run_tlc.sh`
- NEVER modify or stage skills.md, .gitignore, or .agents/ (except metadata in own agent folder).
- Do NOT touch files owned by Package D (e.g., `kargu/api/tools.el`) or Package F.
- Genuine implementation only, no cheating or test hardcoding.
- Pass byte-compile with `byte-compile-error-on-warn t`, checkdoc, ERT tests, TLC `--transport`. Remove any `.elc` files.

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-22T03:12:22Z

## Task Summary
- **What to build**: Provider-scoped circuit breakers, unified run budget accounting hook, elimination of string parsing for retry control decisions, bounded stream drains & backpressure, logical request handle ownership, formal TLA+ model & test suites.
- **Success criteria**: Full ERT test pass (0 failures), byte-compilation zero warnings, checkdoc clean, TLC verification pass, reports in place.
- **Interface contracts**: parallel-plan.md, architecture-contracts.md (Contract 4, 6), todo.md (MOD-04, RISK-02, DEEP-09, DEEP-12, DEEP-14, ARCH-15, ARCH-16, ARCH-17, ARCH-19).
- **Code layout**: .agents/teamwork holds only agent metadata.

## Key Decisions Made
- Scoped circuit breakers use canonical provider name string key with bidirectional sync to legacy dynamic variables (`kargu-circuit--state`, etc.) for backward-compatibility with existing tests and mocks.
- Run budget debits `:normal-request` for initial attempts and `:retry-attempt` for retries; cancels retries immediately if budget is exhausted.
- Replaced string matching in `kargu/api/retry.el` with canonical `kargu-result-err` symbols and status codes.
- Added stream backpressure caps on incomplete lines (64KB), raw bytes (4MB), single event size (1MB), tool call counts (64), and tool args bytes (512KB).
- Implemented `kargu-http--strip-auth-for-cross-origin` to strip authorization headers on cross-origin redirects.

## Artifact Index
- DISPATCH.md — assignment instructions
- BRIEFING.md — situational awareness
- progress.md — liveness & heartbeat
- worker_E_report.md — comprehensive implementation and verification report
- handoff.md — 5-component handoff report

## Change Tracker
- **Files modified**: `kargu/api/circuit.el`, `kargu/api/client.el`, `kargu/api/http.el`, `kargu/api/parameters.el`, `kargu/api/request.el`, `kargu/api/response.el`, `kargu/api/retry.el`, `kargu/api/sse.el`, `kargu/api/stream.el`, `kargu/api/tool-calls.el`, `proof/run_tlc.sh`, `tests/test-parameters.el`.
- **New files**: `proof/KarguTransport.tla`, `proof/TransportMC.tla`, `proof/TransportMC.cfg`, `tests/test-stream-pressure.el`, `tests/test-transport-contract.el`.
- **Build status**: Pass (0 warnings with `byte-compile-error-on-warn t`, checkdoc clean).
- **Pending issues**: None.

## Quality Status
- **Build/test result**: Pass (TLC: 1810 states / 0 errors; ERT: 68/68 Package E tests pass, 33/33 loop tests pass).
- **Lint status**: Clean (checkdoc 0 warnings).
- **Tests added/modified**: `tests/test-stream-pressure.el` (7 tests), `tests/test-transport-contract.el` (9 tests).
