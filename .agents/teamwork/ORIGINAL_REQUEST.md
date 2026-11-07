# Original User Request

## 2026-10-21T20:03:11Z

Execute the end-to-end multi-wave parallel architecture transformation and verification of Kargu according to `parallel-plan.md`, covering Wave 0 through Wave 5 with coordinator and parallel worker roles.

Working directory: /home/emrehan/.emacs.local/kargu
Integrity mode: development

Reference specification: [parallel-plan.md](file:///home/emrehan/.emacs.local/kargu/parallel-plan.md)
Tracking source: [todo.md](file:///home/emrehan/.emacs.local/kargu/todo.md)

## Requirements

### R1. Multi-Wave Architectural Transformation (Waves 0–5)
Implement all packages defined in `parallel-plan.md` in strict wave order:
- **Wave 0**: Coordinator establishes contract boundaries, type definitions, and test fixtures (`kargu.el`, `kargu/core.el`, `kargu/contract/*.el`, `tests/test-helpers.el`, `tests/test-modules.el`).
- **Wave 1**: Package A (Application/coordinator/budget/async ownership), Package B (Owned edit service and approval identity), Package C (Async credential discovery and connection snapshot).
- **Wave 2**: Package D (Single gate for tool registry and execution), Package E (Bounded transport and circuit breakers), Package F (Process/job ownership and cancellation lifecycle).
- **Wave 3**: Package G (Headless engine/loop, history protocol wall, unified budget accounting), Package H (Owned view, selection, catalog and plan services), Package I (Log data minimization, redaction and bounded retention).
- **Wave 4**: Package J (LSP capability, freshness, exact coordinate conversion), Package K (Dape debugger adapter boundary and resource cleanup), Package L (Filesystem writer contracts, conflict resolution and persistence data lifecycle).
- **Wave 5**: Package M (Fake agent backend port and contract suite), Package N (Provenance, egress policy and structured shell/tool trust), Package O (Checkdoc and test lint hygiene).

### R2. Architectural Integrity and Modularity
- Adhere to the single-active-run invariant per Emacs application instance (ARCH-01/ARCH-12).
- Remove global mutable singleton variables when their consumers are migrated to owned application/session contexts.
- Feature adapters must be pluggable/detachable without breaking core offline functionalities (ARCH-09).
- Never modify or stage `skills.md`, `.gitignore`, or `.agents/`; protect the user's working tree.

### R3. Programmatic Verification and Formal Proofs
- Maintain 100% passing rate across the entire ERT test suite (929+ tests).
- All modified and new production and test Elisp files must compile cleanly with `byte-compile-error-on-warn t`.
- Updated state machines and protocols must pass exhaustive TLA+/TLC model checking via `proof/run_tlc.sh`.
- Update `todo.md` to reflect verified closures and remaining boundaries.

## Acceptance Criteria

### Test Suite and Compilation
- [ ] All ERT test suites pass with 0 failures and 0 errors:
  `emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit`
- [ ] Zero byte-compilation warnings on all modified and new Elisp files under `kargu/` and `tests/` with `(setq byte-compile-error-on-warn t)`.
- [ ] No temporary byte-compiled `.elc` files left in source directories.

### Formal Verification
- [ ] All relevant TLA+ specifications under `proof/` pass exhaustive TLC model checking without errors (`proof/run_tlc.sh`).

### Repository and Governance
- [ ] `skills.md`, `.gitignore`, and `.agents/` remain completely untouched and unstaged.
- [ ] `todo.md` is accurately updated with evidence for each completed ARCH/MOD/DEEP/CONFIG/RISK item.
- [ ] Final integration report summarizing commit hashes, modified files, removed legacy paths, and contract test results is provided.

## Follow-up — 2026-10-22T03:09:17Z

The quota has reset. Please check on the orchestrator in .agents/teamwork/teamwork_preview_orchestrator_1 and resume execution/monitoring.
