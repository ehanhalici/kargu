# BRIEFING — 2026-10-21T23:34:00Z

## Mission
Analyze process and job ownership, cancellation lifecycle, RISK-01 stderr close stress anomaly, and design package F deliverables for Worker F.

## 🔒 My Identity
- Archetype: explorer
- Roles: investigation, synthesis
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave2_F
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Dalga 2, Package F (Process/Job Ownership & Cancellation Lifecycle)

## 🔒 Key Constraints
- Read-only investigation — do NOT implement in source code
- Produce structured analysis report and 5-component handoff report
- Address RISK-01, DEEP-05/12/15, ARCH-17/18
- Check TLA+ formal model and model checking

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-21T23:23:49Z

## Investigation State
- **Explored paths**:
  - `kargu/tools/process.el`: Process launching, filter buffering, stderr pipe process sentinel, deadline timer, `kargu-process-cancel`.
  - `kargu/tools/bash.el` & `kargu/tools/bash/jobs.el`: Foreground/background jobs, global state (`kargu-bash--processes`, `kargu-bash--counter`, `kargu-bash--active-async-proc`), `kargu-bash-manage-job`.
  - `kargu/tools/toolchain.el`: Strategy pattern detection for build/test commands.
  - `tests/test-process.el` & `tests/test-tools.el`: Process and bash ERT suites.
  - `proof/KarguProcess.tla` & `ProcessMC.tla`: TLA+ model checking verified with 0 errors via `proof/run_tlc.sh --process`.
- **Key findings**:
  - **RISK-01 Root Cause #1**: `tests/test-process.el:255` used `(accept-process-output process 0.02)` where `process` had already exited. Dead process handle in `accept-process-output` returns in microseconds without sleeping, running ~75,000 tight-spins in 0.5s, starving asynchronous pipe sentinels and signal handlers. Fix: use `(accept-process-output nil 0.02)`.
  - **RISK-01 Root Cause #2**: `kargu-process-cancel` failed to signal the process group when `(process-live-p process)` was nil (e.g. parent shell exited, but background child was still running). Furthermore, `kill-process` only signals single PID, not process group `-pid`. Background child was leaked as orphan reparented to PID 1. Fix: store PGID on process object (`process-put proc 'kargu-pgid (process-id proc)`), signal process group `(- pid)` with SIGKILL (or SIGINT -> SIGKILL).
  - **ARCH-17/DEEP-05**: Move global jobs state into `kargu-job-service` struct keyed by project root, with structured multi-phase cancellation (graceful close -> deadline -> force kill).
  - **DEEP-05**: Evaluated `kargu/tools/process/session.el` for interactive long-lived CLI sessions without PTY framework bloat.
- **Unexplored areas**: None.

## Key Decisions Made
- Confirmed RISK-01 reproduction and concrete fix.
- Designed `kargu-job-service` with seamless backwards-compatibility synchronization for existing variables.
- Designed `kargu/tools/process/session.el` and test suites: `tests/test-job-owner.el`, `tests/test-process-stress.el`, and `tests/test-process-session.el`.

## Artifact Index
- DISPATCH.md — incoming dispatch message
- progress.md — liveness heartbeat
- BRIEFING.md — working memory
- package_F_report.md — detailed architectural investigation report
- handoff.md — 5-component handoff report
