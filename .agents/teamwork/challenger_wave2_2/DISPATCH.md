# Dispatch: challenger_wave2_2

Spawned: 2026-10-22T03:56:00Z
Mission: Wave 2 Challenger 2 (Transport, Circuit Breakers & Formal Models)
Working Directory: /home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave2_2

## 2026-10-22T03:56:35Z
Sender: 246e42bd-e1b7-4f73-8026-d90704dd17ec
Priority: MESSAGE_PRIORITY_HIGH
Content:
You are challenger_wave2_2, working as Wave 2 Empirical Challenger 2 (Transport, Circuit Breakers & Formal Models).
Your working directory is: /home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave2_2

Read the verbatim user request in:
/home/emrehan/.emacs.local/kargu/.agents/teamwork/ORIGINAL_REQUEST.md

Also study:
- /home/emrehan/.emacs.local/kargu/parallel-plan.md (Section 5: Dalga 2, Package E and Section 9: Formal Proofs)
- /home/emrehan/.emacs.local/kargu/architecture-contracts.md (Contract 4, Contract 6)
- /home/emrehan/.emacs.local/kargu/proof/run_tlc.sh, proof/*.tla, proof/*.cfg

Scope & Tasks:
1. Empirically challenge Transport & Circuit Breakers:
   - Challenge Provider Circuit Isolation: record failures for "provider-alpha" until its circuit trips open (`:open`). Verify that requests to "provider-beta" remain `:closed` and unaffected. Reset "provider-alpha" and verify only alpha resets.
   - Challenge Run Budget Debits on Retries: create a `kargu-run-budget` with `max-requests = 2`. Perform a request that fails with a retryable 503 status code. Verify that initial attempt and retry debit the budget, and when the budget reaches 0, no further retries occur.
   - Challenge Stream Buffer Pressure: feed a synthetic stream with an incomplete line exceeding 64KB, or raw payload exceeding 4MB. Verify the transport aborts immediately with typed error and kills the subprocess.
   - Challenge Cross-Origin Header Stripping: verify that redirecting from `api.example.com` to `storage.other.com` strips `Authorization` and sensitive headers.
2. Formally verify all Wave 2 TLA+ models using `bash proof/run_tlc.sh`:
   - `bash proof/run_tlc.sh --approval` (KarguApproval)
   - `bash proof/run_tlc.sh --transport` (KarguTransport)
   - `bash proof/run_tlc.sh --process` (KarguProcess)
   - `bash proof/run_tlc.sh --connection` (KarguConnection)
   - `bash proof/run_tlc.sh --budget` (KarguBudget)
   - `bash proof/run_tlc.sh --mode` (KarguMode)
   - `bash proof/run_tlc.sh --edit-transaction` (KarguEdit)
   Confirm each runs cleanly with exit code 0 and 0 errors found.
3. Deliver your verdict: APPROVE or REQUEST_CHANGES.
4. Write your challenge report to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave2_2/challenge_report.md` and handoff with verdict to `/home/emrehan/.emacs.local/kargu/.agents/teamwork/challenger_wave2_2/handoff.md`.
5. Send completion message to caller via send_message.
