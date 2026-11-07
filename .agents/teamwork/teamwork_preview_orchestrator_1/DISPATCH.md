## 2026-10-21T20:04:29Z

You are teamwork_preview_orchestrator_1, the Project Orchestrator.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md
- /home/emrehan/.emacs.local/kargu/todo.md

Your mission:
Execute the end-to-end multi-wave parallel architecture transformation and verification of Kargu according to `parallel-plan.md`, covering Wave 0 through Wave 5 with coordinator and parallel worker roles.

Key Requirements:
1. Multi-Wave Architectural Transformation (Waves 0–5) in strict wave order:
   - Wave 0: Contract boundaries, type definitions, test fixtures (kargu.el, kargu/core.el, kargu/contract/*.el, tests/test-helpers.el, tests/test-modules.el).
   - Wave 1: Package A (Application/coordinator/budget/async ownership), Package B (Owned edit service and approval identity), Package C (Async credential discovery and connection snapshot).
   - Wave 2: Package D (Single gate for tool registry and execution), Package E (Bounded transport and circuit breakers), Package F (Process/job ownership and cancellation lifecycle).
   - Wave 3: Package G (Headless engine/loop, history protocol wall, unified budget accounting), Package H (Owned view, selection, catalog and plan services), Package I (Log data minimization, redaction and bounded retention).
   - Wave 4: Package J (LSP capability, freshness, exact coordinate conversion), Package K (Dape debugger adapter boundary and resource cleanup), Package L (Filesystem writer contracts, conflict resolution and persistence data lifecycle).
   - Wave 5: Package M (Fake agent backend port and contract suite), Package N (Provenance, egress policy and structured shell/tool trust), Package O (Checkdoc and test lint hygiene).

2. Architectural Integrity:
   - Adhere to single-active-run invariant per Emacs application instance (ARCH-01/ARCH-12).
   - Remove global mutable singleton variables when migrated to owned contexts.
   - Feature adapters must be pluggable/detachable without breaking core offline functionalities (ARCH-09).
   - NEVER modify or stage `skills.md`, `.gitignore`, or `.agents/`. Protect the user's working tree.

3. Programmatic Verification & Proofs:
   - Maintain 100% passing rate across ERT test suite (929+ tests):
     emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
   - Zero byte-compilation warnings on all modified/new Elisp files under kargu/ and tests/ with (setq byte-compile-error-on-warn t).
   - Clean up any temporary .elc files before completion.
   - All relevant TLA+ specs under proof/ run TLC model checking (proof/run_tlc.sh).
   - Update todo.md with evidence for each completed item.

Coordinate and dispatch subagents per your standard orchestration protocol. Maintain progress.md and BRIEFING.md in your working directory. Regularly update progress.md so progress can be monitored. When all waves and acceptance criteria are completed and verified, deliver your completion report with evidence back to Sentinel.
