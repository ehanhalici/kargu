# BRIEFING — 2026-10-21T21:05:00Z

## Mission
Empirically challenge Wave 0 implementations (`kargu-file-current-revision`, coordinator claim/release/active-run invariants) via executable stress scripts.

## 🔒 My Identity
- Archetype: challenger
- Roles: critic, specialist
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave0_1
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: wave0-verification
- Instance: 1 of 1

## 🔒 Key Constraints
- Review-only — do NOT modify implementation code
- Run tests and verifications empirically, don't trust claims
- Write only to own folder /home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave0_1

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-21T20:57:42Z

## Review Scope
- **Files reviewed**:
  - `/home/emrehan/.emacs.local/kargu/kargu/files.el` (`kargu-file-current-revision`)
  - `/home/emrehan/.emacs.local/kargu/kargu/application/coordinator.el` (`claim`, `release`, `set-active-run`)
  - `/home/emrehan/.emacs.local/kargu/tests/test-application-context.el`
- **Interface contracts**: `/home/emrehan/.emacs.local/kargu/parallel-plan.md`
- **Review criteria**: correctness, edge-case resilience, invariant preservation

## Attack Surface
- **Hypotheses tested**:
  - File current revision on non-existent paths, empty/whitespace strings, buffer without file, killed buffer, modified buffer, narrowed buffer, directory, symlinks (valid, dangling, cyclic), remote Tramp paths.
  - Coordinator concurrent claims, claim with active logical request, foreign claim release, multiple releases, claim after release, reset while active.
  - Single active run invariant via direct set, claim, and interleaving.
- **Vulnerabilities found**:
  - BUG-04 (CRITICAL): `kargu-application-claim` prematurely advances `generation` in `let*`, causing `work-active-p` to ignore active in-flight request.
  - BUG-06 (HIGH): `kargu-application-release` does not check `claim-app == target`, allowing foreign claims with matching default run-id (`"run-1"`) to release unrelated apps.
  - BUG-01 (HIGH): `kargu-file-current-revision` calls `file-exists-p` before `file-remote-p`, causing synchronous network hang via Tramp.
  - BUG-02 (MEDIUM): `kargu-file-current-revision` returns non-nil revision for dangling symlinks due to `lstat`.
  - BUG-03 (MEDIUM): `kargu-file-current-revision` does not detect target file modification when checked via symlink.
  - BUG-05 (LOW): `kargu-application-claim` mutates generation counter on rejected claim attempts.
- **Untested angles**:
  - Out-of-scope Wave 1 packages (edit service, connection snapshot).

## Loaded Skills
- None

## Key Decisions Made
- Executed all empirical challenges via standard input in `emacs -Q --batch` to ensure zero test pollution or temporary files on disk.
- Delivered verdict: `REQUEST_CHANGES` based on 1 CRITICAL and 2 HIGH defects.

## Artifact Index
- `DISPATCH.md` — Dispatch log
- `BRIEFING.md` — Situational awareness
- `progress.md` — Liveness & progress tracking
- `challenge_report.md` — Detailed adversarial review & empirical evidence
- `handoff.md` — 5-component handoff report
