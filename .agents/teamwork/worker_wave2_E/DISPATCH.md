## 2026-10-22T03:12:22Z
You are worker_wave2_E, working on Wave 2 Package E: Bounded Transport & Circuit Breakers.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_E

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/package_E_report.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/handoff.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/proposed_KarguTransport.tla
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/proposed_TransportMC.tla
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/proposed_TransportMC.cfg
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/proposed_run_tlc.patch
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/proposed_test_transport_contract.el
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_E/proposed_test_stream_pressure.el
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 5: Package E)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Contract 6: Budget Accounting, Contract 4: Connection Snapshot)
- /home/emrehan/.emacs.local/kargu/todo.md (MOD-04, RISK-02, DEEP-09, DEEP-12, DEEP-14, ARCH-15, ARCH-16, ARCH-17, ARCH-19)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope & Exclusive Write Allowlist:
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
NEVER modify or stage skills.md, .gitignore, or .agents/. Do NOT touch files owned by Package D or Package F. (Note: `kargu/api/tools.el` belongs exclusively to Package D).

Tasks:
1. Provider-Scoped Circuit Breakers:
   Replace global circuit variables in `kargu/api/circuit.el` with explicit `kargu-circuit-breaker` struct keyed by provider name. Ensure provider failure independence.
2. Unified Run Budget Accounting:
   Hook initial HTTP attempts and retries to Package A's `kargu-run-budget` (`kargu/application/budget.el`) in `kargu/api/request.el` and `kargu/api/retry.el`. Halt retries when budget is exhausted. Track token counts via `kargu-budget-record-tokens`.
3. Eliminate String Parsing for Control Decisions (ARCH-16):
   Replace string matching in `kargu/api/retry.el` with canonical `kargu-result-err` domain symbols and status codes.
4. Bounded Stream Drains & Backpressure:
   Enforce hard bounds in `kargu/api/sse.el`, `kargu/api/stream.el`, and `kargu/api/wire.el` on raw buffer, incomplete lines, tool call counts, and tool args length. Abort immediately on breach.
5. Logical Request Handle Ownership:
   Ensure `kargu-logical-request` cleanly encapsulates process, watchdog timer, and retry timers with idempotent cancellation.
6. Test Suites:
   Add `tests/test-transport-contract.el` and `tests/test-stream-pressure.el` from proposed files.
7. Formal Model:
   Install `proof/KarguTransport.tla`, `proof/TransportMC.tla`, `proof/TransportMC.cfg`, and apply `--transport` patch to `proof/run_tlc.sh`. Verify TLC model checking passes.
8. Verification:
   - Run ERT tests: `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
   - Run byte-compilation check with `(setq byte-compile-error-on-warn t)` on all modified/new files. Confirm 0 warnings.
   - Run checkdoc on modified/new files.
   - Confirm zero `.elc` files remain.
   - Run TLC: `bash proof/run_tlc.sh --transport`.
   - Confirm repository hygiene: `git status --porcelain skills.md .gitignore .agents/` is empty.
9. Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_E/worker_E_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_E/handoff.md`.
10. Send completion message to caller via send_message.
