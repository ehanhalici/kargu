# BRIEFING — 2026-10-22T04:06:30Z

## Mission
Empirical challenge and stress-testing of Tool Execution Gate, Approvals, and Process/Job Lifecycle (RISK-01) for Wave 2.

## 🔒 My Identity
- Archetype: empirical-challenger
- Roles: critic, specialist
- Working directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave2_1
- Original parent: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Milestone: Dalga 2
- Instance: 1 of 1

## 🔒 Key Constraints
- Review-only — do NOT modify implementation code
- Run tests and empirical stress tests directly via batch Elisp scripts
- Verify RISK-01 and Contract 5 empirically
- Deliver verdict: APPROVE or REQUEST_CHANGES

## Current Parent
- Conversation ID: 246e42bd-e1b7-4f73-8026-d90704dd17ec
- Updated: 2026-10-22T04:06:30Z

## Review Scope
- **Files to review**: `kargu/tools/execution.el`, `kargu/tools/registry.el`, `kargu/permission/*.el`, `kargu/tools/process.el`, `kargu/tools/bash/jobs.el`, `kargu/tools/process/session.el`
- **Interface contracts**: `parallel-plan.md` (Section 5: Dalga 2), `architecture-contracts.md` (Contract 5: Tool Registry & Execution Gate)
- **Review criteria**: Mode gating, approval single-use, policy revision staleness, registry draining, process tree cancellation (RISK-01), dead process wait loop

## Attack Surface
- **Hypotheses tested**:
  1. Mutating tools (`edit_file`, `bash`, `git_commit`) are blocked in `ask` and `plan` modes by the gate. -> FAILED (Bug confirmed).
  2. Single-use approval tokens cannot be replayed for general tools. -> FAILED (Bug confirmed: non-bash tokens are never claimed).
  3. Policy specification allows `:needs-approval-p`. -> FAILED (Bug confirmed: contract assertion in registry.el rejects it).
  4. Policy revision staleness blocks obsolete approval tokens. -> PASSED.
  5. Registry draining blocks new invocations with `:tool-draining`. -> PASSED.
  6. Process cancellation with background child forks leaves no orphan. -> PASSED.
  7. Dead process wait loop with `nil` avoids 100% CPU spin. -> PASSED.
- **Vulnerabilities found**:
  - Critical: Mode Gating Bypass at Execution Gate (`execution.el` does not check `kargu-loop-mutating-tools` and real tools lack `:policy '(:modes (agent))`; `edit_file` modifies disk in `ask`/`plan` modes if session state is `agent`).
  - Critical: Approval Token Replay on Non-Bash Tools (`execution.el` lines 445-470 only claims token if `needs-appr` is non-nil, which is nil for non-bash tools; tokens remain `claimed-p = nil` and can be replayed infinitely).
  - High: Contract Inconsistency in `kargu-tool-registry--policy-p` (`registry.el` only allows `(:modes :available-p)` and rejects `:needs-approval-p` with a contract violation).
- **Untested angles**: None within Wave 2 gate/process scope.

## Loaded Skills
- None specified

## Key Decisions Made
- Verdict: REQUEST_CHANGES based on 3 critical/high reproducible empirical vulnerabilities in Package D.
- Package F (Process lifecycle, RISK-01) is empirically robust and verified.

## Artifact Index
- DISPATCH.md — Initial dispatch message
- challenge_report.md — Detailed empirical challenge report with benchmarks and reproduction scripts
- handoff.md — 5-component handoff report with verdict REQUEST_CHANGES
