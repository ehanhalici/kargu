## 2026-10-22T04:40:12Z
sender=246e42bd-e1b7-4f73-8026-d90704dd17ec
priority=MESSAGE_PRIORITY_HIGH

You are explorer_wave3_I, working as Wave 3 Package I Explorer (Log Data Minimization & Bounded Retention).
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_I

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 6: Dalga 3, Package I)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Contract 4: Connection Snapshot, Contract 7: Events)
- /home/emrehan/.emacs.local/kargu/todo.md (DEEP-06, DEEP-07, ARCH-14, ARCH-15, ARCH-16, DEEP-15)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/handoff.md

Scope & Tasks:
1. Analyze existing logging implementation:
   - `kargu/core/log.el`
   - Related log/redact usages in `kargu/api/http.el`, `kargu/api/sse.el`, `kargu/tools/process.el`, `kargu/application/coordinator.el`
   - Existing tests: `tests/test-log.el`
2. Design Structured Secret Redaction (`kargu/core/redact.el`):
   - Default logging is metadata-only. Wire content logging requires explicit opt-in and privacy warning.
   - Known credentials, bearer tokens, API keys, and sensitive structured fields (e.g. `Authorization`, `x-api-key`, passwords) must be masked at the write boundary BEFORE appending to log buffers or temporary files.
   - Redactor errors must fail-closed: never fall back to unredacted raw content.
   - Design synthetic secret fixtures covering URL/query parameters, upstream error echo, and export.
3. Design Owned Logger Handle & Bounded Retention:
   - Manage logger and runtime retention via an explicit owned handle (`kargu-logger` struct).
   - Enforce hard retention bounds (character/entry cap) on EVERY write, ensuring memory does not grow unbounded.
   - Verify behavior for zero retention, single huge log record, Unicode, narrowing, and buffer-undo isolation.
   - Measure trim overhead: avoid complex ring buffer frameworks if simple bounded truncation suffices.
   - Provide clean public port for Package C (credentials), Package F (jobs), and Package L (storage).
4. Design new test suites:
   - `tests/test-log-privacy.el` (verifying keyless/nested/malformed JSON/error/export scenarios; confirming no wire content in metadata-only mode, and fail-closed secret masking).
   - `tests/test-log-retention.el` (verifying retention cap enforced on every write, zero retention, single oversized entry, two independent logger handles isolated from each other).
5. Output:
   - Provide concrete before/after code blocks, signatures, and implementation blueprint for Worker I.
   - Write your report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_I/package_I_report.md` and handoff in `/home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave3_I/handoff.md`.
   - Send completion message to caller via send_message.
