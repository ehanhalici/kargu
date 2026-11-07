# Kargu Codebase Survey Report: Baseline, Contracts, and Wave 0 Boundaries

**Survey Date:** 2026-10-21  
**Investigator:** `teamwork_preview_explorer_survey_1` (Survey Codebase Explorer)  
**Baseline Git Commit:** `262850b` (docs: define staged parallel agent ownership and acceptance plan)  
**Parent Commit:** `988dd96` (fix: finish isolated edit transactions and revision-bound verification)  
**Workspace:** `/home/emrehan/.emacs.local/kargu`  

---

## Executive Summary

1. **Current Code Baseline:**
   - 942/942 ERT tests pass cleanly with 0 failures and 0 errors across 65 test modules.
   - Formal verification tooling (`proof/run_tlc.sh`) is fully operational via `nix-shell` (tested `EditMC.tla`: 425 generated / 160 distinct states, depth 10, 0 errors).
   - Byte-compilation runs cleanly across the repository when modules are properly loaded with their dependencies; all temporary `.elc` files were removed, keeping the working tree clean.
   - Protected user paths (`.gitignore`, `.agents/`, `skills.md`) remain untouched and unstaged.

2. **Existing Contracts Inventory:**
   - `kargu/contract.el` acts as a facade, currently requiring 4 contract submodules: `constants`, `result`, `types`, and `assert`.
   - In `kargu/contract/`: `assert.el`, `constants.el`, `types.el`, `result.el`, `history.el`, `selection.el`, and `file-window.el` exist and pass `checkdoc` with 0 warnings.
   - However, `kargu/contract.el` does not yet require `history.el`, `selection.el`, or `file-window.el`.

3. **Wave 0 Boundary Assessment:**
   - **Missing Public File Revision API:** `kargu/files.el` defines struct `kargu-file-revision` and private function `kargu-file--file-revision`, but lacks a public `kargu-file-current-revision`. As a consequence, `kargu/tools/diff/track.el` line 47 performs an unauthorized cross-module private call: `(ignore-errors (kargu-file--file-revision path))`. The Wave 0 coordinator must expose `kargu-file-current-revision` in `kargu/files.el` before Wave 1 Package B starts.
   - **Missing Architecture Contracts Inventory:** `architecture-contracts.md` does not yet exist at the repository root. It must be authored by the Wave 0 coordinator, specifying the 8 core boundary contracts (Application, Async scope, Edit, Connection, Tool, Budget, Events, Results).
   - **Application Isolation Fixtures:** While `tests/test-helpers.el` isolates tests via dynamic variable rebinding (`kargu-test--isolate`), there is no test fixture demonstrating two concurrent, isolated `kargu-application` coordinator handles rejecting duplicate runs on the same instance without global interference.

4. **Singleton vs. Owned Context Status:**
   - `kargu/application/coordinator.el` defines `kargu-application` and `kargu-logical-request` structs (introduced in `06a9df2`), but retains fallback singleton `kargu-application--context` and bidirectional bridges to global variables (`kargu--loop-run`, `kargu--busy`, `kargu--generation`, `kargu--current-process`).
   - `kargu/core/session.el` defines `kargu-session` as a buffer-local context (`kargu-session--context`), but falls back to buffer-local `kargu--session-id` and global replacement hooks.
   - `kargu/state/store.el` holds a flat global plist `kargu--state-store` acting as an un-parameterized facade reading from `kargu-session-context` and global coordinator functions.
   - `kargu/async.el` maintains a global list `kargu-async--pending` and checks task ownership against global `kargu--loop-run`.

---

## 1. Codebase Baseline & Verification State

### 1.1 Git Status & Hygiene
- **Branch:** `refactoring`
- **Head Commit:** `262850b`
- **Unstaged / Untracked Safety:**
  - `M .gitignore` (pre-existing modification preserved)
  - `?? .agents/` (agent metadata preserved, unstaged)
  - `?? skills.md` (local engineering discipline preserved, unstaged)
- **Zero `.elc` Rule:** Verified. All temporary compilation files are removed immediately upon inspection.

### 1.2 ERT Test Suite
Executed the authoritative batch command:
```bash
emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit
```
- **Total Tests:** 942
- **Passed:** 942 (100%)
- **Failed / Errored:** 0
- **Duration:** ~42.9 seconds

### 1.3 Formal Proofs (TLA+ / TLC)
Executed via `proof/run_tlc.sh` utilizing `/run/current-system/sw/bin/nix-shell`:
```bash
bash proof/run_tlc.sh --edit-transaction
```
- **Specification:** `EditMC.tla` (`KarguEdit.tla`)
- **Generated States:** 425
- **Distinct States Found:** 160
- **Search Depth:** 10
- **Errors:** 0 (Model checking completed successfully)

---

## 2. Existing Contracts Inventory (`kargu/contract/` & `kargu/contract.el`)

The codebase already contains 7 dedicated contract files in `kargu/contract/` plus `kargu/contract.el`:

| File | Primary Exports (Structs / Consts / Functions) | Role & Dependencies |
|---|---|---|
| `kargu/contract.el` | Requires `constants`, `result`, `types`, `assert` | Facade entry point for contract validation. Does NOT currently require `history`, `selection`, or `file-window`. |
| `kargu/contract/constants.el` | `kargu-buffer-plan` ("\*kargu-plan\*"), `kargu-eglot-required-message`, `kargu-mode-ask`, `kargu-mode-debug`, `kargu-mode-agent`, `kargu-mode-plan`, `kargu-all-modes`, `kargu-role-system`, `kargu-role-user`, `kargu-role-assistant`, `kargu-role-tool`, HTTP statuses (429, 500, 502, 503, 504, 529), `kargu-http-retry-statuses` | Centralized domain constants, modes, roles, and HTTP retry codes. Zero external dependencies. |
| `kargu/contract/assert.el` | `kargu-contract-assert (pred value &optional format-string &rest format-args)`, `kargu-contract-validate (pred value &optional context)` | Boundary assertion and Railway-Oriented validation returning `kargu-ok` or `kargu-err`. Requires `kargu/contract/result`, `kargu/contract/types`. |
| `kargu/contract/types.el` | `kargu-contract-mode-p`, `kargu-contract-role-p`, `kargu-contract-content-p`, `kargu-contract-tool-call-p`, `kargu-contract-tool-calls-p`, `kargu-contract-message-p`, `kargu-contract-filepath-p`, `kargu-contract-non-empty-string-p`, `kargu-contract-url-p`, `kargu-contract-tool-executor-p`, `kargu-contract-prompt-p`, `kargu-contract-callback-p`, `kargu-contract-tool-schema-p` | Predicates validating messages, roles, modes, tools, paths, URLs, schemas. Requires `kargu/contract/constants`. |
| `kargu/contract/result.el` | `kargu-result-ok` struct with `(kargu-ok value)` constructor; `kargu-result-err` struct with `(kargu-err message &optional code data)` constructor; predicates `kargu-ok-p`, `kargu-err-p`; accessor `kargu-result-value` | Railway-Oriented Result ADT for typed error flows without exceptions. Requires `cl-lib`. |
| `kargu/contract/history.el` | `kargu-history` struct (slots: `messages-value`, `tail-value`, `system-key-value`, `overlay-value`, `measured-tail-value`, `char-count-value`); `kargu-history-create (&key messages)` | Session-owned conversation queue record with deep copy of messages. Requires `kargu/contract/assert`. |
| `kargu/contract/selection.el` | `kargu-selection` struct (read-only slots: `provider-value`, `model-value`, `effort-value`); `kargu-selection-default-effort` symbol; `kargu-selection-create (&key provider model effort)` | Immutable provider/model/effort selection value. Requires `kargu/contract/assert`. |
| `kargu/contract/file-window.el` | `kargu-file-window` struct (read-only slots: `from`, `to`); `kargu-file-window-create (&key from to limit offset)` | Canonical 1-based inclusive line range window normalizing aliases (`offset`, `limit`, `from_line`, `to_line`). Requires `kargu/contract/assert`. |

### Observations on Existing Contracts
1. **Linter & Docstrings:** All files under `kargu/contract/` adhere to `checkdoc` conventions and produce zero warnings.
2. **Facade Modularization:** `kargu/contract.el` requires only the initial 4 files. `kargu/contract/history.el`, `kargu/contract/selection.el`, and `kargu/contract/file-window.el` are currently required individually by domain packages (`kargu/core/session.el`, `kargu/files.el`, `tests/test-selection.el`, etc.).
3. **Domain Coverage:** Domain predicates currently focus on message format, tool schemas, modes, and basic strings/URLs. Missing from `kargu/contract/types.el` are explicit predicates for application coordinator records, logical requests, edit outcomes, budgets, and connection snapshots.

---

## 3. Wave 0 Boundary Analysis (Comparison with `parallel-plan.md` Section 3)

`parallel-plan.md` Section 3 establishes the coordinator's ownership and boundaries for Wave 0.

### 3.1 Exclusively Coordinator-Owned Files in Wave 0
The plan explicitly lists:
- `kargu.el`, `kargu/core.el`, `kargu/contract.el`, `kargu/contract/assert.el`, `kargu/contract/constants.el`, `kargu/contract/types.el`, `kargu/contract/result.el`, `kargu/contract/history.el`, `kargu/contract/selection.el`, `kargu/contract/file-window.el`, `kargu/json.el`, `kargu/core/custom.el`, `kargu/core/group.el`.
- `tests/run-tests.el`, `tests/test-helpers.el`, `tests/test-modules.el`, `tests/test-laws.el`, `tests/test-integration.el`.
- `proof/run_tlc.sh`, `proof/README.md`, `proof/KarguState.tla`, `proof/KarguContract.tla`, `proof/MC.tla`, `proof/MC.cfg`.
- `README.md`, `todo.md`, `parallel-plan.md`; and `architecture-contracts.md`.

### 3.2 Gaps and Required Actions for Wave 0

#### Gap 1: Public `kargu-file-current-revision` in `kargu/files.el`
- **Current Observation:**
  In `kargu/files.el` (lines 51–55, 142–150):
  ```elisp
  (cl-defstruct (kargu-file-revision (:constructor kargu-file--make-revision))
    "Filesystem identity and content revision of one disk snapshot."
    (inode nil :read-only t) (device nil :read-only t)
    (bytes nil :read-only t) (mtime nil :read-only t))

  (defun kargu-file--file-revision (path)
    "Capture PATH's filesystem identity, size and content modification time."
    (let ((attributes (file-attributes path)))
      (unless attributes (error "File disappeared while reading its snapshot"))
      (kargu-file--make-revision
       :inode (file-attribute-inode-number attributes)
       :device (file-attribute-device-number attributes)
       :bytes (file-attribute-size attributes)
       :mtime (file-attribute-modification-time attributes))))
  ```
  In `kargu/tools/diff/track.el` (lines 44–47):
  ```elisp
  (defun kargu-diff--disk-revision (path)
    "Return `kargu-file-revision' for PATH on disk, or nil when absent."
    (when (file-exists-p path)
      (ignore-errors (kargu-file--file-revision path))))
  ```
- **Analysis:**
  `kargu-file--file-revision` is a private function of `kargu/files.el`. Calling it from `kargu/tools/diff/track.el` is an architectural boundary violation across module domains.
- **Wave 0 Requirement (`parallel-plan.md` lines 75–80):**
  Coordinator must define `kargu-file-current-revision (path)` in `kargu/files.el` as a public, validating function:
  - Takes `path`, asserts `(kargu-contract-filepath-p path)`, returns the validated `kargu-file-revision` or nil when absent.
  - This allows Package B (`kargu/tools/diff/track.el`) to call the public contract without private cross-calls.
  - This is a narrow bootstrap modification committed before Wave 1 begins.

#### Gap 2: Inventory Document `architecture-contracts.md`
- **Current Observation:** `architecture-contracts.md` does not exist.
- **Wave 0 Requirement (`parallel-plan.md` lines 69, 82–98):**
  Coordinator must author `architecture-contracts.md` to define the 8 target boundaries with producers, consumers, input/output types, validation owners, state transitions, cancellation semantics, and resource lifetimes:
  1. **Application:** Open `application` handle + session/run/request IDs; claim before presentation notification; release only releases matching claim. UI commands receive handle from composition; lower services do not look up singletons.
  2. **Async scope:** Owner/parent/task, deadline, cancel/close. Cancellation request, process exit, and terminal delivery are distinct events.
  3. **Edit:** Explicit edit service; exact source revision and policy/config revision; block, symbol, and Unified Diff produce the same transaction outcome (`applied`, `staged`, `conflict`, `partial/unknown`).
  4. **Connection:** Immutable snapshot of provider/model/endpoint/format/config revision; credentials bound exclusively to this snapshot; secrets excluded from argv, logs, and session snapshots.
  5. **Tool:** Registry + execution context + args + completion → cancel handle. Unified gate for direct and alias invocations.
  6. **Budget:** Run-owned total accounting for requests, deadlines, and tokens. Normal calls, retries, compactions, and healing debit the same gate. Unknown usage is distinct from zero.
  7. **Events:** Minimal immutable payload carrying run/session/request/call/connection IDs. Passive notifications separated from control requests requiring response.
  8. **Results:** Railway-oriented domain error codes and impact states on `contract/result.el`. No string parsing to deduce retry/success.

#### Gap 3: Contract Type Predicates in `kargu/contract/types.el`
- **Current Observation:**
  Predicates exist for modes, roles, messages, filepaths, URLs, schemas, callbacks.
- **Wave 0 Requirement:**
  Wave 0 should establish predicates or type assertions for core records:
  - `(kargu-contract-application-p app)` or verify `kargu-application-p`
  - `(kargu-contract-logical-request-p req)` or verify `kargu-logical-request-p`
  - Verify `kargu-file-revision-p` export/predicate visibility

#### Gap 4: Multi-Application Fixtures and Gate 0 Acceptance Test
- **Current Observation:**
  `tests/test-helpers.el` has `kargu-test--isolate` which shadows global variables using dynamic `let` bindings during ERT runs.
- **Wave 0 Requirement (`parallel-plan.md` lines 99–101):**
  "İlk kapı: iki izole application fixture'ı birbirini değiştirmez; aynı application'da ikinci run reddedilir; opsiyonel modül yüklenmeden public sözleşmeler yüklenir."
  A concrete acceptance test or fixture helper should be established in `tests/test-helpers.el` or `tests/test-application-context.el` proving that two instantiated `kargu-application` coordinator structs do not cross-contaminate and that attempting a second concurrent active run on an application instance is rejected.

---

## 4. Application Coordinator and Session State Analysis

### 4.1 Application Coordinator (`kargu/application/coordinator.el`)
- **Structs Defined:**
  - `kargu-logical-request`: `(id generation session origin state process retry-timer stream-timer)`
  - `kargu-application`: `(status active-run active-request generation)`
- **Current Singleton vs. Owned Status:**
  - **Global Fallback:** `kargu-application--context` is a global variable lazily initialized by `kargu-application-context`.
  - **Legacy Global Bridges:**
    - Line 19: `(defvar kargu--loop-run nil)`
    - Line 20: `(defvar kargu--busy nil)`
    - Line 21: `(defvar kargu--generation 0)`
    - Line 22: `(defvar kargu--current-process nil)`
  - **Bypasses in Coordinator Functions:**
    - In `kargu-application-current-run (&optional app)` (lines 166–172):
      If `app` is nil, it falls back to `kargu--loop-run` before checking `kargu-application--context`.
    - In `kargu-application-set-active-run (run &optional app)` (lines 173–179):
      `(unless app (setq kargu--loop-run run))` synchronizes back to the global variable.
    - In `kargu-application-next-generation (&optional app)` (lines 200–207):
      `(unless app (let ((next (cl-incf kargu--generation))) (setf (kargu-application-generation target) next) next))`
    - In `kargu-application-work-active-p (&optional app)` (lines 209–222):
      If `app` is nil, it inspects `kargu--loop-run`, `kargu--busy`, `kargu-loop-running-p`, and `kargu-busy-p`.
- **Verdict:**
  The structs `kargu-application` and `kargu-logical-request` provide the foundation for owned contexts, but currently operate as a transitional wrapper around mutable global singletons. In Wave 1/A, all calls must pass the explicit application handle and eliminate lookups of `kargu-application--context` and global flags.

### 4.2 Session State (`kargu/core/session.el`)
- **Struct Defined:**
  - `kargu-session`: `(id-value usage-value mode-value mode-revision mode-request history-value selection-value)`
- **Current Status:**
  - Buffer-local storage: `(defvar-local kargu-session--context nil)`.
  - `kargu-session-context (&optional buffer)` returns the buffer's owned session record, creating it lazily if absent.
  - Still maintains legacy buffer-local `kargu--session-id`.
  - Employs global hook `kargu-session-before-replace-hook` for retirement/cleanup.
- **Verdict:**
  Session state is already buffer-owned and structured via `kargu-session`. The primary need is cleanly separating session identity from application claim, and ensuring headless callers can pass an explicit session reference without requiring a live Emacs buffer.

### 4.3 Central State Store (`kargu/state/store.el`)
- **Current Implementation:**
  - `(defvar kargu--state-store nil)` stores a global plist: `(:status :idle :busy nil :prompt-tokens 0 :completion-tokens 0 :total-tokens 0)`.
  - `kargu-state--sync-snapshot` syncs from `(kargu-session-context)` and `(kargu-application-current-status)`.
  - `kargu-state-get (key &optional default)` delegates:
    - `:mode` → `(kargu-session-mode-value (kargu-session-context))`
    - `:provider` → `(kargu-selection-provider)`
    - `:model` → `(kargu-selection-model)`
    - `:reasoning-effort` → `(kargu-selection-effort)`
    - `:status` → `(kargu-application-current-status)`
    - `:busy` → `(kargu-application-busy-p)`
    - `:prompt-tokens` / `:completion-tokens` → `(kargu-session-usage-value (kargu-session-context))`
    - Other keys → `(plist-get kargu--state-store key)`
- **Verdict:**
  `kargu/state/store.el` currently acts as an un-parameterized facade over global and buffer-local singletons. Callers cannot specify which application or session they are reading from. In Wave 1/A, state accessors must take explicit context parameters.

### 4.4 Asynchronous Tasks (`kargu/async.el`)
- **Current Implementation:**
  - `(defvar kargu-async--pending nil)` (global list of all pending tasks)
  - `(defvar kargu--loop-run nil)` (referenced as task owner)
  - In `kargu-async-start`: `:owner kargu--loop-run`, `:buffer (current-buffer)`
  - In `kargu-async-pending-p`: verifies `(eq (kargu-async-task-owner task) kargu--loop-run)`
- **Verdict:**
  Task ownership is tied to the global `kargu--loop-run`. Wave 1/A must introduce explicit owner/parent scopes so tasks are owned by an application run or session context rather than a global variable.

---

## 5. Synthesis & Actionable Recommendations for Wave 0

To enable the Wave 1 parallel workers (Worker A: Application/Budget, Worker B: Edit Service, Worker C: Connection Snapshot) to execute without boundary collisions, the coordinator should complete the following serial steps in Wave 0:

1. **Bootstrap `kargu-file-current-revision` in `kargu/files.el`:**
   - Define and export `kargu-file-current-revision (path)` in `kargu/files.el`.
   - Update `kargu/tools/diff/track.el` to call `kargu-file-current-revision` instead of the private `kargu-file--file-revision`.
   - Verify `tests/test-patch.el` and `tests/test-file-window.el` continue to pass.

2. **Publish `architecture-contracts.md`:**
   - Document the 8 target port contracts as required by Section 3 of `parallel-plan.md`.
   - Include type specifications, validation responsibilities, error formats, state machines, and lifecycle/cancellation rules for each port.

3. **Establish Contract Facade & Type Consistency:**
   - Review whether `kargu/contract.el` should explicitly require `kargu/contract/history`, `kargu/contract/selection`, and `kargu/contract/file-window` or maintain on-demand loading.
   - Add type assertions/predicates for application and logical request handles in `kargu/contract/types.el`.

4. **Add Wave 0 Acceptance Fixtures:**
   - Add a test verifying dual application isolation: instantiate two `kargu-application` records, demonstrate that setting active runs, requests, or statuses on one does not affect the other, and verify that claiming a second run on an active application is rejected.

5. **Update Tracking in `todo.md`:**
   - Reflect Wave 0 baseline validation and note the formal establishment of common boundaries.
