# Wave 1 Package B Implementation Report: Single-Owner Edit Service & Approval Identity

## 1. Executive Summary
Wave 1 Package B has been fully implemented in strict adherence to:
- `parallel-plan.md` Section 4 (Package B)
- `architecture-contracts.md` Contract 3 (Edit Service Contract)
- Issues addressed: ARCH-03, ARCH-04, ARCH-08, ARCH-10, ARCH-15, ARCH-17, MOD-07, DEEP-10, DEEP-11, DEEP-15.

All modifications strictly adhered to the exclusive write allowlist:
- `kargu/edit.el`
- `kargu/tools/diff.el`
- `kargu/tools/diff/context.el` (new)
- `kargu/tools/diff/track.el`
- `kargu/tools/diff/stage.el`
- `kargu/tools/diff/review.el`
- `tests/test-edit-service.el` (new)
- `tests/run-tests.el` (registration only)
- `proof/KarguEdit.tla`, `proof/EditMC.cfg`

Files forbidden from modification (`skills.md`, `.gitignore`, other agents' spaces, Package A/C files) were completely untouched.

---

## 2. Architecture & Design Implementation

### 2.1 Single-Owner Edit Service Context (`kargu/tools/diff/context.el`)
- Defined `kargu-edit-service` struct holding:
  - `service-id`: unique string identifier.
  - `root`: project root directory.
  - `snapshots`, `changes`, `reviews`, `active-plans`: dedicated hash-tables per service instance.
  - `policy-revision`: integer generation counter for editing and approval policy.
  - `temp-dirs`, `processes`, `timers`, `buffers`: tracked temporary resources owned exclusively by this service.
  - `closed`: boolean flag tracking lifecycle state.
- Resource Lifecycle (`kargu-edit-service-close`):
  - Safely aborts only review sessions owned by the service, closing ediff controls without firing callbacks and killing shadow/base buffers.
  - Cancels tracked timers and processes (`kargu-process-cancel`).
  - Deletes tracked temporary directories.
  - Clears hash tables and marks service as closed.
  - Peer services operating concurrently on same or different paths remain completely isolated and intact.

### 2.2 Frozen Approval & Document Identity
- Defined `kargu-edit-plan` immutable struct capturing:
  - `plan-id`, `path`, `kind` (`:block`, `:symbol`, `:unified-diff`, `:write`), `proposed-content`.
  - `expected-revision`: `kargu-file-revision` capturing inode, device, size, mtime at capture time.
  - `policy-revision`: policy generation counter at capture time.
  - `session-id`, `run-id`, `app-id`: execution identity.
- Pre-apply Re-validation (`kargu-diff-submit-plan` / `kargu-edit-submit-plan`):
  - Step 1: Re-checks `policy-revision`. If service policy revision incremented or changed, rejects with `(kargu-err ... :policy-conflict)`.
  - Step 2: Re-checks session context. If active session differs from plan's `session-id`, rejects with `(kargu-err ... :session-conflict)`.
  - Step 3: Re-checks document revision on disk and visiting buffer. If visiting buffer is modified, rejects with `(kargu-err ... :conflict)`. If disk revision changed, rejects with `(kargu-err ... :conflict)`.

### 2.3 Unified Transaction Outcome (`kargu-edit-outcome`)
- Defined `kargu-edit-outcome` struct unifying block replacements, symbol edits, and Unified Diff patches:
  - `plan-id`, `path`, `status` (`:applied`, `:staged`, `:conflict`, `:partial`, `:unavailable`, `:rejected`, `:interrupted`, `:unchanged`, `:rolled-back`, `:error`).
  - `post-revision`: post-write `kargu-file-revision` capturing disk state after save hooks.
  - `hunks-applied`, `hunks-total`, `message`, `saved`, `hook-transformed`, `decided-content`, `snapshot`, `rollback-status`, `write-effects`.

### 2.4 Git Working Tree Protection
- Maintained isolated patch workspace:
  - Temporary workspace directory created with ephemeral `.git` structure (`HEAD`, `refs`, `objects`).
  - `git apply` executed with `--git-dir` and `--work-tree` pointing strictly to the isolated temp directory.
  - Never passes `--cached` and never mutates `.git/index`.
  - Staged git index in user repository remains 100% byte-for-byte identical before and after edits.
  - Async `git apply` processes and temp workspaces are registered on the edit service and cleanly unregistered upon completion or cancellation.

---

## 3. Formal Verification (TLA+)

- Specification: `proof/KarguEdit.tla`, `proof/EditMC.tla`, `proof/EditMC.cfg`.
- Extensions:
  - Added `policyStale` and `serviceClosed` variables.
  - Added `PolicyChange` and `CloseService` actions.
  - Updated `Prepare`, `Commit`, `Deliver` guards.
  - Verified safety invariants:
    - `TypeOK`
    - `Safety_ReviewBeforeWrite`
    - `Safety_PreserveForeign`
    - `Safety_Once`
    - `Safety_NoPrematureDelivery`
    - `Safety_PolicyInvalidatedNoWrite`: `(policyStale /\ writes = {}) => \A f \in Files : disk[f] # "owned"`
    - `Safety_ClosedServiceNoOwnedWrites`: `(serviceClosed /\ phase = "done") => \A f \in Files : disk[f] # "owned"`
- Model Check Result:
  - Command: `bash proof/run_tlc.sh --edit-transaction`
  - Result: 1849 states generated, 560 distinct states found, 0 errors, 0 deadlocks. PASS.

---

## 4. Test Suite (`tests/test-edit-service.el`)

12 comprehensive ERT tests covering all contract requirements:
1. `kargu-edit-service-two-services-different-paths-test`: Verifies two edit services modifying different files maintain disjoint snapshot and change tables; rollback on one does not touch the other.
2. `kargu-edit-service-two-services-same-path-isolation-test`: Verifies two services modifying the same file maintain disjoint histories; foreign writer conflict detection prevents corrupting intervening edits.
3. `kargu-edit-service-approval-invalidated-on-policy-change-test`: Verifies plan captured under policy revision 1 is rejected with `:policy-conflict` when policy revision bumps to 2.
4. `kargu-edit-service-approval-invalidated-on-session-change-test`: Verifies plan captured for session-A is rejected with `:session-conflict` under session-B.
5. `kargu-edit-service-approval-invalidated-on-doc-revision-change-test`: Verifies plan captured with revision R is rejected with `:conflict` when external edits modify the file before apply.
6. `kargu-edit-service-active-close-cleans-own-resources-test`: Verifies closing service 1 terminates its own buffers, temp dirs, and timers while peer service 2's resources remain live. Submitting to closed service yields `:service-closed`.
7. `kargu-edit-service-staged-git-index-unmodified-test`: Verifies user staged changes in `.git/index` are 100% preserved and untouched during edit service mutations.
8. `kargu-edit-service-dirty-buffer-rejected-test`: Verifies unsaved buffer modifications trigger `:conflict` rejection.
9. `kargu-edit-service-narrowed-buffer-preserved-test`: Verifies buffer narrowing restriction and point position are preserved across plan execution.
10. `kargu-edit-service-crlf-line-endings-preserved-test`: Verifies CRLF `\r\n` line endings are preserved on disk.
11. `kargu-edit-service-unicode-content-test`: Verifies Turkish multibyte UTF-8 characters and Unicode emoji are preserved without byte truncation.
12. `kargu-edit-service-unified-outcome-structure-test`: Verifies plan submission produces a valid `kargu-edit-outcome` struct with all required slots.

Test Execution Results:
- `tests/test-edit-service.el`: 12/12 PASSED.
- Combined `kargu-edit`, `kargu-patch`, `kargu-diff` suites: 41/41 PASSED (0 failures).

---

## 5. Quality & Compliance Attestation

1. **Byte-Compilation**:
   `emacs -Q --batch -L . --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile` on all modified/new files executed with 0 errors and 0 warnings.
2. **Leftover Artifacts**:
   `find . -name "*.elc"` confirmed 0 `.elc` files remaining in the repository.
3. **Checkdoc**:
   `checkdoc-current-buffer` executed in batch across all modified and new files: confirmed 0 warnings.
4. **Layout Compliance**:
   All new source code is in `kargu/tools/diff/context.el`, all new tests in `tests/test-edit-service.el`, and agent metadata strictly in `.agents/teamwork/worker_wave1_B/`.
