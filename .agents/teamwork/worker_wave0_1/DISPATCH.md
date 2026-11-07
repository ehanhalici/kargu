## 2026-10-21T20:31:19Z
You are teamwork_preview_worker_wave0_1, working as Wave 0 Coordinator Worker.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave0_1

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 3: Wave 0 common boundaries)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_1/wave0_revision_report.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/architecture-contracts.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_3/wave0_isolation_report.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope & Boundaries:
- NEVER modify or stage skills.md, .gitignore, or .agents/.
- Do NOT leave any temporary .elc files in the source tree.
- Exclusive write ownership for Wave 0:
  - kargu/files.el
  - kargu/tools/diff/track.el
  - kargu/contract.el
  - kargu/application/coordinator.el
  - architecture-contracts.md
  - tests/test-helpers.el
  - tests/test-modules.el
  - tests/test-application-context.el
  - tests/run-tests.el

Tasks:
1. Implement public `(kargu-file-current-revision path)` in `kargu/files.el` and update `kargu/tools/diff/track.el:47` to use `(kargu-file-current-revision path)` instead of the private helper, exactly as detailed in `explorer_wave0_1/wave0_revision_report.md`.
2. Write `/home/emrehan/.emacs.local/kargu/architecture-contracts.md` using the complete text from `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/architecture-contracts.md`.
3. Update `kargu/contract.el` to require the remaining submodules (`file-window`, `history`, `selection`) so the public contract facade loads all 7 submodules.
4. Update `kargu/application/coordinator.el` with:
   - `kargu-application-claim` (returns t on success, nil if already claimed by active run)
   - `kargu-application-release` (releases matching claim)
   - Single-active-run rejection in `kargu-application-set-active-run` per `explorer_wave0_3/wave0_isolation_report.md`.
5. Update `tests/test-helpers.el` with dual-application fixtures (`kargu-test-make-dual-applications`, `kargu-test-with-dual-applications`).
6. Update `tests/test-modules.el` with `kargu-module-all-contracts-independent-test` and `kargu-module-dual-application-isolation-test`.
7. Create `tests/test-application-context.el` with the 4 isolation tests (dual-instance isolation, request isolation, single-run rejection, claim/release lifecycle) per `explorer_wave0_3/wave0_isolation_report.md`.
8. Update `tests/run-tests.el` to require `tests/test-application-context`.
9. Verification:
   - Run the full ERT test suite:
     `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
     Confirm all tests pass with 0 failures and 0 errors (should now be 948 passing tests).
   - Run byte-compilation on all modified and new Elisp files with `(setq byte-compile-error-on-warn t)`. Ensure ZERO warnings.
   - Ensure ZERO `.elc` files remain: `find . -name "*.elc"` must be empty.
   - Run checkdoc on modified and new files.
   - Run TLC model checking: `bash proof/run_tlc.sh --mode` and `bash proof/run_tlc.sh --edit-transaction`.
   - Verify `git status --short` confirms `skills.md`, `.gitignore`, and `.agents/` are untouched.
10. Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave0_1/wave0_worker_report.md` and complete handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave0_1/handoff.md`.
11. Send completion message via send_message to caller.
