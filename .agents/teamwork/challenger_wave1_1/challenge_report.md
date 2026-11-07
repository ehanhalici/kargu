# Adversarial Empirical Challenge Report — Wave 1 (Packages A & B)

## Challenge Summary

- **Target Systems**: 
  - Package A: Application Coordinator (`kargu/application/coordinator.el`), Reset Ordering (`kargu/application/reset.el`), Run Budget Accounting (`kargu/application/budget.el`), and Async Scope (`kargu/async.el`).
  - Package B: Edit Service (`kargu/tools/diff/context.el`, `kargu/edit.el`), Diff / Patch Workspace (`kargu/tools/diff.el`), Frozen Approval Identity, and Git Worktree Safety.
- **Overall Risk Assessment**: **LOW**
- **Verdict**: **APPROVE**
- **Test Executable**: `tests/test-wave1-empirical-challenge.el` (9 comprehensive empirical challenge tests; 9 passed, 0 failed).
- **Formal Verification**: TLA+ specifications `BudgetMC`, `EditMC`, and `ModeMC` verified with TLC model checker; 0 errors found.

---

## Challenges & Invariant Stress-Tests

### Package A Challenges

#### 1. Budget Accounting Debit Gate
- **Assumption Challenged**: The run budget gate (`kargu-budget-debit`, `kargu-budget-record-tokens`, `kargu-budget-create`) enforces non-negative inputs, strictly positive limits, terminal exhaustion states, mid-execution deadline expirations, sealing immutability, and single-compaction turn limits.
- **Attack Scenarios Tested**:
  - *Negative/Zero limits*: Passed `max-requests 0`, `max-requests -5`, `max-tokens 0`, `max-tokens -50`, `timeout 0`, `timeout -2.5`, `max-compactions -1` to `kargu-budget-create`.
  - *Invalid debits*: Passed `:requests 0`, `:requests -1`, `:tokens -10` to `kargu-budget-debit`.
  - *Invalid token recordings*: Passed negative prompt and completion tokens `(-5, 10)` and `(10, -20)` to `kargu-budget-record-tokens`.
  - *Exhaustion*: Created budget with `max-requests 2`, exhausted it, and verified subsequent debits are denied and `kargu-budget-live-p` returns nil.
  - *Token exhaustion*: Created budget with `max-tokens 100`, debited beyond cap, and verified `:exhausted-tokens` status and subsequent debit denial.
  - *Sealing*: Called `kargu-budget-seal`, verified transition to `:sealed`, verified subsequent debits fail with `(:reason :sealed)`, and verified that sealing an already exhausted budget preserves the specific exhaustion reason (`:exhausted-requests`).
  - *Mid-execution deadline*: Created budget with 100ms timeout, executed initial valid debit, slept 150ms, executed second debit. Verified second debit was rejected with `:exhausted-deadline`.
  - *Single compaction bound*: Created budget with default `max-compactions 1`, executed first compaction turn (succeeded), executed second compaction turn (rejected with `:exhausted-compactions`). Attempted third turn (rejected).
- **Blast Radius If Broken**: Agent runs could loop indefinitely, overrun token/cost budgets, leak turns past deadlines, or perform infinite context compactions.
- **Empirical Finding**: **ROBUST**. All boundary constraints fail closed with typed `(kargu-err ... :budget-exhausted)` results or signal contract assertion errors upon illegal inputs.

#### 2. Async Task Ownership & Hierarchical Scope
- **Assumption Challenged**: Parent-child async tasks form a strict ownership hierarchy where cancelling a parent cancels all descendants recursively, executes all cleanup thunks in LIFO order, and never cancels unrelated siblings or tasks under other owners.
- **Attack Scenario Tested**:
  - Spawned root parent `P` (owner "owner-1").
  - Spawned children `C1` and `C2` under `P` (owner "owner-1").
  - Spawned grandchild `GC1` under `C1` (owner "owner-1").
  - Spawned unrelated sibling `S_diff` (owner "owner-2", no parent).
  - Spawned parentless sibling `S_same` (owner "owner-1", no parent).
  - Attached cleanup thunks to each task recording execution order.
  - Executed `(kargu-async-cancel P)`.
- **Observations**:
  - `P`, `C1`, `C2`, `GC1` all transitioned to `:cancelled` and were deregistered from `kargu-async--pending`.
  - Cleanups for `P`, `C1`, `C2`, `GC1` executed cleanly.
  - `S_diff` (under owner-2) remained in state `:pending` in `kargu-async--pending` and its cleanup did not execute.
  - `S_same` (under owner-1 without parent) remained in state `:pending` and its cleanup did not execute.
- **Blast Radius If Broken**: Resource leaks, hanging timers, orphaned background child tasks, or accidental cancellation of tasks belonging to concurrent agent runs.
- **Empirical Finding**: **ROBUST**. Structured cancellation tree functions without leaking tasks or cancelling non-descendants.

#### 3. Application Reset Ordering & Foreign Run Isolation
- **Assumption Challenged**: `kargu-session-reset` ordered sequence resets only the matching application claim and does not cancel or clobber foreign runs on the coordinator.
- **Attack Scenario Tested**:
  - Application coordinator `app` acquired an active claim with `run-id "run-foreign-99"` and `session-id "sess-foreign-99"`.
  - In a temporary buffer with local session context `sess-local`, `kargu-session-reset` was invoked.
  - Verified `app` maintained `active-run "run-foreign-99"` and status `:running`; foreign claim remained active.
  - Switched to session context matching `"sess-foreign-99"` and invoked `kargu-session-reset`.
  - Verified matching claim was released and `app` transitioned to `:idle`.
- **Blast Radius If Broken**: Multiple buffers/views running in Emacs could accidentally abort each other's agent runs during buffer resets.
- **Empirical Finding**: **ROBUST**. Coordinator resets are strictly scoped to the owner session.

---

### Package B Challenges

#### 4. Edit Service Isolation (Concurrent Same & Different Files)
- **Assumption Challenged**: Multiple `kargu-edit-service` instances can operate concurrently on the same repository without contaminating each other's snapshot, change, review, or plan tables.
- **Attack Scenario Tested**:
  - Instantiated `svc1` and `svc2` over a git repository containing `fileA.txt`, `fileB.txt`, and `fileC.txt`.
  - `svc1` edited `fileA.txt` and `fileB.txt`.
  - `svc2` edited `fileB.txt` and `fileC.txt`.
  - Verified snapshot tables: `svc1` contained `fileA` and `fileB` only; `svc2` contained `fileB` and `fileC` only.
  - Verified snapshot contents on `fileB.txt`: `svc1` recorded initial disk content; `svc2` recorded content after `svc1`'s modification.
  - Verified change tracking tables: strictly disjoint.
  - Executed rollback on `svc2` for `fileC`: restored `fileC` to initial state without affecting `svc1`'s edits to `fileA` or `fileB`.
- **Blast Radius If Broken**: Concurrent edits would cross-contaminate snapshots, leading to corrupt rollbacks or stale file states.
- **Empirical Finding**: **ROBUST**. Tables are strictly bound to service instances.

#### 5. Frozen Approval Identity & Conflict Errors
- **Assumption Challenged**: An edit plan captured with environment revision R cannot be applied if the underlying document, policy revision, or session changes before execution (ARCH-03, ARCH-04).
- **Attack Scenarios Tested**:
  - *Policy Revision Mismatch*: Captured plan with policy revision 1, updated service policy revision to 2. Submission returned `(kargu-err "Policy revision mismatch; edit plan invalidated" :policy-conflict)`.
  - *Unsaved Buffer Modifications*: Captured plan, modified visiting buffer without saving. Submission returned `(kargu-err "Buffer ... has unsaved modifications" :conflict)`.
  - *External Disk Modification*: Captured plan, modified file externally on disk. Submission returned `(kargu-err "Document revision changed..." :conflict)`.
  - *Session Mismatch*: Captured plan under session-alpha, submitted under session-beta. Submission returned `(kargu-err "Session mismatch; edit plan invalidated" :session-conflict)`.
- **Blast Radius If Broken**: Stale model approvals applied over concurrent user edits or changed policy configurations, causing silent code corruption or unauthorized edits.
- **Empirical Finding**: **ROBUST**. All conflict paths fail closed and return typed errors with descriptive diagnostic messages.

#### 6. Closed Edit Service Rejection
- **Assumption Challenged**: Closing an edit service immediately cleans up all owned resources and prevents any further plan submissions.
- **Attack Scenario Tested**:
  - Registered buffer, timer, and temp directory with `svc`.
  - Closed `svc` via `kargu-edit-service-close`.
  - Verified `kargu-edit-service-closed-p` returned t.
  - Verified buffer was killed and temp directory deleted.
  - Submitted synchronous plan: returned `(kargu-err "Edit service is closed" :service-closed)`.
  - Submitted asynchronous plan: callback received `(kargu-err "Edit service is closed" :service-closed)`.
- **Blast Radius If Broken**: Ghost services processing edits after user or session termination.
- **Empirical Finding**: **ROBUST**. Immediate rejection with typed `:service-closed` result.

#### 7. Git Worktree Safety
- **Assumption Challenged**: Patch workspace operations in `kargu/tools/diff.el` (`kargu-diff-apply-patch`, block replace, write proposal) NEVER modify, stage into, or corrupt the user's actual Git index (`git status --short`, `git diff --cached`).
- **Attack Scenario Tested**:
  - In a git repository, staged `staged.txt` (`git add staged.txt`).
  - Modified `working.txt` in the working tree without staging.
  - Recorded exact `git diff --cached` and `git status --short` before operations.
  - Executed `kargu-diff-apply-patch` with multi-file patch (adding new file, modifying existing file).
  - Executed block replacement plan on target file.
  - Executed full write proposal on another file.
  - Verified `git diff --cached` after operations: byte-for-byte identical to before.
  - Verified `git status --short` staged column: only `staged.txt` remained staged; zero other files had staged changes.
  - Verified no `.kargu.patch`, `.git/index.lock`, or temp files leaked into the repository.
- **Blast Radius If Broken**: The agent could corrupt user commits, stage unreviewed changes into git index, or leave lock files blocking user git workflows.
- **Empirical Finding**: **ROBUST**. Isolated patch workspaces execute via isolated temporary worktrees and never stage into user's git index.

---

## Stress Test Results

| Test Scenario | Module | Expected Behavior | Actual Behavior | Result |
|---|---|---|---|---|
| `kargu-challenge-budget-negative-and-zero-limits-test` | `kargu/application/budget.el` | Contract assertion error on <=0 limits / debits | Errors raised and caught as expected | **PASS** |
| `kargu-challenge-budget-exhaustion-and-sealing-test` | `kargu/application/budget.el` | Denies debits past limits; seal denies with :sealed | Typed :budget-exhausted errors with reasons | **PASS** |
| `kargu-challenge-budget-deadline-and-single-compaction-test` | `kargu/application/budget.el` | Rejects mid-run deadline expiry; rejects 2nd compaction | Status transitions to :exhausted-deadline and :exhausted-compactions | **PASS** |
| `kargu-challenge-async-hierarchical-cancellation-and-isolation-test` | `kargu/async.el` | Recursive cancel on parent; siblings preserved | Tree cancelled, cleanups run, siblings pending | **PASS** |
| `kargu-challenge-application-reset-ordering-foreign-run-test` | `kargu/application/reset.el` | Foreign claim/run untouched by non-owner reset | Foreign claim preserved; owner reset releases claim | **PASS** |
| `kargu-challenge-edit-service-concurrent-isolation-test` | `kargu/tools/diff/context.el` | Disjoint snapshot/change/plan tables per service | Tables isolated; rollback operates strictly on own files | **PASS** |
| `kargu-challenge-frozen-approval-identity-conflicts-test` | `kargu/tools/diff/context.el` | Fails with :policy-conflict, :conflict, :session-conflict | All 4 conflict vectors reject with expected typed errors | **PASS** |
| `kargu-challenge-closed-edit-service-test` | `kargu/tools/diff/context.el` | Rejects submissions with :service-closed | Synchronous and asynchronous reject with :service-closed | **PASS** |
| `kargu-challenge-git-worktree-safety-test` | `kargu/tools/diff.el` | User git index untouched; git diff --cached identical | Byte-for-byte identical diff; no leaked lock/patch files | **PASS** |
| TLC Model Check: `BudgetMC.tla` | `proof/KarguBudget.tla` | Model checking passes without deadlock/invariant failure | 1591 states generated, 432 distinct states, 0 errors | **PASS** |
| TLC Model Check: `EditMC.tla` | `proof/KarguEdit.tla` | Model checking passes without deadlock/invariant failure | 1849 states generated, 560 distinct states, 0 errors | **PASS** |
| TLC Model Check: `ModeMC.tla` | `proof/KarguMode.tla` | Model checking passes without deadlock/invariant failure | 20179 states generated, 5958 distinct states, 0 errors | **PASS** |
| Byte-compilation clean check | All Package A & B `.el` files | Zero warnings and zero errors with byte-compile-error-on-warn | 10 targets compiled cleanly with 0 warnings | **PASS** |

---

## Unchallenged Areas

- **Wave 2+ Modules**: Tool execution gate (Package D), Transport client/circuit breaker (Package E), Process runner (Package F) are part of later waves and were not within Wave 1 Empirical Challenge scope.
- **Remote TRAMP Worktree Operations**: Remote TRAMP filesystems reject `kargu-file-current-revision` (returns nil by design); interactive TRAMP diffing was not tested.

---

## Conclusion & Verdict

**VERDICT: APPROVE**

Package A and Package B implementations fully satisfy Contracts 1, 2, 3, and 6 under rigorous adversarial conditions. No architectural regressions, invariant violations, or state leaks were discovered.
