## 2026-10-21T22:33:48Z
You are challenger_wave1_2, working as Wave 1 Empirical Challenger 2 (Package C & Formal Models).
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave1_2

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 4: Package C and Section 9: Formal Proofs)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Contract 4)
- /home/emrehan/.emacs.local/kargu/proof/run_tlc.sh, proof/*.tla, proof/*.cfg

Scope & Tasks:
1. Empirically challenge Package C invariants:
   - Test `kargu-config-api-key-fast`: mock `auth-source-search` to throw an error if called. Verify `kargu-config-api-key-fast` does NOT call `auth-source-search`.
   - Test synchronous resolution: when `:secret` is a function, verify synchronous resolution returns `(kargu-err ... :unavailable)` instead of evaluating the function synchronously (CONFIG-01).
   - Test credential wiping: test `kargu-credential-scope-wipe` on a scope containing a secret string, and verify the internal buffer/string is zeroed out by `clear-string`.
   - Test worker cancellation: trigger an async credential resolution, cancel it immediately, verify the child process is killed (`delete-process`) and does not hang as a zombie.
2. Formally verify all Wave 1 TLA+ models using `proof/run_tlc.sh`:
   - `bash proof/run_tlc.sh --budget` (KarguBudget)
   - `bash proof/run_tlc.sh --edit-transaction` (KarguEdit)
   - `bash proof/run_tlc.sh --connection` (KarguConnection)
   - `bash proof/run_tlc.sh --mode` (KarguMode)
   Confirm each runs cleanly with exit code 0 and 0 errors found.
3. Deliver your verdict: APPROVE or REQUEST_CHANGES.
4. Write your challenge report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave1_2/challenge_report.md` and handoff with verdict to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave1_2/handoff.md`.
5. Send completion message to caller via send_message.
