# BRIEFING — 2026-10-21T22:44:00Z

## Mission
Adversarial empirical stress-testing of Package A (Budget, Coordinator, Async) and Package B (Edit Service, Frozen Approval, Worktree Safety) to discover bugs and verify invariants under extreme conditions.

## 🔒 My Identity
- Archetype: empirical-challenger
- Roles: critic, specialist
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave1_1
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Wave 1 Stress Testing (Packages A & B)
- Instance: 1 of 1

## 🔒 Key Constraints
- Review-only — do NOT modify implementation code
- Run verification code empirically (batch Elisp); do NOT trust claims or logs
- .agents/teamwork/ holds only metadata — test scripts/code must NOT be placed here
- Provide APPROVE or REQUEST_CHANGES verdict based on findings

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: not yet

## Review Scope
- **Files reviewed**:
  - `kargu/application/budget.el`
  - `kargu/application/coordinator.el`
  - `kargu/application/reset.el`
  - `kargu/async.el`
  - `kargu/tools/diff/context.el`
  - `kargu/tools/diff.el`
  - Existing test suites in `tests/`
- **Interface contracts**:
  - Contracts 1, 2, 3, 6 in `/home/emrehan/.emacs.local/kargu/architecture-contracts.md`
  - Section 4 in `/home/emrehan/.emacs.local/kargu/parallel-plan.md`

## Attack Surface
- **Hypotheses tested**:
  1. Negative or zero token/request/compaction limits could corrupt budget counters: REJECTED (fail-closed contract assertions enforce positivity).
  2. Submitting debits to exhausted or sealed budgets could leak turns: REJECTED (debits return :budget-exhausted with typed reasons).
  3. Deadline expiry mid-execution might be ignored during ongoing run: REJECTED (transitions to :exhausted-deadline and denies debit).
  4. Second context compaction turn could bypass single-compaction bound: REJECTED (fails with :exhausted-compactions).
  5. Cancelling parent async task might miss deeply nested child tasks or leak timers: REJECTED (all descendants cancelled recursively, cleanups invoked, timers released).
  6. Cancelling parent async task might cancel unrelated siblings or tasks under different owners: REJECTED (sibling isolation preserved).
  7. Application reset (`kargu-session-reset`) might inadvertently clear foreign claims or reset global circuits: REJECTED (foreign runs/claims preserved).
  8. Concurrent edit services on same/different files might contaminate snapshot/change tables: REJECTED (strict table isolation verified).
  9. Changes to buffer, disk file, policy revision, or session after plan capture might be silently overwritten: REJECTED (fails with :conflict, :policy-conflict, :session-conflict).
  10. Closed edit service might accept subsequent edits: REJECTED (fails with :service-closed).
  11. Unified diff / patch operations might modify or stage into user's git index: REJECTED (`git diff --cached` and `git status --short` byte-for-byte identical before/after).
- **Vulnerabilities found**: None. All invariants held under adversarial conditions.
- **Untested angles**: Multi-threaded or remote TRAMP edit pipelines (out of Wave 1 scope).

## Loaded Skills
- None

## Key Decisions Made
- Created `tests/test-wave1-empirical-challenge.el` containing 9 comprehensive adversarial tests and standalone batch runner `wave1-run-empirical-challenges`.
- Verified batch execution via `emacs -Q --batch` and ERT.
- Verified TLA+ proofs `BudgetMC`, `EditMC`, `ModeMC` via `proof/run_tlc.sh`.
- Verdict: APPROVE.

## Artifact Index
- DISPATCH.md — Original dispatch message
- progress.md — Liveness heartbeat and progress log
- challenge_report.md — Detailed stress-test findings and results
- handoff.md — 5-component handoff report with verdict
- `tests/test-wave1-empirical-challenge.el` — Executable test suite
