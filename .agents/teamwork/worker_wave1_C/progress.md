# Progress - worker_wave1_C

Last visited: 2026-10-21T22:31:00Z

## Status
All Package C tasks completed:
- `kargu/config/schema.el`: Implemented monotonic integer `kargu-config-revision` and `kargu-config-bump-revision`. Updated `kargu-check-setup` to avoid UI hangs.
- `kargu/config/worker.el`: Created non-blocking subprocess worker for auth-source resolution (`make-process` running `emacs -Q --batch`). Zero secrets in argv. 64KB bounded output buffer. Clean cancellation with immediate process cleanup.
- `kargu/config/connection.el`: Created immutable `kargu-connection-snapshot`, opaque `kargu-credential-scope` with `clear-string` memory wiping, `kargu-connection-redacted-summary`, and `kargu-connection-resolve-async` with URL validation, immediate keyless resolution, and stale revision/session discard.
- `kargu/config/key.el`: Enforced CONFIG-01: synchronous resolution refuses callable `:secret` functions with `:unavailable`; async resolution delegates to background worker.
- `kargu/config.el`: Exported worker and connection modules.
- `tests/test-connection-snapshot.el`: 11 comprehensive ERT tests added (100% pass rate).
- `tests/run-tests.el`: Registered `tests/test-connection-snapshot`.
- `proof/KarguConnection.tla`, `proof/ConnectionMC.tla`, `proof/ConnectionMC.cfg`: TLA+ formal specification created.
- `proof/run_tlc.sh`: Added `--connection` flag.
- TLC Model Checking: Exhaustive scan passed (77,292 distinct states, 0 errors).
- Byte-compile: 0 warnings under `byte-compile-error-on-warn t` across all Package C files.
- Checkdoc: 0 warnings across all Package C files.
- Zero `.elc` files in repository.
