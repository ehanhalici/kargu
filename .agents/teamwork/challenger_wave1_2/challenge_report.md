# Empirical Challenge Report: Wave 1 Package C & Formal Models

**Author**: `challenger_wave1_2` (Wave 1 Empirical Challenger 2)  
**Date**: 2026-10-21  
**Scope**: Package C (Async Credential Discovery, Config, Worker Lifecycle, Connection Snapshot) & Formal Models (`KarguBudget`, `KarguEdit`, `KarguConnection`, `KarguMode`)  
**Verdict**: **APPROVE** (Risk Level: LOW)

---

## 1. Executive Summary

We conducted adversarial testing, stress-testing, and formal verification of Package C and all Wave 1 TLA+ specifications.
- **Formal Verification**: All 4 TLA+ specifications (`KarguBudget`, `KarguEdit`, `KarguConnection`, `KarguMode`) passed exhaustive TLC model checking with **0 errors** and exit status 0 across 469,831 generated states.
- **Package C Invariants**:
  1. `kargu-config-api-key-fast` completely avoids `auth-source-search` under mocked error conditions (no UI lockup / pinentry invocation).
  2. Synchronous credential resolution with a callable `:secret` strictly refuses to invoke the secret on the UI thread, returning `(kargu-err ... unavailable)`.
  3. `kargu-credential-scope-wipe` zeroes out underlying secret string buffers in place via `clear-string` (verified across ASCII and multibyte UTF-8 strings).
  4. Worker cancellation cleanly terminates child processes via `delete-process`, verifies `/proc/<pid>` disappearance, and prevents zombie/hanging processes.
- **Byte Compilation & ERT**: 100% clean byte-compilation on all Package C files with `byte-compile-error-on-warn t` (0 warnings). All 17 Package C ERT tests passed cleanly (0 errors, 0 failures).

---

## 2. Formal Verification Results (`proof/run_tlc.sh`)

| Specification | Model / Config | States Generated | Distinct States | Search Depth | Result |
|---|---|---|---|---|---|
| **KarguBudget** | `BudgetMC.tla` / `BudgetMC.cfg` | 1,591 | 432 | 11 | **PASSED (0 errors)** |
| **KarguEdit** | `EditMC.tla` / `EditMC.cfg` | 1,849 | 560 | 11 | **PASSED (0 errors)** |
| **KarguConnection** | `ConnectionMC.tla` / `ConnectionMC.cfg` | 446,212 | 77,292 | 19 | **PASSED (0 errors)** |
| **KarguMode** | `ModeMC.tla` / `ModeMC.cfg` | 20,179 | 5,958 | 16 | **PASSED (0 errors)** |

### Formal Model Highlights:
1. **`KarguConnection.tla`**: Exhaustively verified 446,212 states proving snapshot immutability, zero secret leakage to logs/argv, stale discard on config revision bumps, and secret wiping lifecycle.
2. **`KarguBudget.tla`**: Exhaustively verified 1,591 states checking monotonic request spending, debit gate refusal upon budget exhaustion, single compaction turn limit, and explicit unknown token tracking.
3. **`KarguEdit.tla`**: Verified 1,849 states checking atomic plan capture, revision conflict aborts upon out-of-band disk modification, safe rollback, and isolated diff staging.
4. **`KarguMode.tla`**: Verified 20,179 states checking single active run invariance per application instance, valid mode transitions, and session claim isolation.

---

## 3. Empirical Challenge & Stress Test Results

### Challenge 1: Fast API Key Resolution (`kargu-config-api-key-fast`)
- **Assumption Challenged**: Calling `kargu-config-api-key-fast` might fall through to `auth-source-search` or trigger interactive pinentry when no direct key is configured.
- **Attack Scenario**: Installed mock `auth-source-search` configured to throw `(error "FORBIDDEN: auth-source-search was called!")`. Tested both with a direct key present and with no direct key configured.
- **Empirical Observation**:
  - Direct key present: Returned direct key (`"sk-mocked-direct-key"`), `auth-source-search` was NOT called.
  - No direct key: Returned `nil`, `auth-source-search` was NOT called.
  - Positive control: `kargu-config-api-key` under the identical mock immediately threw the `FORBIDDEN` error, verifying the mock was active and would have caught any unauthorized leakage.
- **Verdict**: **PASSED**.

### Challenge 2: Synchronous Resolution of Callable Secrets (CONFIG-01)
- **Assumption Challenged**: Synchronous resolution (`kargu-config-resolve-api-key-result`) might accidentally evaluate a callable `:secret` function on the Emacs UI thread.
- **Attack Scenario**: Configured `auth-source-search` to return `:secret (lambda () (setq secret-invoked t) "secret-token")`.
- **Empirical Observation**:
  - `secret-invoked` remained `nil`. The function was never invoked.
  - Returned `#s(kargu-result-err "Callable secret for openai requires async resolution" unavailable nil)`.
- **Code Notation (Low)**: In `kargu/config/key.el` line 263, the error code returned is the symbol `'unavailable` rather than the keyword `:unavailable` (Contract 8 specification). Existing tests (`tests/test-connection-snapshot.el:152`) assert `'unavailable`. For complete strictness across contracts, normalizing to `:unavailable` is recommended during Wave 5 polish.
- **Verdict**: **PASSED**.

### Challenge 3: In-Place Secret Wiping (`kargu-credential-scope-wipe`)
- **Assumption Challenged**: Credential wiping might leave sensitive plaintext lingering in string memory, or fail to handle multibyte/Unicode characters.
- **Attack Scenario**:
  1. Created scope with secret `"super-secret-token-abcdef-9876543210"`. Executed `kargu-credential-scope-wipe`.
  2. Created scope with UTF-8 multibyte secret `"şeker-şifre-🔑-12345-ümlaut-äöü"`. Executed `kargu-credential-scope-wipe`.
- **Empirical Observation**:
  - For both ASCII and multibyte UTF-8 strings, every character byte was overwritten with byte `0` via `clear-string`.
  - `kargu-credential-scope-raw-secret` was set to `nil`.
  - `kargu-credential-scope-wiped-p` transitioned to `t`.
  - Subsequent calls to `kargu-credential-scope-wipe` safely returned `nil` (idempotent no-op).
- **Verdict**: **PASSED**.

### Challenge 4: Worker Process Cancellation & Zombie Prevention
- **Assumption Challenged**: Cancelling an asynchronous credential resolution might leave an orphaned background child process or zombie in the OS process table.
- **Attack Scenario**: Spawned background worker with an eval script simulating a slow lookup (`sleep-for 10`). Captured child process PID from `process-list` (PID 1155616, state live). Immediately executed `(kargu-async-cancel task)`.
- **Empirical Observation**:
  - Process was immediately signalled and deleted (`process-status` = `signal`, `process-live-p` = `nil`).
  - Checked `/proc/1155616`: File ceased to exist. Process was reaped and did not hang as a zombie (`Z`) in the OS process table.
  - Callback was never invoked with late result.
- **Verdict**: **PASSED**.

### Challenge 5: Adversarial Worker Output Flooding
- **Assumption Challenged**: A rogue worker outputting unbounded data might exhaust Emacs heap memory.
- **Attack Scenario**: Simulated worker outputting 70,000 bytes (exceeding `kargu-config-worker-max-bytes` = 65,536).
- **Empirical Observation**:
  - Filter detected output bound violation (`> bytes-received kargu-config-worker-max-bytes`).
  - Child process was terminated (`delete-process`), buffer erased and killed.
  - Task completed with `(kargu-err "Credential resolution worker exited with code 9 for flood-provider" :auth-unavailable nil)`.
- **Verdict**: **PASSED**.

### Challenge 6: Worker Crash / Non-Zero Exit
- **Assumption Challenged**: Worker crash with non-zero exit code might hang or cause unhandled exceptions.
- **Attack Scenario**: Simulated worker exiting with code 42 (`kill-emacs 42`).
- **Empirical Observation**:
  - Sentinel detected exit code 42.
  - Task completed cleanly with `(kargu-err "Credential resolution worker exited with code 42 for crash-provider" :auth-unavailable nil)`.
- **Verdict**: **PASSED**.

### Challenge 7: Stale Discard on Config Revision Bump
- **Assumption Challenged**: Late discovery results arriving after a configuration change might overwrite new configuration.
- **Attack Scenario**: Began async resolution, bumped config revision via `(kargu-config-bump-revision)`, then delivered late adapter result.
- **Empirical Observation**:
  - Late result was rejected; task completed with `(kargu-err "Connection or document changed" :stale-discard nil)`.
- **Verdict**: **PASSED**.

---

## 4. Byte-Compilation & ERT Verification

1. **Byte Compilation**:
   ```
   emacs -Q --batch -L . -L tests --eval '(progn (setq byte-compile-error-on-warn t) ...)'
   Byte compiling kargu/config.el...
   Byte compiling kargu/config/key.el...
   Byte compiling kargu/config/connection.el...
   Byte compiling kargu/config/worker.el...
   Byte compiling kargu/config/schema.el...
   Byte compiling kargu/config/toml.el...
   Byte compiling tests/test-config.el...
   Byte compiling tests/test-connection-snapshot.el...
   ALL PACKAGE C FILES BYTE-COMPILED CLEANLY WITH ZERO WARNINGS!
   ```
2. **ERT Suite**:
   - `test-connection-snapshot.el`: 11 / 11 passed (0 unexpected).
   - `test-config.el`: 6 / 6 passed (0 unexpected).
   - Total Package C tests: 17 passed, 0 failed.

---

## 5. Unchallenged Areas

- **Interactive Pinentry GUI Windows**: Testing physical OS pinentry window popping in an interactive X11/Wayland desktop session was mocked out since testing runs headless in batch Emacs. Noninteractive mode rejection was verified.
- **Downstream Packages (D, E, F, G, H, etc.)**: Beyond Wave 1 scope.

---

## 6. Final Verdict

**APPROVE**. Package C satisfies all architectural invariants, CONFIG-01, DEEP-14, and Contract 4 specifications. All four Wave 1 TLA+ formal specifications check cleanly without errors.
