# Dispatch: auditor_wave2_1

Spawned: 2026-10-22T03:56:00Z
Mission: Wave 2 Forensic Auditor
Working Directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/auditor_wave2_1

## 2026-10-22T03:56:35Z
You are auditor_wave2_1, working as Wave 2 Forensic Auditor.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/auditor_wave2_1

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 5: Dalga 2 Packages D, E, F)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md
- All git changes introduced across Wave 2 in:
  - Package D: `kargu/tools/execution.el`, `kargu/tools/registry.el`, `kargu/permission/*.el`, `kargu/permission.el`, `kargu/confirm.el`, `kargu/api/tools.el`, `tests/test-tool-execution-contract.el`, `tests/test-tool-registry.el`, `tests/test-permission-operation.el`
  - Package E: `kargu/api/circuit.el`, `kargu/api/http.el`, `kargu/api/retry.el`, `kargu/api/client.el`, `kargu/api/request.el`, `kargu/api/sse.el`, `kargu/api/stream.el`, `kargu/api/wire.el`, `kargu/api/tool-calls.el`, `kargu/api/response.el`, `kargu/api/parameters.el`, `kargu/api.el`, `tests/test-transport-contract.el`, `tests/test-stream-pressure.el`, `proof/KarguTransport.tla`, `proof/TransportMC.tla`, `proof/TransportMC.cfg`
  - Package F: `kargu/tools/process.el`, `kargu/tools/bash/jobs.el`, `kargu/tools/process/session.el`, `tests/test-job-owner.el`, `tests/test-process-stress.el`, `tests/test-process-session.el`, `tests/test-process.el`
  - Common: `proof/run_tlc.sh`

Scope & Tasks:
1. Forensic integrity verification:
   - Verify that all implementations across Packages D, E, and F are GENUINE:
     - NO hardcoded return values matching test inputs/names
     - NO mock or dummy facades producing fake success without genuine business logic
     - NO weakened test assertions or skipped assertions
     - NO mock bypasses that circumvent real validation
   - Verify that `kargu/tools/execution.el` contains genuine 13-stage pipeline, real schema validation, authentic single-use claim tracking, real output token debiting, and real secret redaction.
   - Verify that `kargu/api/circuit.el` genuinely scopes circuit state by provider and isolates failures.
   - Verify that `kargu/api/http.el` and `retry.el` genuinely debit `kargu-run-budget` and eliminate string-based retry matching.
   - Verify that `kargu/tools/process.el` genuinely uses `(accept-process-output nil ...)` and signals negative PGID `(- pgid)` to eliminate orphan child processes.
   - Verify that `kargu/tools/bash/jobs.el` genuinely scopes jobs by project root.
   - Run the FULL ERT test suite command:
     `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
     Confirm that ALL 1049 tests pass with 0 failures and 0 errors!
   - Verify byte-compilation hygiene: all modified/new files compile under `(setq byte-compile-error-on-warn t)` with zero warnings.
   - Verify zero `.elc` files exist anywhere in the repository.
   - Verify repository governance: `skills.md`, `.gitignore`, and `.agents/` outside `.agents/teamwork/` are 100% untouched and unstaged.
2. Deliver your binary verdict: CLEAN or INTEGRITY VIOLATION.
3. Write your detailed forensic audit report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/auditor_wave2_1/audit_report.md` and handoff with verdict to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/auditor_wave2_1/handoff.md`.
4. Send completion message to caller via send_message.
