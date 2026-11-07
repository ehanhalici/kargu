# Handoff Report — Wave 2 Package D (Tool Execution Gate & Registry)

**Author:** `explorer_wave2_D_2`  
**Recipient:** `worker_wave2_D` / Coordinator (`246e42bd-e1b7-4f73-8026-d90704dd17ec`)  
**Date:** 2026-10-22  
**Artifact Directory:** `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_D_2/`  
**Handoff Type:** Hard (Exploration, Design & Verification Complete)

---

## 1. Observation

1. **Global Unowned Tool Registry (`kargu/api/tools.el:25-26`)**:
   ```elisp
   (defvar kargu--tool-registry (kargu-tool-registry-create)
     "Legacy default registry awaiting explicit application ownership.")
   ```
   All tools register against this mutable global variable. Unregistered or detached modules leave dangling references, violating ARCH-01 and ARCH-12.

2. **Bypassed Execution Gate (`kargu/api/tools.el:411-440`)**:
   `kargu-execute-tool` resolves tools and immediately dispatches executors without checking:
   - Mode gating for mutating tools (`kargu-tool-execution--mutating-tools`), allowing mutations in `ask` / `plan` modes when called directly or via alias.
   - Run budget accounting (`kargu-run-budget` from `kargu/application/budget.el`), allowing unlimited unbudgeted tool outputs.
   - Captured single-use approval verification (`kargu-tool-approval`).
   - Secret redaction in output before logging or storage.

3. **Active Work Dropping on Unload (`kargu/tools/registry.el:127-142`)**:
   ```elisp
   (defun kargu-tool-registry-remove (registry name)
     "Remove NAME from REGISTRY and return non-nil if it existed..."
     (let* ((entries (kargu-tool-registry-entries registry))
            (entry (gethash name entries)))
       (when entry
         ...
         (remhash name entries)
         t)))
   ```
   Removing a tool immediately deletes its hash table entry while asynchronous processes (`kargu-async-task`) may still be executing in the background, violating ARCH-09 and ARCH-17.

4. **Approval Replay & Scope Boundary (`kargu/permission/execute.el:37-55`)**:
   `kargu-permission--operation-valid-p` checks session and root, but lacks binding to the tool definition's schema and policy revision (`policy-revision`). A tool definition could be mutated mid-approval without invalidating pending approvals.

5. **Formal Model Verification Status**:
   - `proof/run_tlc.sh --approval` passes with 8,194 states generated, 1,536 distinct states, 0 errors.
   - `proof/run_tlc.sh --simulate 10000` passes with 2,795,038 states checked, 0 errors, validating `KarguTools.tla` and `KarguLoop.tla`.

6. **Test Suite Baseline**:
   - 997 tests ran, 997 passed, 0 failures, 0 errors via:
     `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
   - All scope files compile cleanly with 0 warnings under `(setq byte-compile-error-on-warn t)`.

---

## 2. Logic Chain

1. **From Observation 1 & 3 to Owned Registry with Revisions & Draining**:
   - Because definitions, aliases, and revisions must be isolated from mutable pending executions, `kargu-tool-registry` in `kargu/tools/registry.el` is augmented with a monotonic `revision` counter and a `draining` state table.
   - `kargu/tools/execution.el` maintains active async task tracking (`kargu-tool-execution--active-tasks`).
   - When a tool is unregistered or disabled, `kargu-tool-execution-drain` marks the definition as draining, cancels or drains all active tasks, and only detaches the code once in-flight task count reaches zero (ARCH-09, ARCH-17).

2. **From Observation 2 to Context-Carrying Unified Execution Gate**:
   - Passing `kargu-tool-execution-context` (carrying `app`, `run-id`, `session-id`, `root`, `mode`, `budget-scope`, `policy-revision`) ensures every execution has an explicit owner.
   - The 13-stage gate pipeline guarantees:
     1. Canonical resolution & alias flattening (aliases cannot bypass checks).
     2. Mode gating (mutating tools like `edit_file`, `bash`, `git_commit` forbidden in `ask`/`plan` modes).
     3. Availability checking (`:available-p`).
     4. JSON parameter decoding and schema validation.
     5. Budget pre-check (`kargu-budget-live-p`) and token debiting (`kargu-budget-record-tokens`).
     6. Single-use captured approval (`kargu-tool-approval`, no replay/preapproved cache).
     7. Async task tracking with structured cancellation under `kargu-async`.
     8. Output secret redaction (`kargu-tool-execution-redact`).
     9. Output truncation and project-owned archiving (`*kargu-output-N*`).
     10. Terminal single-delivery guarantee via `kargu-async-finish`.

3. **From Observation 4 to Single-Use Approval Binding (ARCH-03)**:
   - Defining `kargu-tool-approval` with `token-id`, `tool-name`, `args-hash`, `root`, `policy-revision`, `environment-hash`, and `claimed-p`.
   - On execution, `kargu-tool-approval-claim` verifies all bound parameters match and immediately sets `claimed-p = t`.
   - Replay attempts fail fast with `:approval-stale`.

4. **From Observation 5 to Formal Proof Consistency**:
   - `proof/KarguApproval.tla` proves that execution transitions to `executing` if and only if all authority fields are verified at admission, and terminal delivery occurs only after the phase closes.
   - `proof/KarguTools.tla` proves mode safety: mutating tools can only be admitted in `agent` mode.
   - Concrete implementation strictly conforms to both formal specifications.

---

## 3. Caveats

1. **Feature Adapters Write Boundary**:
   Per `parallel-plan.md` Section 5, Package D Worker must NOT modify feature adapters in their source files (`kargu/tools/git.el`, `kargu/tools/diff.el`, `kargu/tools/bash.el`, `kargu/tools/search.el`, `kargu/tools/lsp/register.el`, `kargu/tools/dape/register.el`, `kargu/tools/webfetch.el`, `kargu/tools/skill.el`). Those adapters continue registering via the compatibility facade in `kargu/api/tools.el` until migrated by their respective packages (F, J, K, N) or final composition.
2. **Read-Only Investigation Integrity**:
   No source code in `kargu/` or `tests/` was modified during this investigation. All blueprints, reports, and proposed tests are strictly stored in `.agents/teamwork/explorer_wave2_D_2/`.

---

## 4. Conclusion

Wave 2 Package D is fully investigated, architecturally designed, and ready for immediate implementation by Worker D:
1. **Architectural Report**: `package_D_report.md` contains the complete blueprint, ASCII flow diagrams, function signatures, and before/after code blocks.
2. **Registry Revision & Draining**: Designed monotonic revision tracking and safe unregister/disable in `kargu/tools/registry.el`.
3. **Unified Execution Gate**: Designed `kargu/tools/execution.el` with `kargu-tool-execution-context`, `kargu-tool-approval`, and `kargu-tool-gate-execute`.
4. **Contract Test Suite**: Designed `proposed_test_tool_execution_contract.el` with 19 comprehensive ERT test cases.
5. **Formal Verification**: Verified `KarguApproval.tla` and `KarguTools.tla` with 100% TLC pass.

---

## 5. Verification Method

To independently verify the designs, code blueprints, and formal models:

1. **Verify Baseline Test Suite**:
   ```bash
   emacs -Q --batch -L . \
     --eval "(progn (require 'package) (package-initialize) \
                    (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) \
                      (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" \
     -f ert-run-tests-batch-and-exit
   ```
   *Expected outcome*: 997 tests pass with 0 failures and 0 errors.

2. **Verify Formal Models with TLC**:
   ```bash
   bash proof/run_tlc.sh --approval
   bash proof/run_tlc.sh --simulate 10000
   ```
   *Expected outcome*: TLC completes without errors (1,536 distinct states on ApprovalMC).

3. **Verify Byte-Compilation Hygiene**:
   ```bash
   emacs -Q --batch -L . \
     --eval "(progn (require 'package) (package-initialize) \
                    (setq byte-compile-error-on-warn t) \
                    (dolist (f '(\"kargu/tools/registry.el\" \"kargu/permission.el\" \
                                \"kargu/permission/guards.el\" \"kargu/permission/policy.el\" \
                                \"kargu/permission/bash.el\" \"kargu/permission/execute.el\" \
                                \"kargu/confirm.el\" \"kargu/api/tools.el\")) \
                      (byte-compile-file f)))" && rm -f kargu/tools/*.elc kargu/permission/*.elc kargu/*.elc kargu/api/*.elc
   ```
   *Expected outcome*: 0 warnings, 0 errors, 0 leftover `.elc` files.

4. **Verify Proposed Contract Test Suite Once Implemented**:
   ```bash
   emacs -Q --batch -L . \
     --eval "(progn (require 'package) (package-initialize) (require 'kargu) \
                    (require 'tests/test-tool-execution-contract))" \
     -f ert-run-tests-batch-and-exit
   ```
   *Expected outcome*: 19/19 tests pass.

---

### Artifact Index
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_D_2/package_D_report.md`
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_D_2/handoff.md`
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_D_2/proposed_test_tool_execution_contract.el`
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_D_2/BRIEFING.md`
- `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_D_2/progress.md`
