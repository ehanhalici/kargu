## 2026-10-22T04:40:12Z

You are explorer_wave3_H, working as Wave 3 Package H Explorer (Owned View, Selection, Catalog & Plan Services).
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_H

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 6: Dalga 3, Package H)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Contract 1, Contract 4, Contract 7)
- /home/emrehan/.emacs.local/kargu/todo.md (MOD-01, MOD-06, MOD-07, ARCH-01, ARCH-06, ARCH-09, ARCH-12, ARCH-19, ARCH-08)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/handoff.md

Scope & Tasks:
1. Analyze existing view, selection, catalog, and plan files:
   - `kargu/chat.el`, `kargu/chat/routing.el`, `kargu/chat/render.el`, `kargu/chat/stream.el`, `kargu/chat/transcript.el`, `kargu/chat/prompt.el`, `kargu/chat/header.el`, `kargu/chat/select.el`, `kargu/chat/complete.el`, `kargu/chat/attach.el`, `kargu/chat/tune.el`, `kargu/chat/plan.el`
   - `kargu/selection.el`, `kargu/api/select.el`, `kargu/api/catalog.el`, `kargu/models/store.el`, `kargu/providers.el`, `kargu/providers/catalog.el`
   - `kargu/plan.el`, `kargu/plan/context.el`, `kargu/plan/store.el`, `kargu/plan/dispatch.el`, `kargu/plan/buffer.el`
   - `kargu/ui.el`, `kargu/ui/confirm.el`, `kargu/ui/notify.el`, `kargu/ui/transient.el`
   - Tests: `tests/test-chat.el`, `tests/test-chat-state.el`, `tests/test-selection.el`, `tests/test-model-store.el`, `tests/test-metadata.el`, `tests/test-dynamic-models.el`, `tests/test-confirm.el`, `tests/test-plan.el`, `tests/test-plan-async.el`, `tests/test-attach.el`
   - Proof: `proof/KarguSelection.tla`, `proof/SelectionMC.tla`, `proof/SelectionMC.cfg`, `proof/KarguPlan.tla`, `proof/PlanMC.tla`, `proof/PlanMC.cfg`
2. Design Catalog & Metadata Service:
   - Move catalog generation, cache, and refusal tables to explicit provider/model service (`kargu/providers/catalog.el`, `kargu/api/catalog.el`).
   - Bind capability revisions to Package C/E connection snapshots. Immutable snapshot consumers must not re-query mutable metadata during active runs.
   - Preserve clean distinctions between `off`, `none`, `inherit`, and successful-empty catalogs.
3. Design Owned View & Selection:
   - Decouple selection state from global chat buffers; buffer views observe Package A application coordinator and Package G engine events.
   - Do NOT create a secondary state store inside UI transcript/draft/selection.
   - Enforce bounded and coalesced UI render queues; keep Stop accessible at all times during heavy streaming.
   - Scope pending confirmations by view/job handles rather than a shared global pending list.
4. Design Plan Dispatcher:
   - Plan dispatcher calls application port rather than private internal loop functions.
   - Preserve claim, approved revision, draft state, and mode preparation.
   - Buffer close cleanly releases subscriptions, watchers, and model picker resources.
   - Note: Split-buffer/header-line layout experiment is NOT part of this scope; preserve existing markers and UX.
5. Design new test suite:
   - `tests/test-view-lifetime.el` (verifying two projects/views, focus safety on delayed responses, stream preservation during point/narrowing/IME, observer Stop, confirmation close, model service isolation, buffer close resource release).
6. Formal Models & TLC:
   - Inspect `proof/KarguSelection.tla` and `proof/KarguPlan.tla`, and check TLC model checking setup in `proof/run_tlc.sh`.
7. Output:
   - Provide concrete before/after code blocks, signatures, and implementation blueprint for Worker H.
   - Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_H/package_H_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_H/handoff.md`.
   - Send completion message to caller via send_message.
