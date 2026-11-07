# Progress — explorer_wave0_3

Last visited: 2026-10-21T20:30:35Z

- [x] Initialized workspace (DISPATCH.md, BRIEFING.md, progress.md)
- [x] Read and analyze required documents:
  - ORIGINAL_REQUEST.md (Wave 0 boundaries, 100% ERT pass, 0 byte-compile warnings, formal TLC)
  - parallel-plan.md (§3 lines 88-102: Wave 0 acceptance gate)
  - PROJECT.md (Architecture, Milestones M0-M6, Interface Contracts)
  - tests/test-helpers.el (shared test harness, kargu-test--isolate advice)
  - tests/test-modules.el (subprocess module boundary tests, forbidden features)
  - kargu/application/coordinator.el (kargu-application, kargu-logical-request)
  - kargu/contract/*.el (contract facade and 7 submodules)
- [x] Verify contract module dependency graph:
  - Verified all contract submodules load cleanly without forbidden runtime/adapter features
  - Identified missing requires in `kargu/contract.el` (`file-window`, `history`, `selection`)
  - Verified that requiring all submodules under `kargu-module-test--load-foundation` passes with zero forbidden features
- [x] Investigate application coordinator lifecycle and isolation mechanisms:
  - Discovered that currently `kargu-application-set-active-run` overwrites active runs without checking for existing active runs
  - Verified that `kargu-application-claim` and `kargu-application-release` do not yet exist
- [x] Run test suite with single active run rejection check:
  - Full suite passed: 942/942 passed, 0 failures, 0 regressions
- [x] Design dual-application isolation fixture and macro:
  - Designed `kargu-test-with-dual-applications` and `kargu-test-make-dual-applications` for `tests/test-helpers.el`
- [x] Design second active run rejection tests (ARCH-01/ARCH-12):
  - Designed single-active-run rejection for `kargu-application-set-active-run`
  - Designed `kargu-application-claim` and `kargu-application-release`
- [x] Determine file location strategy:
  - `tests/test-helpers.el` for fixture macro and creator
  - `tests/test-modules.el` for subprocess contract independence and dual-app isolation
  - `tests/test-application-context.el` for unit tests of application context, single run rejection, and claim lifecycle
- [x] Write detailed report (`wave0_isolation_report.md`) and `handoff.md`
- [x] Send completion message to parent orchestrator
