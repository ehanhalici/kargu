## 2026-10-21T21:56:44Z
You are worker_wave1_C, working on Wave 1 Package C: Async Credential Discovery and Connection Snapshot.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_C

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 4: Package C)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Connection snapshot contract)
- /home/emrehan/.emacs.local/kargu/todo.md (CONFIG-01, ARCH-15, ARCH-19, DEEP-14, MOD-03)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope & Exclusive Write Allowlist:
- kargu/config.el
- kargu/config/key.el
- kargu/config/schema.el
- kargu/config/toml.el
- kargu/providers/registry.el
- New: kargu/config/connection.el
- New: kargu/config/worker.el
- Tests: tests/test-config.el, tests/test-providers.el, new tests/test-connection-snapshot.el
- Proof: new proof/KarguConnection.tla, proof/ConnectionMC.tla, proof/ConnectionMC.cfg
- Register tests/test-connection-snapshot in tests/run-tests.el.
NEVER modify or stage skills.md, .gitignore, or .agents/. Do NOT touch files owned by Package A or B.

Tasks:
1. Fix CONFIG-01: UI and discovery must read purely from in-memory snapshots; ensure `auth-source-search` or callable `:secret` functions are NEVER called synchronously on the Emacs UI thread.
2. Asynchronous Credential Worker: Implement cancellable worker/adapter in `kargu/config/worker.el` for disk/auth resolution. Never pass secrets in argv. Nonblocking timeout/Stop.
3. Connection Snapshot: Implement immutable `kargu-connection-snapshot` in `kargu/config/connection.el` binding provider, model, endpoint, capability, config revision, and credential scope.
4. Test Suite: Add `tests/test-connection-snapshot.el` verifying callable secret safety (CONFIG-01), keyless/offline mode, nonblocking cancellation, stale discard, and zero secret leakage into logs/traces.
5. Formal Model: Create `proof/KarguConnection.tla`, `proof/ConnectionMC.tla`, `proof/ConnectionMC.cfg`, add `--connection` flag to `proof/run_tlc.sh`, and verify TLC model checks pass.
6. Verification:
   - Run ERT tests: `emacs -Q --batch -L . -l kargu -l tests/test-helpers.el -f ert-run-tests-batch-and-exit`
   - Byte-compilation with `(setq byte-compile-error-on-warn t)`: 0 warnings.
   - Checkdoc: 0 warnings on modified/new files.
   - Zero `.elc` files left in repo.
   - TLC model check: `bash proof/run_tlc.sh --connection`.
7. Write detailed report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_C/worker_C_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_C/handoff.md`.
8. Send completion message to caller.
