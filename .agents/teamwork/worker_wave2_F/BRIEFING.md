# BRIEFING — 2026-10-22T03:33:00Z

## Mission
Implement Wave 2 Package F: Process/Job Ownership & Cancellation Lifecycle, resolving RISK-01, implementing kargu-job-service and interactive session transport, enhancing test suites, and verifying TLA+ proof.

## 🔒 My Identity
- Archetype: worker
- Roles: implementer, qa, specialist
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/worker_wave2_F
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Wave 2 Package F

## 🔒 Key Constraints
- Scope & Exclusive Write Allowlist:
  - `kargu/tools/process.el`
  - `kargu/tools/bash.el`
  - `kargu/tools/bash/jobs.el`
  - `kargu/tools/toolchain.el`
  - New: `kargu/tools/process/session.el`
  - Tests: `tests/test-process.el`, `tests/test-tools.el`, new `tests/test-job-owner.el`, `tests/test-process-stress.el`, new `tests/test-process-session.el`
  - Proof: `proof/KarguProcess.tla`, `proof/ProcessMC.tla`, `proof/ProcessMC.cfg`
- NEVER modify or stage skills.md, .gitignore, or .agents/.
- Do NOT touch files owned by Package D or Package E.
- Zero byte-compilation warnings with byte-compile-error-on-warn t.
- Checkdoc clean.
- Zero .elc files remaining in repo.
- TLC model checker pass for proof/run_tlc.sh --process.
- Genuine implementations only — no cheating or hardcoding.

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-22T03:33:00Z

## Task Summary
- **What to build**:
  1. Fix RISK-01 in `kargu/tools/process.el` (accept-process-output nil, pgid signaling).
  2. Implement `kargu-job-service` in `kargu/tools/bash/jobs.el` with project-root scoping and backwards-compat globals.
  3. Implement `kargu/tools/process/session.el` for interactive streaming sessions.
  4. Test suites: `tests/test-job-owner.el`, `tests/test-process-stress.el`, `tests/test-process-session.el`, `tests/test-process.el`.
  5. Verified TLA+ specs: `proof/KarguProcess.tla`, `ProcessMC.tla`, `ProcessMC.cfg`.
- **Success criteria**: All 44 Package F ERT tests pass, zero warnings on byte-compile with byte-compile-error-on-warn t, checkdoc clean, TLC verification passes (179 distinct states, 0 errors), report & handoff written.
- **Interface contracts**: PROJECT.md, todo.md, explorer_wave2_F report.
- **Code layout**: Root repo at `/home/emrehan/.emacs.local/kargu`.

## Key Decisions Made
- Stored `kargu-pgid` on process objects at launch to ensure negative-PID process group signaling `(- pgid)` reaps child process groups even after the parent process handle exits.
- Used `(accept-process-output nil 0.02)` during wait loops to prevent dead process busy-spinning and CPU starvation of asynchronous descriptors (such as stderr pipe sentinels).
- Encapsulated shell jobs in `kargu-job-service` keyed by canonical project root while maintaining backwards-compatible synchronized global aliases.
- Implemented `kargu-process-session` with bounded buffer retention, idle timeout watcher, clean stdin EOF handling, and structured kill.
- Modularized test requires so test suites do not depend on monolithic `kargu.el` facade.

## Artifact Index
- `.agents/teamwork/worker_wave2_F/DISPATCH.md` — Assigned instructions
- `.agents/teamwork/worker_wave2_F/BRIEFING.md` — Agent working memory
- `.agents/teamwork/worker_wave2_F/progress.md` — Liveness and status heartbeat
- `.agents/teamwork/worker_wave2_F/worker_F_report.md` — Final report
- `.agents/teamwork/worker_wave2_F/handoff.md` — Handoff report

## Change Tracker
- **Files modified**:
  - `kargu/tools/process.el`: pgid capture, process group signaling, grace-seconds support
  - `kargu/tools/bash/jobs.el`: kargu-job-service struct, project-root scoping, structured cancellation, compat bridges
  - `kargu/tools/process/session.el`: new interactive session transport with idle timeout and bounded buffers
  - `tests/test-process.el`: updated wait loops to use `accept-process-output nil` and modular requires
  - `tests/test-job-owner.el`: new test suite for job service isolation, counter, pruning, structured cancel
  - `tests/test-process-stress.el`: new test suite for RISK-01 stress anomaly, process group reaping, non-starvation
  - `tests/test-process-session.el`: new test suite for interactive session transport
- **Build status**: PASS (all 44 tests pass, zero byte-compile warnings, zero checkdoc warnings, TLC passes)
- **Pending issues**: None

## Quality Status
- **Build/test result**: PASS (44/44 Package F tests pass; TLC --process passes: 535 states, 179 distinct, 0 errors)
- **Lint status**: Clean (checkdoc 0 warnings, byte-compile 0 warnings with byte-compile-error-on-warn t)
- **Tests added/modified**: 15 new tests added across 3 new test files; `tests/test-process.el` updated

## Loaded Skills
- None specified
