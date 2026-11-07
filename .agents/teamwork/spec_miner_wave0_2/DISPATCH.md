## 2026-10-21T20:20:11Z
You are teamwork_preview_spec_miner_wave0_2, working as Wave 0 Architecture Contracts Spec Miner.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also read:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (especially Section 3: lines 62-102)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_survey_2/survey_spec_matrix.md
- /home/emrehan/.emacs.local/kargu/kargu/contract/*.el

Scope & Boundaries:
You are a READ-ONLY specification investigator. Do not modify source code files. Write only to your working directory.

Tasks:
1. Draft the complete, authoritative `architecture-contracts.md` file required by Wave 0 at the repository root.
2. For each of the 8 core boundaries (Application, Async scope, Edit, Connection, Tool, Budget, Events, Results):
   - Producer / Consumer roles
   - Required vs optional dependencies
   - Input / output types (referencing existing structs from kargu/contract/*.el or new contract types)
   - Validation owner
   - State & lifecycle events (creation, transition, terminal, cancel, release)
   - Ownership, cleanup, and cancellation invariants
3. Ensure the contracts reflect the exact target names, invariants, and decisions specified in parallel-plan.md §3 and survey_spec_matrix.md.
4. Provide the complete text of `architecture-contracts.md` ready for the Worker to write to `/home/emrehan/.emacs.local/kargu/architecture-contracts.md`.
5. Write your detailed report to:
   /home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/wave0_contracts_report.md
   and write a summary in:
   /home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_wave0_2/handoff.md
6. Send completion message via send_message to caller.
