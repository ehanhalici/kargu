# Handoff Report: Baseline Survey & Wave 0 Boundaries

## 1. Observation
1. **Repository Baseline & Verification:**
   - Head commit: `262850b docs: define staged parallel agent ownership and acceptance plan` (branch `refactoring`).
   - Running full ERT suite via `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit` yielded:
     `Ran 942 tests, 942 results as expected, 0 unexpected (2026-10-21 20:07:58+0000, 42.896241 sec)`.
   - Running TLC proof via `bash proof/run_tlc.sh --edit-transaction` yielded:
     `425 states generated, 160 distinct states found, 0 states left on queue. The depth of the complete state graph search is 10. Finished in 00s ... TLC finished without error`.
   - Git working tree status via `git status --short` shows `M .gitignore`, `?? .agents/`, `?? skills.md`. Zero `.elc` artifacts exist in source tree.
2. **Contracts Baseline (`kargu/contract/`):**
   - `kargu/contract.el` (lines 14–17) loads only:
     ```elisp
     (require 'kargu/contract/constants)
     (require 'kargu/contract/result)
     (require 'kargu/contract/types)
     (require 'kargu/contract/assert)
     ```
   - In `kargu/contract/`, 7 files exist: `assert.el`, `constants.el`, `types.el`, `result.el`, `history.el`, `selection.el`, and `file-window.el`.
   - `history.el` defines struct `kargu-history` and `kargu-history-create`.
   - `selection.el` defines struct `kargu-selection` and `kargu-selection-create`.
   - `file-window.el` defines struct `kargu-file-window` and `kargu-file-window-create`.
   - All 7 contract files pass `checkdoc` with 0 warnings.
3. **Private Cross-Module Revision Call:**
   - In `kargu/files.el` (line 142), `kargu-file--file-revision (path)` is private.
   - In `kargu/tools/diff/track.el` (line 47):
     ```elisp
     (defun kargu-diff--disk-revision (path)
       "Return `kargu-file-revision' for PATH on disk, or nil when absent."
       (when (file-exists-p path)
         (ignore-errors (kargu-file--file-revision path))))
     ```
   - No public `kargu-file-current-revision` is defined in `kargu/files.el`.
4. **Missing Contracts Inventory:**
   - File `architecture-contracts.md` does not exist in repository root (`find_by_name` returned 0 results).
5. **Application & Session State:**
   - In `kargu/application/coordinator.el` (lines 19–23, 142, 170–178):
     `kargu-application--context` is a global fallback singleton; `kargu-application-current-run` falls back to `kargu--loop-run`; `kargu-application-set-active-run` mutates `kargu--loop-run`.
   - In `kargu/core/session.el` (lines 44, 87–103):
     `kargu-session--context` is buffer-local, but relies on buffer-local `kargu--session-id` and global hook `kargu-session-before-replace-hook`.
   - In `kargu/state/store.el` (lines 21, 61–80):
     `kargu--state-store` is a global plist; `kargu-state-get` reads from `(kargu-session-context)` and `(kargu-application-current-status)` without taking an application/session parameter.
   - In `kargu/async.el` (lines 16, 31, 48–50):
     `kargu-async--pending` is a global list; `kargu-async-start` binds `:owner kargu--loop-run`; `kargu-async-pending-p` checks `(eq (kargu-async-task-owner task) kargu--loop-run)`.

## 2. Logic Chain
1. From Observation 1: The current repository is in a strictly verified, 100% passing state (942/942 ERT, TLC proof operational, clean hygiene). Any refactoring in Wave 0 must preserve this exact stability.
2. From Observation 3: In `kargu/tools/diff/track.el:47`, Package B's code accesses the internal helper `kargu-file--file-revision` from `kargu/files.el`. Because `parallel-plan.md` Section 3 mandates that Wave 0 must remove cross-module private calls before Wave 1/B starts, coordinator must define a public `kargu-file-current-revision` in `kargu/files.el` and update `kargu/tools/diff/track.el` to call it.
3. From Observation 4: `parallel-plan.md` Section 3 specifies `architecture-contracts.md` as the target contract inventory across 8 core boundaries. Because the file is currently absent, coordinator must create it in Wave 0 to establish the interface specifications before parallel worker dispatch.
4. From Observation 5: While `kargu-application` and `kargu-logical-request` structs exist, application and state accessors still fall back to `kargu-application--context`, `kargu--loop-run`, `kargu--busy`, and `kargu--state-store`. Wave 0 must define the contract boundary requiring explicit handles, and establish the test fixture proving dual application isolation.

## 3. Caveats
- No changes to source code files were made during this investigation (strictly read-only).
- External network-dependent providers (live OpenAI/OpenRouter APIs) were not tested; all assertions rely on local ERT suites, fake agents, and formal specifications.
- Did not modify or stage `.gitignore`, `skills.md`, or `.agents/`.

## 4. Conclusion
The codebase baseline is solid and ready for Wave 0 stabilization. To fulfill Wave 0 requirements before launching Wave 1 workers, the Wave 0 coordinator needs to:
1. Expose public `kargu-file-current-revision` in `kargu/files.el` and update `kargu/tools/diff/track.el:47` to eliminate the private call.
2. Author `architecture-contracts.md` documenting the 8 target boundary contracts.
3. Provide an isolated dual-application fixture in tests ensuring two independent application coordinator instances do not mutate shared state.
4. Update `todo.md` tracking.

## 5. Verification Method
1. Inspect survey report: `view_file` on `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_survey_1/survey_codebase_report.md`.
2. Verify ERT baseline:
   `emacs -Q --batch -L . --eval '(progn (require (quote package)) (package-initialize) (dolist (f (directory-files "tests" nil "^test-.*\\.el$")) (require (intern (concat "tests/" (file-name-sans-extension f))))))' -f ert-run-tests-batch-and-exit`
3. Verify TLC model checking:
   `bash proof/run_tlc.sh --edit-transaction`
4. Inspect private function call in track.el:
   `grep -n "kargu-file--file-revision" kargu/tools/diff/track.el`
