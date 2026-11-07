# Dispatch: worker_wave2_D

Spawned: 2026-10-22T03:12:00Z
Mission: Wave 2 Package D Worker (Tool Execution Gate & Registry)
Working Directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_D
## 2026-10-22T03:12:22Z
You are worker_wave2_D, working on Wave 2 Package D: Tool Execution Gate & Registry.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_D

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_D_2/package_D_report.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_D_2/handoff.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_D_2/proposed_test_tool_execution_contract.el
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 5: Package D)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Contract 5: Tool Registry & Execution Contract, Contract 6: Budget Accounting)
- /home/emrehan/.emacs.local/kargu/todo.md (MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17, ARCH-19)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope & Exclusive Write Allowlist:
- `kargu/api/tools.el`
- `kargu/tools/registry.el`
- `kargu/permission/*.el`
- `kargu/permission.el`
- `kargu/confirm.el`
- New: `kargu/tools/execution.el`
- Tests: `tests/test-tool-registry.el`, `tests/test-permission.el`, `tests/test-permission-operation.el`, new `tests/test-tool-execution-contract.el`
- Proof: `proof/KarguApproval.tla`, `proof/ApprovalMC.tla`, `proof/ApprovalMC.cfg`, `proof/KarguTools.tla`
NEVER modify or stage skills.md, .gitignore, or .agents/. Do NOT touch files owned by Package E or Package F. Do NOT modify feature tool implementations (`kargu/tools/git.el`, `diff.el`, `bash.el`, `search.el`, `lsp/*`, `dape/*`, etc.).

Tasks:
1. Unified Tool Execution Gate:
   Implement `kargu/tools/execution.el` with `kargu-tool-execution-context` (carrying app, run-id, session-id, root, mode, budget-scope, policy-revision), `kargu-tool-approval` with single-use claim semantics (`claimed-p`), 13-stage execution pipeline in `kargu-tool-gate-execute`, active async task tracking under `kargu-async`, secret redaction, output token debiting into `kargu-run-budget`, output truncation and project-owned archiving, and terminal single-delivery.
2. Draining and Unload Safety:
   Implement `kargu-tool-execution-drain` marking definitions draining and cancelling/waiting on active tasks before code detachment (ARCH-09, ARCH-17). Update `kargu/tools/registry.el` with monotonic revision counter and draining state.
3. Approval Identity & Permission:
   Update `kargu/permission/*.el`, `kargu/permission.el`, and `kargu/confirm.el` to bind approval tokens to root, tool, args-hash, and policy revision, rejecting replay attempts.
4. Compatibility Bridge:
   Update `kargu/api/tools.el` to route `kargu-execute-tool` through the unified gate while preserving existing public API compatibility.
5. Test Suite:
   Implement `tests/test-tool-execution-contract.el` (all 19 tests from `proposed_test_tool_execution_contract.el`) and ensure all existing permission/tool tests pass.
6. Verification:
   - Run ERT tests: `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
   - Run byte-compilation check with `(setq byte-compile-error-on-warn t)` on all modified/new files. Confirm 0 warnings.
   - Run checkdoc on modified/new files.
   - Confirm zero `.elc` files remain.
   - Run TLC: `bash proof/run_tlc.sh --approval`.
   - Confirm repository hygiene: `git status --porcelain skills.md .gitignore .agents/` is empty.
7. Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_D/worker_D_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_D/handoff.md`.
8. Send completion message to caller via send_message.
