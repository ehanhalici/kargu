# Handoff Report: Survey Specification Mining (Waves 0–5 & Packages A–O)

**Agent**: `teamwork_preview_spec_miner_survey_2` (Survey Spec Miner)  
**Date**: 2026-10-21  
**Destination Report**: `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_survey_2/survey_spec_matrix.md`

---

## 1. Observation

Direct observations extracted verbatim from authoritative specification documents:

1. **Original Request Scope & Constraints**:
   - In `/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md` (lines 15–28):
     - "Implement all packages defined in `parallel-plan.md` in strict wave order: Wave 0 ... Wave 1 (Packages A, B, C) ... Wave 2 (Packages D, E, F) ... Wave 3 (Packages G, H, I) ... Wave 4 (Packages J, K, L) ... Wave 5 (Packages M, N, O)."
     - "Adhere to the single-active-run invariant per Emacs application instance (ARCH-01/ARCH-12)."
     - "Remove global mutable singleton variables when their consumers are migrated to owned application/session contexts."
     - "Feature adapters must be pluggable/detachable without breaking core offline functionalities (ARCH-09)."
     - "Never modify or stage `skills.md`, `.gitignore`, or `.agents/`; protect the user's working tree."
     - Acceptance criteria: 100% passing ERT test suite (929+ tests), zero byte-compilation warnings with `(setq byte-compile-error-on-warn t)`, zero checkdoc warnings on new/modified production and test files, exhaustive TLC passes via `proof/run_tlc.sh`.

2. **Parallel Plan Execution Structure & Invariants**:
   - In `/home/emrehan/.emacs.local/kargu/parallel-plan.md` (lines 30–35):
     - "Çalıştırma düzeni: koordinatör + en fazla üç işçi. Aynı dalgadaki üç görev paraleldir; dalgalar arası kabul kapısı seridir. Tek bir Emacs uygulamasında yine **tek aktif run** vardır."
   - In `/home/emrehan/.emacs.local/kargu/parallel-plan.md` (lines 45–47):
     - "Her dalga bir öncekinin **entegre edilmiş revision'ından** başlar. Erken biten işçi sonraki dalgaya kendiliğinden geçmez."
   - In `/home/emrehan/.emacs.local/kargu/parallel-plan.md` (lines 49–61):
     - Common worker rules: read `skills.md`, `todo.md`; never stage `skills.md`; use dedicated worktree/branch; write allowlists are strict; do not change shared contracts or peer records directly; test fail/cleanup before success; no mutable singletons or general event-bus frameworks; deliver commit hashes, modified files, removed legacy paths, test commands, TLC scope.
   - In `/home/emrehan/.emacs.local/kargu/parallel-plan.md` (lines 75–80):
     - Wave 0 bootstrap: Coordinator exposes `kargu-file-current-revision` in `kargu/files.el` as public API prior to Wave 1 so Package B can eliminate private calls. Write ownership of `kargu/files.el` shifts to Package L in Wave 4.
   - In `/home/emrehan/.emacs.local/kargu/parallel-plan.md` (lines 351–356):
     - Package O allowlist: strictly 18 test files (`test-api.el`, `test-async.el`, `test-attach.el`, `test-chat.el`, `test-compact.el`, `test-confirm.el`, `test-contract.el`, `test-dynamic-models.el`, `test-fake-agent.el`, `test-heal.el`, `test-history.el`, `test-languages.el`, `test-loop.el`, `test-lsp.el`, `test-metadata.el`, `test-permission.el`, `test-session.el`, `test-state.el`).
     - Explicit exclusion from Package O: `tests/test-deps.el`, `tests/test-git.el`, `tests/test-security.el`, `tests/test-webfetch.el` are owned by Package N; `tests/test-integration.el` is owned by Coordinator.
   - In `/home/emrehan/.emacs.local/kargu/parallel-plan.md` (lines 380–405):
     - Complete mapping of 48 TODO items to their owners and resolution criteria.

3. **Existing Verification & Test Baseline**:
   - `proof/run_tlc.sh` exists and models:
     - 15 flags/modes: default (`MC.tla`), `--plan` (`PlanMC.tla`), `--mode` (`ModeMC.tla`), `--restore` (`RestoreMC.tla`), `--selection` (`SelectionMC.tla`), `--approval` (`ApprovalMC.tla`), `--process` (`ProcessMC.tla`), `--diagnostics` (`DiagnosticsMC.tla`), `--debug-startup` (`DebugStartupMC.tla`), `--debug-close` (`DebugCloseMC.tla`), `--debug-watch` (`DebugWatchMC.tla`), `--debug-execution` (`DebugExecutionMC.tla`), `--edit-transaction` (`EditMC.tla`), `--verification` (`VerificationMC.tla`), `--debug-selection` (`DebugSelectionMC.tla`), `--debug-readiness` (`DebugReadinessMC.tla`).
   - `proof/` directory currently contains 56 files, including existing specs, cfgs, and scripts.
   - Depo baseline: 942/942 ERT tests pass, zero compile errors, TLC verified.

---

## 2. Logic Chain

1. **Step 1: Mapping Objectives to Structural Boundaries**:
   - From `ORIGINAL_REQUEST.md` R1 and `parallel-plan.md` §2, the refactoring spans 6 sequential waves (Wave 0 through Wave 5) and 15 packages (A through O), partitioned into 3 parallel workers per wave plus the Coordinator.
   - Because each wave is gated serially, the specification must establish strict boundaries: allowlisted files per package, contract interfaces, and integration gates.

2. **Step 2: Guaranteeing File and State Ownership**:
   - From `parallel-plan.md` §2 and §3, workers write strictly to their allowlists. If two workers need to interact, they do so through typed public contracts published by the Coordinator in Wave 0 or integrated at wave boundaries.
   - For example, Package B in Wave 1 requires file revision reading from `kargu/files.el`, but `kargu/files.el` write ownership belongs to Package L in Wave 4. The Coordinator solves this by publishing `kargu-file-current-revision` in Wave 0 before Wave 1 begins.
   - Similarly, in Wave 5, Package O's checkdoc cleanup is restricted to 18 test files to avoid merge conflicts with Package N (which touches `test-deps.el`, `test-git.el`, `test-security.el`, `test-webfetch.el`) and the Coordinator (`test-integration.el`).

3. **Step 3: Maintaining Invariants Across Parallel Worktrees**:
   - The Single-Active-Run invariant (ARCH-01/ARCH-12) must hold across all execution modes (UI, headless loop, fake backend). By encapsulating run coordination in an explicit `kargu-application` struct, parallel worker branches can develop without global mutable collision.
   - Pluggable Adapters (ARCH-09) ensure that omitting optional tools (LSP, Dape, webfetch, bash, git) does not impair core headless execution. Missing capabilities return typed `unavailable` states, and security checks fail closed.

4. **Step 4: Formal Verification & Defect Closure**:
   - From `todo.md`, each TODO item is assigned to a specific package owner. Open risks (RISK-01 stderr timing anomaly, RISK-02 sampling compatibility) require reproducible versioned fixtures; they must NOT be closed prematurely via test reruns or timeout increases.
   - TLA+ model checking is coupled to package deliveries: Package A adds `KarguBudget`, Package C adds `KarguConnection`, Package E adds `KarguTransport`, Package M adds `KarguBackend`, and Package L conditionally adds `KarguWriter`.

5. **Step 5: Synthesizing the Complete Specification Matrix**:
   - All these dimensions were systematically compiled into `/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_survey_2/survey_spec_matrix.md`, covering Wave/Package attributes, allowlists, acceptance criteria, cross-cutting invariants, 39 discovered features, 30 edge cases, and the 48-item TODO index.

---

## 3. Caveats

- **External Protocol Implementations Out of Scope**: Real external agent/CLI connections (MCP, Claude Code, Cursor, Codex, OpenCode) and custom DAP client implementations are explicitly deferred to post-Wave 5 plans. Only fake backend ports and contracts are in scope.
- **Experimental Layouts Deferred**: Split-buffer, multi-window chat UI redesigns, and recursive multi-stage compaction are optional design choices and must not block core architectural integration.
- **Unreproduced Risks Remain Open**: If RISK-01 or RISK-02 cannot be deterministically reproduced with concrete fixtures during Waves 2 and 5, they must remain documented as open risks in `todo.md` rather than being marked closed.
- **Read-Only Investigation**: As a specification miner, no source code, test files, or proofs were modified during this investigation.

---

## 4. Conclusion

The specification mining for Kargu's multi-wave architectural transformation is complete and fully documented in:
`/home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_survey_2/survey_spec_matrix.md`

The matrix provides an exhaustive, unambiguous blueprint for the Coordinator and Worker roles across Waves 0 through 5:
- All 15 Packages (A through O) and Wave 0 have exact file allowlists (production, new, test, proof).
- Cross-cutting invariants (Single-Active-Run ARCH-01/ARCH-12, Pluggable Adapters ARCH-09, Strict Wave Sequencing, and Protected Paths) are formally defined with enforcement rules.
- 39 distinct features and 30 concrete edge case behaviors are cataloged.
- All 48 TODO items from `todo.md` are mapped to their respective package owners and acceptance boundaries.

---

## 5. Verification Method

To independently verify the findings in this report:

1. **Inspect Artifact Files**:
   - View the complete specification matrix:
     `view_file /home/emrehan/.emacs.local/kargu/.agents/teamwork/spec_miner_survey_2/survey_spec_matrix.md`
   - Cross-check against authoritative sources:
     `view_file /home/emrehan/.emacs.local/kargu/parallel-plan.md`
     `view_file /home/emrehan/.emacs.local/kargu/todo.md`
     `view_file /home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md`

2. **Verify Repository Worktree Integrity**:
   - Run `git status` to ensure `skills.md`, `.gitignore`, and `.agents/` are untouched:
     ```bash
     git status --porcelain
     ```

3. **Verify Baseline Test & Model Checker Suite**:
   - Execute the ERT test suite:
     ```bash
     emacs -Q --batch -L . \
       --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" \
       -f ert-run-tests-batch-and-exit
     ```
   - Run TLC model checker:
     ```bash
     ./proof/run_tlc.sh
     ```
