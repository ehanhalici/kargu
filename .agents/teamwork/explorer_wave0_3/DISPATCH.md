## 2026-10-21T20:20:11Z
You are teamwork_preview_explorer_wave0_3, working as Wave 0 Isolation Fixture Explorer.
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_3

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also read:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (especially Section 3: lines 88-102)
- /home/emrehan/.emacs.local/kargu/.agents/teamwork/teamwork_preview_orchestrator_1/PROJECT.md
- /home/emrehan/.emacs.local/kargu/tests/test-helpers.el
- /home/emrehan/.emacs.local/kargu/tests/test-modules.el
- /home/emrehan/.emacs.local/kargu/kargu/application/coordinator.el
- /home/emrehan/.emacs.local/kargu/kargu/contract/*.el

Scope & Boundaries:
You are a READ-ONLY explorer. Do not modify source code files. Recommend concrete implementation steps. Write only to your working directory.

Tasks:
1. Examine the Wave 0 acceptance gate requirement in parallel-plan.md §3:
   "İlk kapı: iki izole application fixture'ı birbirini değiştirmez; aynı application'da ikinci run reddedilir; opsiyonel modül yüklenmeden public sözleşmeler yüklenir. Salt tanım envanteri kod garantisi sayılmaz."
2. Design the dual-application isolation fixture and tests:
   - Verify that public contract modules (`kargu/contract.el` and all `kargu/contract/*.el`) can be loaded cleanly without loading optional feature modules.
   - Create a test helper / fixture that initializes two independent application coordinator handles.
   - Assert that operations or state claims on application A do NOT mutate or affect application B.
   - Assert that attempting a second active run on an application instance while one is active is rejected (enforcing ARCH-01/ARCH-12).
3. Determine where this fixture and tests should reside (e.g. updating `tests/test-helpers.el`, `tests/test-modules.el`, or adding `tests/test-application-context.el` which is also in Wave 1/A's test list).
4. Provide concrete code and test definitions for the Worker.
5. Write your detailed report to:
   /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_3/wave0_isolation_report.md
   and write a summary in:
   /home/emrehan/.emacs.local/kargu/.agents/teamwork/explorer_wave0_3/handoff.md
6. Send completion message via send_message to caller.
