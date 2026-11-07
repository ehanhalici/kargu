# BRIEFING — 2026-10-21T22:31:00Z

## Mission
Implement Wave 1 Package C: Async Credential Discovery and Connection Snapshot (CONFIG-01, ARCH-15, ARCH-19, DEEP-14, MOD-03), including non-blocking worker, immutable connection snapshot, tests, and TLA+ formal model.

## 🔒 My Identity
- Archetype: implementer
- Roles: implementer, qa, specialist
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_C
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Wave 1 Package C

## 🔒 Key Constraints
- Pure in-memory reads for UI and discovery; auth-source-search or callable `:secret` NEVER called synchronously on UI thread (CONFIG-01).
- Non-blocking cancellable worker/adapter for disk/auth resolution in `kargu/config/worker.el`. Never pass secrets in argv.
- Immutable `kargu-connection-snapshot` binding provider, model, endpoint, capability, config revision, credential scope.
- Zero secret leakage into logs, debug buffers, or error messages.
- Exclusive write allowlist: kargu/config.el, kargu/config/key.el, kargu/config/schema.el, kargu/config/toml.el, kargu/providers/registry.el, kargu/config/connection.el, kargu/config/worker.el, tests/test-config.el, tests/test-providers.el, tests/test-connection-snapshot.el, proof/KarguConnection.tla, proof/ConnectionMC.tla, proof/ConnectionMC.cfg, proof/run_tlc.sh, tests/run-tests.el, and local .agents/teamwork/worker_wave1_C/.
- NEVER modify or stage skills.md, .gitignore, or other .agents/ folders. Do NOT touch files owned by Package A or B.
- Byte-compile with `(setq byte-compile-error-on-warn t)`: 0 warnings.
- Checkdoc: 0 warnings on modified/new files.
- Zero `.elc` files left in repo.
- TLC model check passes: `bash proof/run_tlc.sh --connection`.

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-21T22:31:00Z

## Task Summary
- **What to build**: Asynchronous credential discovery worker, immutable connection snapshot structure and lifecycle, update config/registry integration, ERT tests for connection snapshot and secret safety, and TLA+ formal specification + TLC verification.
- **Success criteria**: All ERT tests pass, 0 byte-compile warnings with error-on-warn, 0 checkdoc warnings, TLC model checks pass, no secret leakage, no UI freezes.
- **Interface contracts**: /home/emrehan/.emacs.local/kargu/architecture-contracts.md
- **Code layout**: /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

## Key Decisions Made
- Added monotonic integer `kargu-config-revision` and `kargu-config-bump-revision` in `kargu/config/schema.el`. Bumped on TOML reload and provider change.
- Fixed `CONFIG-01`: `kargu-config-api-key-fast` strictly performs pure in-memory lookup. `kargu-config-resolve-api-key-result` returns `:unavailable` for callable secrets to prevent synchronous execution on Emacs UI thread.
- Created `kargu/config/worker.el`: Non-blocking subprocess via `make-process` running `emacs -Q --batch`. Passes host and paths only in argv (never secrets). 64KB bounded output buffer. Clean cancellation with immediate process termination (`delete-process`).
- Created `kargu/config/connection.el`: Immutable struct `kargu-connection-snapshot` and opaque `kargu-credential-scope` with `clear-string` memory wiping. Implemented `kargu-connection-resolve-async` with URL validation, immediate keyless resolution, worker delegation, and stale discard upon config revision or session change. Safe `kargu-connection-redacted-summary` for logs.
- Formal TLA+ specification in `proof/KarguConnection.tla`, `proof/ConnectionMC.tla`, `proof/ConnectionMC.cfg`, and `--connection` dispatcher in `proof/run_tlc.sh`. Exhaustive model check completed with 77,292 distinct states and 0 errors.

## Artifact Index
- `kargu/config/worker.el` — Non-blocking async worker child process
- `kargu/config/connection.el` — Immutable snapshot and credential scope
- `kargu/config/schema.el` — Config revision and non-blocking setup check
- `kargu/config/key.el` — Fast in-memory resolution & callable secret guard
- `kargu/config.el` — Module exports
- `tests/test-connection-snapshot.el` — 11 ERT tests for connection snapshot
- `tests/run-tests.el` — Test runner registration
- `proof/KarguConnection.tla` — TLA+ formal specification
- `proof/ConnectionMC.tla` — TLC model checking module
- `proof/ConnectionMC.cfg` — TLC model checking configuration
- `proof/run_tlc.sh` — TLC test script update (`--connection`)
- `.agents/teamwork/worker_wave1_C/worker_C_report.md` — Detailed Package C implementation report
- `.agents/teamwork/worker_wave1_C/handoff.md` — 5-component handoff report

## Change Tracker
- **Files modified**:
  - `kargu/config/schema.el`: revision counter and bump functions
  - `kargu/config/key.el`: safe fast key resolution and async worker delegation
  - `kargu/config.el`: exported worker and connection submodules
  - `proof/run_tlc.sh`: added `--connection` flag
  - `tests/run-tests.el`: registered `tests/test-connection-snapshot`
- **Files created**:
  - `kargu/config/worker.el`: subprocess auth-source resolution worker
  - `kargu/config/connection.el`: snapshot struct, scope, wipe, resolve-async
  - `tests/test-connection-snapshot.el`: 11 ERT tests for snapshot contracts
  - `proof/KarguConnection.tla`: TLA+ formal model
  - `proof/ConnectionMC.tla`: TLA+ TLC model checker module
  - `proof/ConnectionMC.cfg`: TLA+ TLC configuration
- **Build status**: Pass (0 warnings under byte-compile-error-on-warn t)
- **Pending issues**: None

## Quality Status
- **Build/test result**: Pass. 41 ERT tests pass (11 connection snapshot + 11 config + 19 providers). TLC exhaustive scan passed (77,292 distinct states, 0 errors).
- **Lint status**: 0 checkdoc warnings. Clean.
- **Tests added/modified**: `tests/test-connection-snapshot.el` (11 new tests covering immutable slots, redaction, callable secret safety, keyless mode, timeout, worker argv safety, cancellation cleanup, stale revision discard, retry preservation, wipe lifecycle).

## Loaded Skills
- None specified by orchestrator
