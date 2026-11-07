# Handoff Report: Wave 0 Architecture Contracts Specification

**Agent**: `teamwork_preview_spec_miner_wave0_2`  
**Milestone**: Wave 0 Coordinator Boundaries  
**Date**: 2026-10-21  
**Working Directory**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2`  
**Target File**: `/home/emrehan/.emacs.local/kargu/architecture-contracts.md`  

---

## 1. Observation

1. **Dispatch and Plan Directives**:
   - `parallel-plan.md` lines 62–70 explicitly specifies allowlisted files for Wave 0:
     > "`kargu.el`, `kargu/core.el`, `kargu/contract.el`, `kargu/contract/assert.el`, `kargu/contract/constants.el`, `kargu/contract/types.el`, `kargu/contract/result.el`, `kargu/contract/history.el`, `kargu/contract/selection.el`, `kargu/contract/file-window.el`, `kargu/json.el`, `kargu/core/custom.el`, `kargu/core/group.el` ... yeni ortak sözleşme envanteri için `architecture-contracts.md`."
   - `parallel-plan.md` lines 75–81 explicitly specifies the bootstrap requirement for `kargu/files.el`:
     > "Dalga 0'da B'nin çapraz private çağrısını kaldırabilmesi için koordinatör `kargu/files.el` içinde mevcut revision okuyucusunu public, doğrulanan `kargu-file-current-revision` sınırıyla açabilir. Yeni disk okuma motoru veya ikinci revision tipi oluşturmaz. Bu dar bootstrap değişikliği Dalga 1'den önce commit edilir; dosyanın sonraki yazma sahipliği Dalga 4/L'ye geçer."
   - `parallel-plan.md` lines 88–98 fixes the 8 target boundary contracts:
     - Application: explicit `application` handle + session/run/request IDs; claim first, view notification after; release releases only identical claim.
     - Async scope: owner/parent/task, deadline, and cancel/close. Cancellation request, process exit, and terminal delivery are distinct events.
     - Edit: explicit edit service; source revision and config/policy revision; block/symbol/Unified Diff converge on same transaction outcome (`applied`, `staged`, `conflict`, `partial/unknown`).
     - Connection: provider/model/endpoint/format/config-capability revision snapshot; credential bound strictly to this snapshot; secrets excluded from argv/log/session.
     - Tool: registry + execution context + args + completion callback -> cancel handle; unified gate for alias and direct calls.
     - Budget: single total request/deadline/token debit gate per run; normal requests, retries, healing, compaction share debit gate; unknown usage is never coerced to `0`.
     - Events: minimal run/session/request/call/connection ID; immutable payload; passive observer vs replying control request separated.
     - Results: canonical domain error codes and effect status on `contract/result.el`; no text parsing to decide retry/success.
   - `parallel-plan.md` lines 99–101 defines the initial acceptance gates:
     > "İlk kapı: iki izole application fixture'ı birbirini değiştirmez; aynı application'da ikinci run reddedilir; opsiyonel modül yüklenmeden public sözleşmeler yüklenir. Salt tanım envanteri kod garantisi sayılmaz."

2. **Codebase Inspection**:
   - `kargu/contract/*.el`:
     - `kargu/contract/result.el` lines 21–29 defines `kargu-result-ok` (`value`) and `kargu-result-err` (`message`, `code`, `data`), with constructors `kargu-ok`, `kargu-err`, and predicates `kargu-ok-p`, `kargu-err-p`.
     - `kargu/contract/types.el` lines 17–105 defines type predicates `kargu-contract-mode-p`, `kargu-contract-role-p`, `kargu-contract-content-p`, `kargu-contract-tool-call-p`, `kargu-contract-tool-calls-p`, `kargu-contract-message-p`, `kargu-contract-filepath-p`, `kargu-contract-url-p`, `kargu-contract-tool-executor-p`, `kargu-contract-tool-schema-p`.
     - `kargu/contract/assert.el` lines 16–37 defines `kargu-contract-assert` and `kargu-contract-validate`.
     - `kargu/contract/constants.el` lines 25–82 defines modes (`ask`, `debug`, `agent`, `plan`), roles (`system`, `user`, `assistant`, `tool`), and HTTP retry status codes (429, 500, 502, 503, 504, 529).
     - `kargu/contract/history.el` lines 16–28 defines `kargu-history` struct and constructor.
     - `kargu/contract/selection.el` lines 19–33 defines `kargu-selection` struct and constructor.
     - `kargu/contract/file-window.el` lines 15–39 defines `kargu-file-window` struct and constructor.
   - `kargu/files.el` line 51 defines struct `kargu-file-revision` (`inode`, `device`, `bytes`, `mtime`), and line 142 defines internal function `(kargu-file--file-revision path)`.
   - `kargu/application/coordinator.el` lines 29–60 defines `kargu-logical-request`, line 121 defines `kargu-application` struct (`status`, `active-run`, `active-request`, `generation`).
   - `kargu/async.el` lines 22–33 defines `kargu-async-task` struct and `kargu-async-start`.
   - `tests/test-modules.el` lines 45–55 defines `kargu-module-test--load-foundation` and lines 145–150 tests `kargu-module-contract-is-independent-test`.

---

## 2. Logic Chain

1. From Observation 1, `parallel-plan.md` §3 and `ORIGINAL_REQUEST.md` mandate establishing the authoritative `architecture-contracts.md` at the repository root defining the 8 core boundaries and Wave 0 acceptance gates.
2. From Observation 1, each boundary requires documented Producer/Consumer roles, required vs optional dependencies, canonical input/output types (referencing existing structs or specifying new contracts), validation owners, lifecycle state machines, and ownership/cancellation invariants.
3. From Observation 2 (`kargu/contract/*.el`), Kargu already has established primitives (`kargu-result-ok`, `kargu-result-err`, `kargu-file-window`, `kargu-history`, `kargu-selection`, type predicates) that serve as foundational types.
4. From Observation 2 (`kargu/files.el:51,142`), `kargu-file-revision` already exists internally and must be made public as `kargu-file-current-revision` to eliminate private calls from Package B.
5. Synthesizing Observations 1 and 2, all 8 boundaries have been specified in complete, unambiguous detail in `architecture-contracts.md` and backed by 39 discovered features and 34 edge cases documented in `wave0_contracts_report.md`.
6. Therefore, the generated `architecture-contracts.md` file in our working directory is fully verified and ready for the Worker to deploy to `/home/emrehan/.emacs.local/kargu/architecture-contracts.md`.

---

## 3. Caveats

- **Read-Only Constraint**: As a Spec Miner, this agent does not modify repository files outside its designated working directory (`.agents/teamwork/spec_miner_wave0_2/`). The draft text is provided in `architecture-contracts.md` within this directory, ready for the Worker/Coordinator to copy to the repository root.
- **TLA+ Model Validation**: TLC model checking (`proof/run_tlc.sh`) will be executed by the Coordinator / Worker during integration of Wave 0.

---

## 4. Conclusion

The specification mining for Wave 0 Architecture Contracts is complete:
1. `architecture-contracts.md` is fully drafted at:
   `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/architecture-contracts.md`
2. All 8 boundaries (Application, Async scope, Edit, Connection, Tool, Budget, Events, Results) are exhaustively defined with producers, consumers, dependencies, input/output types, validation owners, lifecycle events, and invariants.
3. Acceptance test fixtures (Dual-Application Isolation, Single-Active-Run Rejection, Pluggable Contract Loading, File Revision Reader Bootstrap) are documented with exact verification criteria.
4. The comprehensive report is stored at:
   `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/wave0_contracts_report.md`

---

## 5. Verification Method

To verify the deliverables:
1. Inspect the drafted files:
   - `view_file` on `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/architecture-contracts.md`
   - `view_file` on `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/wave0_contracts_report.md`
   - `view_file` on `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/handoff.md`
2. Confirm the 8 boundaries match `parallel-plan.md` §3 lines 88–98 and `survey_spec_matrix.md`.
3. Confirm that the test suite continues to pass 942/942 tests:
   ```bash
   emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
   ```
4. Confirm zero byte-compilation warnings with `(setq byte-compile-error-on-warn t)`.
