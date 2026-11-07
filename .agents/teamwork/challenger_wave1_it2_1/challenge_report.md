# Wave 1 Iteration 2 Adversarial Challenge Report

## Challenge Summary

**Overall risk assessment**: LOW

All adversarial hypotheses and empirical stress tests have completed with zero defects found. The remediation implemented by `worker_wave1_remediation_1` correctly resolved all 26 regressions without weakening architectural invariants or leaking resources.

---

## Challenges

### [Low] Challenge 1: State Machine Transition Table Permissiveness & Legacy Accommodation

- **Assumption challenged**: Expanding `kargu-application--transition-table` and adding the legacy unowned accommodation in `kargu-application-transition` could potentially allow illegal transitions to slip through undetected on claimed application runs or explicit application contexts.
- **Attack scenario**:
  1. Initialize an explicit application instance `(kargu-application-create :status :idle)` and attempt forbidden transitions: `:idle -> :streaming`, `:idle -> :executing-tool`, `:idle -> :done`, `:starting -> :done`, `:starting -> :streaming`.
  2. Claim an explicit application instance `(kargu-application-claim app ...)` and attempt forbidden transitions: `:running -> :starting`, `:streaming -> :requesting`, `:done -> :streaming`.
  3. Claim the default singleton coordinator `(kargu-application-claim nil ...)` and attempt forbidden transitions: `:running -> :starting`, `:idle -> :streaming`, `:starting -> :done`.
- **Blast radius**: If the transition table were overly permissive, invalid asynchronous states could corrupt execution workflows or violate ARCH-11.
- **Result**: PASS. All illegal transitions on explicit application instances and claimed instances strictly signal `error("Kargu: invalid application status transition from %S to %S" ...)`. The legacy bypass clause `(and (null app) (null (kargu-application-active-claim-token target)) ...)` is completely disabled whenever `app` is non-nil or whenever a claim token is active on the default coordinator.

### [Low] Challenge 2: Async Task Replacement & Repeating Timer Release

- **Assumption challenged**: Replacing a running owner object (`kargu--loop-run` or application run-id claim) could leak repeating poll timers or allow delayed callbacks to deliver stale results to obsolete runs in Dape and LSP integrations.
- **Attack scenario**:
  1. Start an asynchronous task with a cons-cell `kargu--loop-run` owner and an attached timer/cleanup function. Replace `kargu--loop-run` with a newly allocated cons cell (as happens on new loop runs in Dape/LSP).
  2. Verify that `(kargu-async-pending-p task)` immediately evaluates to `nil`.
  3. Invoke `(kargu-async-finish task "result")` on the obsolete task and verify that:
     - The callback is NOT executed.
     - The task state is set to `:cancelled`.
     - The timer is cancelled and cleared.
     - The registered cleanup function executes.
     - The task is removed from `kargu-async--pending`.
  4. Perform hierarchical cancellation across parent, child, and grandchild tasks to ensure clean recursive teardown while isolating unowned or differently owned siblings.
- **Blast radius**: If replaced runs remained pending, timers would leak and late callbacks would fire against obsolete buffers or processes, causing flakes or race conditions.
- **Result**: PASS. `kargu-async-pending-p` uses pointer identity `(eq owner kargu--loop-run)` for cons-cell loop runs and exact string match against `(kargu-application-current-run)` for string run IDs. Replaced runs are immediately detected as dead, timers are cleanly cancelled, and no stale results are delivered.

---

## Stress Test Results

| Scenario | Expected Behavior | Actual Behavior | Result |
|---|---|---|---|
| Wave 1 Empirical Challenges (9 tests) | 9 passed, 0 failed | Total: 9, Passed: 9, Failed: 0 | PASS |
| Illegal transitions on unclaimed app (`:idle -> :streaming`, `:idle -> :executing-tool`, `:idle -> :done`) | Signal invalid transition error | Signaled `error("Kargu: invalid application status transition...")` | PASS |
| Illegal transitions on unclaimed app (`:starting -> :done`, `:starting -> :streaming`) | Signal invalid transition error | Signaled `error("Kargu: invalid application status transition...")` | PASS |
| Illegal transitions on claimed app (`:running -> :starting`, `:done -> :streaming`) | Signal invalid transition error | Signaled `error("Kargu: invalid application status transition...")` | PASS |
| Illegal transitions on claimed default coordinator (`:idle -> :streaming`, `:starting -> :done`) | Signal invalid transition error | Signaled `error("Kargu: invalid application status transition...")` | PASS |
| Cons-cell loop run replacement (`kargu--loop-run`) | Obsolete task detected, delivery blocked, timer cancelled, cleanup fired | Task state `:cancelled`, 0 delivered, timer nil, cleanup executed | PASS |
| Default coordinator run replacement (`run-alpha` -> `run-beta`) | Obsolete task detected, delivery blocked, task removed from pending | Task state `:cancelled`, 0 delivered, removed from pending | PASS |
| Nested task hierarchy cancellation under replaced run | Parent and all descendants cancelled, cleanups fired, siblings isolated | All descendants `:cancelled`, cleanups run, siblings unaffected | PASS |
| `test-application-context.el` (12 tests) | 12 passed, 0 failed | Ran 12 tests, 12 passed, 0 unexpected | PASS |
| `test-lsp-settle.el` (14 tests) | 14 passed, 0 failed | Ran 14 tests, 14 passed, 0 unexpected | PASS |
| `test-dape-execution.el` (13 tests) | 13 passed, 0 failed | Ran 13 tests, 13 passed, 0 unexpected | PASS |
| `test-dape-compile.el` (37 tests) | 37 passed, 0 failed | Ran 37 tests, 37 passed, 0 unexpected | PASS |
| `test-async.el` (6 tests) | 6 passed, 0 failed | Ran 6 tests, 6 passed, 0 unexpected | PASS |
| Full Repository ERT Test Suite (997 tests) | 997 passed, 0 unexpected | Ran 997 tests, 997 passed, 0 unexpected | PASS |
| Byte-compilation with `byte-compile-error-on-warn t` | 0 errors, 0 warnings | 0 errors, 0 warnings | PASS |
| Stray `.elc` check (`find . -name "*.elc"`) | 0 files found | 0 files found | PASS |
| Git worktree safety (`git diff --cached`) | User git index untouched | Verified unchanged by test-wave1-empirical-challenge | PASS |

---

## Unchallenged Areas

- **Wave 2 through Wave 5 packages**: Out of scope for Wave 1 Iteration 2 challenge. These will be challenged in their respective wave milestones.
