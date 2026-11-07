## 2026-10-21T21:56:44Z
You are worker_wave1_B, working on Wave 1 Package B: Single-Owner Edit Service and Approval Identity.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_B

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 4: Package B)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Edit service contract)
- /home/emrehan/.emacs.local/kargu/todo.md (ARCH-03, ARCH-04, ARCH-08, ARCH-10, ARCH-15, ARCH-17, MOD-07, DEEP-10, DEEP-11, DEEP-15)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope & Exclusive Write Allowlist:
- kargu/edit.el
- kargu/tools/diff.el
- kargu/tools/diff/stage.el
- kargu/tools/diff/review.el
- kargu/tools/diff/track.el
- New: kargu/tools/diff/context.el
- Tests: tests/test-patch.el, tests/test-edit-transaction.el, new tests/test-edit-service.el
- Proof: proof/KarguEdit.tla, proof/EditMC.tla, proof/EditMC.cfg
- Register tests/test-edit-service in tests/run-tests.el.
NEVER modify or stage skills.md, .gitignore, or .agents/. Do NOT touch files owned by Package A or C.

Tasks:
1. Edit Service Context: Move snapshot/change/review tables, pending callbacks, and temp resources into an explicit `kargu-edit-service` struct in `kargu/tools/diff/context.el`.
2. Frozen Approval & Policy: Capture source revision, session/run/application, and review/auto-save/policy revision into the transaction plan. Re-verify document revision before applying.
3. Unified Outcome: Handle save-hook results, write effects, and rollback conflicts in a single typed result structure.
4. Git Safety: Maintain isolated Git work area; never touch user Git index; keep `git apply` async.
5. Resource Cleanup: Close/unload cleans only own review/process/timer/temp areas without leaking across services.
6. Test Suite: Add `tests/test-edit-service.el` testing two services on same/different paths, approval during config/session change, active close, staged index fixture, dirty/narrowed/CRLF/Unicode.
7. Verification:
   - Run ERT tests: `emacs -Q --batch -L . -l kargu -l tests/test-helpers.el -f ert-run-tests-batch-and-exit`
   - Byte-compilation with `(setq byte-compile-error-on-warn t)`: 0 warnings.
   - Checkdoc: 0 warnings on modified/new files.
   - Zero `.elc` files left in repo.
   - TLC model check: `bash proof/run_tlc.sh --edit-transaction`.
8. Write detailed report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_B/worker_B_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave1_B/handoff.md`.
9. Send completion message to caller.
