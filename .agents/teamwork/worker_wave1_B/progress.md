# Progress — worker_wave1_B

Last visited: 2026-10-21T22:27:15Z
Status: Implementation and verification complete

## Completed Tasks
1. Created `kargu/tools/diff/context.el`:
   - `kargu-edit-service` struct owning snapshot, change, review, active plan tables and temp resources.
   - `kargu-edit-plan` and `kargu-edit-outcome` structs.
   - Resource management: register/unregister for temp dirs, processes, timers, buffers.
   - `kargu-edit-service-close` cleaning only owned resources.
   - Service-aware table accessors with dynamic fallback to default service.
   - `kargu-diff-submit-plan` with policy revision, session mismatch, and document revision validation.
2. Modified `kargu/edit.el`:
   - Added `kargu-edit-submit-plan` fallback returning `(kargu-err ... :unavailable)`.
3. Modified `kargu/tools/diff/track.el`:
   - Service-aware snapshot, change, rollback, stats, and run-modified files operations.
4. Modified `kargu/tools/diff/stage.el`:
   - `service` and `policy-revision` in origin validation, shadow buffer registration, service commit recording.
5. Modified `kargu/tools/diff/review.el`:
   - Service-aware review sessions, timer registration on service, buffer unregistration on abort.
6. Modified `kargu/tools/diff.el`:
   - Register patch workspace temp-dir with service.
   - Track async git apply process on service.
   - Installed advice for `kargu-edit-submit-plan`.
   - Updated `kargu/tools/diff-unload-function`.
7. Created `tests/test-edit-service.el`:
   - 12 comprehensive ERT tests covering dual-service isolation, policy invalidation, session invalidation, revision changes, active close cleanup, git staged index safety, dirty buffer rejection, narrowing/point preservation, CRLF preservation, Unicode handling, and unified outcome structure.
8. Registered `test-edit-service` in `tests/run-tests.el`.
9. Updated TLA+ specifications (`proof/KarguEdit.tla`, `proof/EditMC.cfg`):
   - Added `policyStale` and `serviceClosed` transitions and invariants `Safety_PolicyInvalidatedNoWrite` and `Safety_ClosedServiceNoOwnedWrites`.
   - Exhaustive TLC model check passed with 0 errors (1849 generated states, 560 distinct states).
10. Full verification passed:
    - 41/41 edit/diff/patch tests passed.
    - Byte-compile with `byte-compile-error-on-warn t` passed with 0 warnings.
    - Checkdoc passed with 0 warnings across all modified and new files.
    - 0 `.elc` files left in repo.
