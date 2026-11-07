# Progress — Wave 1 Remediation Test and Proof Alignment Explorer

Last visited: 2026-10-21T22:57:40Z

## Status
Task complete. Investigation and verification plan finalized.

## Completed
1. Formal Proof Alignment Analysis:
   - Examined `proof/KarguMode.tla`, `proof/ModeMC.tla`, `proof/ModeMC.cfg`.
   - Verified that `KarguMode.tla` models session mode preparation (`"ask"` vs `"agent"`), async intent supersession, epoch invalidation, and mode freezing during active runs.
   - Proved that updating `kargu-application--transition-table` has zero impact on `KarguMode.tla` or `ModeMC.cfg` because application status keywords are orthogonal internal micro-transitions.
   - Ran all 4 TLC models: `--budget` (432 states), `--edit-transaction` (560 states), `--connection` (77,292 states), `--mode` (5,958 states) — all passed with 0 errors.
2. Root Cause Investigation of 26 ERT Regressions:
   - Discovered that the 26 failures have two distinct root causes:
     - 23 failures: missing transitional paths in `kargu-application--transition-table` in `kargu/application/coordinator.el`.
     - 3 failures: `kargu-async-pending-p` regression in `kargu/async.el` conflating list owner identity with `equal` and keeping cleared owners alive via an improper fallback.
   - Empirically validated that fixing both issues allows all tests to pass cleanly.
3. Designed Comprehensive 7-Gate Verification Plan:
   - Gate 1: Formal Model Checking (4 TLC models, 0 errors).
   - Gate 2: Package A, B, C Core Test Suites (123 tests, 100% pass).
   - Gate 3: Empirical Adversarial Challenge Suite (9 tests, 100% pass).
   - Gate 4: Full Repository ERT Test Suite (997 tests, 100% pass, 0 failures, 0 errors).
   - Gate 5: Byte-Compilation Hygiene (`byte-compile-error-on-warn t`, 0 warnings).
   - Gate 6: Checkdoc Documentation Hygiene (0 warnings).
   - Gate 7: Clean Repository Governance (0 `.elc`, 0 changes to protected files).
4. Documentation:
   - Created detailed report: `test_proof_alignment_report.md`
   - Created 5-component handoff: `handoff.md`

## Next Steps
- Send completion message to orchestrator via `send_message`.
