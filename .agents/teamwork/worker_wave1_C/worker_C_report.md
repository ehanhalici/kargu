# Wave 1 Package C: Async Credential Discovery and Connection Snapshot Report

## 1. Executive Summary

- **Package**: Wave 1 Package C
- **Requirements Addressed**: CONFIG-01, ARCH-15, ARCH-19, DEEP-14, MOD-03
- **Primary Objectives**:
  1. Eliminate UI thread hangs from synchronous auth-source searches or GPG decrypts (CONFIG-01).
  2. Implement a background non-blocking credential discovery worker (`kargu/config/worker.el`).
  3. Implement an immutable connection snapshot data structure and lifecycle (`kargu/config/connection.el`).
  4. Ensure zero secret leakage in `argv`, log buffers, traces, or debug representations.
  5. Provide comprehensive ERT test suites covering immutability, safety, cancellation, stale discard, and retry preservation.
  6. Specify and verify formal TLA+ model (`proof/KarguConnection.tla`) with exhaustive TLC model checking.
- **Verification Status**:
  - **ERT Tests**: 41 passed (11 `test-connection-snapshot.el`, 11 `test-config.el`, 19 `test-providers.el`). 100% pass rate.
  - **TLC Model Check**: 77,292 distinct states checked exhaustively, 0 errors.
  - **Byte Compilation**: 0 warnings with `(setq byte-compile-error-on-warn t)`.
  - **Checkdoc**: 0 warnings across all production and test files.
  - **Leftover Artifacts**: 0 `.elc` files.

---

## 2. Root Cause Analysis: CONFIG-01

Prior to this implementation:
- `kargu-config-resolve-api-key-async` fell back to `kargu-config-resolve-api-key-result` synchronously on the Emacs UI thread when no external adapter was registered.
- `kargu-config-resolve-api-key-result` called `kargu--auth-source-api-key`, which invoked `auth-source-search` directly. When `:secret` was a callable function (e.g. `epa--auth-source-password`), evaluating it synchronously triggered GPG passphrase prompts or pinentry dialogues, freezing the Emacs event loop.
- `kargu-check-setup` called `kargu--resolve-api-key`, which similarly invoked `auth-source-search` synchronously on the UI thread.
- Provider discovery in `kargu-provider-authenticated-p` called `kargu-config-api-key-fast`, which risked UI freezes.

### Resolution:
1. `kargu-config-api-key-fast` now strictly performs pure in-memory reads via `kargu--resolve-direct-api-key` (environment variables and in-memory TOML plist), never querying `auth-source-search`.
2. `kargu-config-resolve-api-key-result` explicitly refuses callable `:secret` functions during synchronous evaluation, returning typed error `unavailable` (`:auth-unavailable`).
3. `kargu-config-resolve-api-key-async` delegates all disk/auth searches to the background worker (`kargu-config-worker-resolve`) asynchronously.
4. `kargu-check-setup` uses `kargu-config-api-key-fast` to guarantee non-blocking execution during startup/status checks.

---

## 3. Architecture & Implementation Details

### 3.1 Background Worker (`kargu/config/worker.el`)
- **Process Model**: Spawns an external asynchronous process using `make-process` invoking `emacs -Q --batch`.
- **Zero Secrets in Argv**: Process arguments contain only the provider name and the target hostname (derived from the URL via `kargu--url-host`). Secret keys and tokens are never passed on the command line or visible in `ps`/process listings.
- **Bounded Buffering**: The worker process buffer is capped at 64 KB (`kargu-config-worker--max-output-bytes`), preventing memory exhaustion if unexpected output is produced.
- **Strict Cancellation**: The worker returns an async cancellable task. Calling `kargu-async-cancel` terminates the child process immediately via `delete-process` and kills the process buffer, ensuring no orphan subprocesses linger.
- **Timeout Support**: Automatically schedules a timer to terminate unresponsive worker processes after a bounded timeout (default 10s).

### 3.2 Immutable Connection Snapshot (`kargu/config/connection.el`)
- **Struct Definition**: `kargu-connection-snapshot` defines immutable slots:
  - `id`: unique UUID identifier (`conn-<uuid>`)
  - `provider`: provider name string
  - `model`: model identifier
  - `endpoint`: validated HTTP/HTTPS URL
  - `wire-format`: protocol wire format symbol (e.g., `:openai`, `:anthropic`)
  - `capabilities`: plist of provider capabilities (tools, streaming, reasoning)
  - `config-revision`: monotonic integer revision at time of snapshot resolution
  - `credential-scope`: opaque struct `kargu-credential-scope`
  - `created-at`: float timestamp
- **Credential Scope & Zeroing**:
  - `kargu-credential-scope` holds the raw secret string in an unexported slot.
  - `kargu-credential-scope-secret` retrieves the secret, erroring if already wiped.
  - `kargu-credential-scope-wipe` clears memory using `clear-string` and sets internal reference to nil, preventing subsequent secret retrieval.
- **Redaction**: `kargu-connection-redacted-summary` returns a safe plist containing provider, model, endpoint, capabilities, and config revision, strictly omitting credentials for logging and UI display.
- **Asynchronous Resolution (`kargu-connection-resolve-async`)**:
  - Validates endpoint format (must begin with `http://` or `https://`).
  - Resolves keyless providers immediately with an empty credential scope without spawning subprocesses.
  - Resolves direct in-memory API keys immediately without subprocess overhead.
  - For disk/auth-sources, delegates to `kargu-config-worker-resolve`.
  - **Stale Discard**: Captures `(kargu-config-revision)` and session ID at invocation time. When the worker finishes, if the revision or session changed, the result is safely discarded with `:stale-discard`.

### 3.3 Configuration Monotonic Revision (`kargu/config/schema.el`)
- Implemented `kargu-config-revision` and `kargu-config-bump-revision`.
- Incremented monotonically on every successful TOML configuration reload and every interactive provider switch (`kargu-set-provider`).

---

## 4. Test Verification Suite (`tests/test-connection-snapshot.el`)

11 ERT tests implemented and verified:
1. `kargu-connection-snapshot-immutable-fields-test`: Verifies all snapshot fields are populated, typed, and read-only.
2. `kargu-connection-snapshot-secret-and-wipe-lifecycle-test`: Verifies credential retrieval and `clear-string` memory wiping.
3. `kargu-connection-redacted-summary-zero-secret-leakage-test`: Verifies redacted summary omits secrets.
4. `kargu-connection-callable-secret-never-called-on-ui-thread-test`: Verifies that callable `:secret` functions are never invoked synchronously on the UI thread and return `:auth-unavailable`.
5. `kargu-connection-keyless-offline-mode-test`: Verifies instant resolution for keyless/offline providers.
6. `kargu-connection-worker-never-passes-secrets-in-argv-test`: Verifies process `argv` contains zero secrets.
7. `kargu-connection-timeout-terminates-cleanly-test`: Verifies timeout cleans up processes and returns `:timeout`.
8. `kargu-connection-cancellation-cleans-up-worker-test`: Verifies cancellation terminates child processes with zero orphan processes.
9. `kargu-connection-invalid-endpoint-rejected-test`: Verifies malformed endpoints are rejected with `:invalid-endpoint`.
10. `kargu-connection-stale-discard-on-config-revision-test`: Verifies results arriving after config revision change are discarded with `:stale-discard`.
11. `kargu-connection-retry-preserves-snapshot-test`: Verifies retry mechanisms reuse the identical connection snapshot across request attempts.

### Complete ERT Test Execution:
```
Running 11 tests (selector 't')
   passed   1/11  kargu-connection-callable-secret-never-called-on-ui-thread-test (0.000689 sec)
   passed   2/11  kargu-connection-cancellation-cleans-up-worker-test (0.000343 sec)
   passed   3/11  kargu-connection-invalid-endpoint-rejected-test (0.000197 sec)
   passed   4/11  kargu-connection-keyless-offline-mode-test (0.000232 sec)
   passed   5/11  kargu-connection-redacted-summary-zero-secret-leakage-test (0.000154 sec)
   passed   6/11  kargu-connection-retry-preserves-snapshot-test (0.000121 sec)
   passed   7/11  kargu-connection-snapshot-immutable-fields-test (0.000176 sec)
   passed   8/11  kargu-connection-snapshot-secret-and-wipe-lifecycle-test (0.000120 sec)
   passed   9/11  kargu-connection-stale-discard-on-config-revision-test (0.000309 sec)
   passed  10/11  kargu-connection-timeout-terminates-cleanly-test (0.100568 sec)
   passed  11/11  kargu-connection-worker-never-passes-secrets-in-argv-test (0.000439 sec)

Ran 11 tests, 11 results as expected, 0 unexpected (0.103613 sec)
```

Additionally:
- `tests/test-config.el`: 11 / 11 passed
- `tests/test-providers.el`: 19 / 19 passed

---

## 5. Formal TLA+ Verification

- **Modules Created**:
  - `proof/KarguConnection.tla`: Formal TLA+ specification modeling session focus, monotonic config revisions, endpoint changes, asynchronous worker resolution, immediate cancellation, stale result discard, request start and retry binding, and credential scope wiping.
  - `proof/ConnectionMC.tla`: Model checking wrapper module.
  - `proof/ConnectionMC.cfg`: TLC model checker configuration file.
  - `proof/run_tlc.sh`: Added `--connection` flag.
- **Invariants Checked**:
  1. `TypeOK`: All variables stay within defined domains.
  2. `Safety_StaleDiscard`: A snapshot is never accepted or installed if worker resolution completed with an outdated revision, session, or endpoint.
  3. `Safety_RetryPreservesSnapshot`: In-flight requests maintain their bound snapshot across all retry attempts.
  4. `Safety_NoOrphanWorker`: External worker processes are active if and only if resolution is in progress (`worker_alive <=> phase = "resolving"`).
  5. `Safety_WipedCannotLeak`: No active request can ever execute with a wiped credential scope.
- **TLC Model Checker Results**:
  ```
  === TLC on Kargu: exhaustive connection-snapshot scan ===
  Specification: ConnectionMC.tla (KarguConnection)
  TLC Binary:    /nix/store/2gfqp5bphf7kdy2p6nb4crb8q8x7jccb-tlaplus-1.7.4/bin/tlc
  ---------------------------------------------------------------
  Model checking completed. No error has been found.
  446212 states generated, 77292 distinct states found, 0 states left on queue.
  The depth of the complete state graph search is 19.
  Finished in 00s
  TLC finished without error (exhaustive connection-snapshot scan).
  ```

---

## 6. Code Quality & Standards Compliance

1. **Byte Compilation**:
   Compiled with `(setq byte-compile-error-on-warn t)`. Zero warnings produced across:
   - `kargu/config/schema.el`
   - `kargu/config/toml.el`
   - `kargu/config/worker.el`
   - `kargu/config/key.el`
   - `kargu/config/connection.el`
   - `kargu/config.el`
   - `kargu/providers/registry.el`
   - `tests/test-connection-snapshot.el`
   - `tests/test-config.el`
   - `tests/test-providers.el`
2. **Checkdoc**:
   Evaluated with `checkdoc-current-buffer`. Zero warnings across all files.
3. **Artifact Cleanup**:
   Zero `.elc` files remain in the repository.
4. **Git Hygiene**:
   Strict adherence to the Package C write allowlist. No unrelated files modified or touched.
