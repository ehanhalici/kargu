# Hard Handoff Report: Wave 3 Package H Exploration
**Owned View, Selection, Catalog & Plan Services**

- **Agent**: `explorer_wave3_H`
- **Recipient**: `246e42bd-e1b7-4f73-8026-d90704dd17ec` (Project Orchestrator / Sentinel)
- **Role Target**: `worker_wave3_H`
- **Working Directory**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_H`
- **Date**: 2026-10-22
- **Status**: Complete Analysis & Implementation Blueprint Delivered (PASS)

---

## 1. Observation

### 1.1 Existing Implementation & Global Mutable State Audit
1. **Catalog & Metadata State**:
   - `kargu/api/catalog.el`:
     - Line 35: `(defvar kargu--catalog-generations (make-hash-table :test #'equal))`
     - Line 43: `(defvar kargu--live-models-cache (make-hash-table :test 'equal))`
     - Line 342: `(defvar kargu--tools-refused (make-hash-table :test #'equal))`
     - Line 586: `(defvar kargu--models-prefetched (make-hash-table :test #'equal))`
     These top-level mutable hash tables violate ARCH-12 (No Global Mutable State).
   - `kargu/models/store.el`:
     - Line 23: `(defvar kargu--model-metadata-table (make-hash-table :test #'equal))`
     `kargu-model-store-get`, `kargu-model-store-put`, `kargu-model-store-retain`, `kargu-model-store-set-property` update metadata without tracking a monotonic catalog/metadata revision counter.
   - `kargu/config/connection.el`:
     - Lines 123-132: `(defun kargu-connection--default-capabilities (provider) ...)` only extracts provider-level wire and effort capabilities. It omits model-specific capabilities (`supports_tools`, `supports_reasoning`, `context_window`, `max_output`) and catalog revision, leaving active runs vulnerable to mid-flight metadata mutation.

2. **Synchronous Chat Streaming & Unbounded Rendering**:
   - `kargu/chat/stream.el`:
     - Line 76: `(defun kargu-chat--on-delta (text &optional kind) (let ((buffer (kargu-chat-output-buffer))) ... (kargu-chat--stream-delta text kind)))`
     - Inserts every streaming delta synchronously onto the UI thread, causing high GC pressure and window recalculation loops during fast SSE bursts.
     - Line 15: `(defvar kargu--loop-run)` — reads global loop run reference directly.
   - `kargu/chat/transcript.el`:
     - Lines 55-62: `(defun kargu-chat-output-buffer () ... (kargu-chat-find-buffer))`
     - Falls back to scanning `(buffer-list)` for project buffers, risking cross-project routing on delayed events.

3. **Global Confirmation Scoping**:
   - `kargu/ui/confirm.el`:
     - Line 41: `(defvar kargu-confirm--pending nil)` — holds all confirmation prompts across all open buffers and sessions in a single global list.
     - Line 231: `(defun kargu-confirm-dismiss-all () ...)` settles every confirmation in every buffer without scoping.
     - Lines 93-98: `(defun kargu-confirm--resolve-chat-buffer ...)` falls back to global buffer name `*kargu-chat*`.

4. **Plan Dispatch Call Chain**:
   - `kargu/chat/plan.el`:
     - Line 80: calls `(kargu-chat-prompt ...)` rather than acquiring an application claim (`kargu-application-claim`) from Package A coordinator (`kargu/application/coordinator.el`).
     - Line 20: `(declare-function kargu-loop-running-p "kargu/loop" ())` — depends on loop internal state predicate instead of application coordinator status.

### 1.2 Programmatic Verification & Formal Proof Audit
1. **Existing Package H Test Suite**:
   Executed batch ERT test suite covering chat, selection, models store, metadata, confirm, plan, plan-async, and attach:
   `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'kargu) (require 'ert) (load \"tests/test-helpers\") ...)" -f ert-run-tests-batch-and-exit`
   **Result**: `Ran 142 tests, 142 results as expected, 0 unexpected (0.525005 sec)`.
2. **TLA+ / TLC Model Checking**:
   - `proof/KarguSelection.tla`:
     Command: `bash proof/run_tlc.sh --selection`
     **Result**: 3,690,151 states generated, 640,440 distinct states found, 0 errors, complete in 4s.
   - `proof/KarguPlan.tla`:
     Command: `bash proof/run_tlc.sh --plan`
     **Result**: 257,073 states generated, 72,313 distinct states found, 0 errors, complete in 1s.

---

## 2. Logic Chain

1. **State Isolation**: Because `kargu--catalog-generations`, `kargu--live-models-cache`, `kargu--tools-refused`, and `kargu-confirm--pending` are global mutable variables (Obs 1.1), concurrent or sequential multi-session operations can leak state or collide across projects. Moving them into an explicit `kargu-catalog-service` struct and scoped confirmation handles restores full ownership and isolation (ARCH-12).
2. **Snapshot Immutability**: Under Contract 4, connection snapshots are immutable records. Because `kargu-connection--default-capabilities` omitted model-level metadata and revision tracking (Obs 1.1), consumers could re-read mutable metadata during an active run. Capturing `:tools`, `:stream`, `:reasoning`, `:context-window`, `:max-output`, and `:catalog-revision` in `kargu-connection-snapshot` guarantees that active runs never inspect mutable store state.
3. **UI Responsiveness & Backpressure**: Because `kargu-chat--on-delta` synchronously inserts every delta into the buffer (Obs 1.2), high-frequency streaming starves the Emacs event loop. Introducing a bounded coalescing queue (`kargu-chat--render-queue` with a 64-chunk coalesce limit and timer drain) decouples network intake from text rendering and guarantees that `[Stop]` / `C-c C-k` remains immediately responsive at all times.
4. **Application Port Dispatch**: Because `kargu-chat-plan--dispatch` invoked chat UI functions instead of the application coordinator (Obs 1.4), execution claims were not bound to the coordinator's single-active-run token (Contract 1). Funneling plan dispatch through `kargu-application-claim` enforces the single-active-run invariant and enables clean rollback if preparation is cancelled.
5. **Model Invariants Preserved**: Because `KarguSelection.tla` and `KarguPlan.tla` passed exhaustive state space searches without violations (Obs 1.2), the modeled invariants (`Safety_OwnedAdmission`, `Safety_DiscardedCannotApply`, `Safety_FrozenSettings`, `Safety_OwnedDispatch`, `Safety_NoResurrectedDecisions`, `Safety_OneClaimPerOwner`) are mathematically sound and must be strictly preserved by Worker H's implementation.

---

## 3. Caveats

1. **Layout Experiment Out of Scope**: Split-buffer and header-line prompt layout experiments (ARCH-06) are explicitly excluded from this package. Existing buffer markers (`kargu-chat--output-marker`, `kargu-chat--prompt-marker`) and UX buttons must be preserved verbatim.
2. **Headless Execution Compatibility**: When running headlessly (no display/interactive UI), confirmation requests must immediately deliver `default-action` (`:reject`, `:stop`, `:cancel`) per Contract 7 without enqueuing or allocating window resources.
3. **Backward Compatibility Whitelist**: Whitelist existing function signatures (`kargu-model-supports-tools-p`, `kargu-model-reasoning-efforts`, `kargu-api-list-models`, `kargu-ui-confirm`) so existing tests and external callers remain fully functional while delegating to the new service layer.

---

## 4. Conclusion

The architecture for Wave 3 Package H is completely scoped, verified, and mapped out in detail.
Worker H can proceed directly with implementation following the 4-step sequence outlined in:
`/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_H/package_H_report.md`

### Implementation Checklist for Worker H:
- [ ] Migrate catalog generations, cache, and refusal tables to explicit `kargu-catalog-service` struct in `kargu/api/catalog.el` and `kargu/providers/catalog.el`.
- [ ] Bind model capability revision to `kargu-connection-snapshot` in `kargu/config/connection.el`.
- [ ] Decouple selection state from global buffer lookups; implement bounded coalesced stream queue in `kargu/chat/stream.el`.
- [ ] Scope pending confirmations by buffer/job handle in `kargu/ui/confirm.el`.
- [ ] Connect plan dispatch to `kargu-application-claim` in `kargu/chat/plan.el` and `kargu/plan/dispatch.el`.
- [ ] Add `tests/test-view-lifetime.el` covering the 7 designated lifetime and isolation test cases.
- [ ] Verify 100% passing ERT test suite, clean byte-compilation (`byte-compile-error-on-warn t`), and exhaustive TLC runs.

---

## 5. Verification Method

To independently verify this exploration and validate Worker H's implementation:

1. **Run Full Existing Test Suite**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'kargu) (require 'ert) (dolist (f '(\"tests/test-chat\" \"tests/test-chat-state\" \"tests/test-selection\" \"tests/test-model-store\" \"tests/test-metadata\" \"tests/test-dynamic-models\" \"tests/test-confirm\" \"tests/test-plan\" \"tests/test-plan-async\" \"tests/test-attach\")) (load f)))" -f ert-run-tests-batch-and-exit
   ```
2. **Run Exhaustive TLC Model Checking**:
   ```bash
   bash proof/run_tlc.sh --selection
   bash proof/run_tlc.sh --plan
   ```
3. **Verify Byte-Compilation Hygiene**:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (setq byte-compile-error-on-warn t) (dolist (f '(\"kargu/selection.el\" \"kargu/api/catalog.el\" \"kargu/models/store.el\" \"kargu/chat/stream.el\" \"kargu/chat/select.el\" \"kargu/ui/confirm.el\" \"kargu/plan/dispatch.el\" \"kargu/chat/plan.el\")) (byte-compile-file f)))"
   ```
   Ensure all `.elc` files generated during compilation checks are removed afterward:
   `find . -name "*.elc" -delete`
4. **Run New Lifetime Test Suite** (once created by Worker H):
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'kargu) (require 'ert) (load \"tests/test-view-lifetime\"))" -f ert-run-tests-batch-and-exit
   ```
