# Migration review — 2026-11-01

The user authorized review of all uncommitted changes, corrections, tests and
incremental commits. The sole task checklist is todo.md. This is an evidence
record, not a declaration that every changed file has been reviewed.

Initial inventory: 164 tracked changed paths, roughly 23,000 added lines,
plus new session/catalog sources and local scratch files. Staged and unstaged
changes were present. Scratch files read-only.txt, remaining.txt and symbol.el
are excluded from commits. No live provider accounts or user session files
were used in tests.

## Confirmed defects and corrections

- Budget preflight skipped monetary unknown-state checks whenever a token cap
  existed. A new failing regression confirmed the bug; independent ceiling
  checks fix it. Unknown usage and fractional micro-dollar charges no longer
  become exact zero/integer costs. The existing implementation is an observed
  spend ceiling, not a hard reservation; task 6.2 remains open. The budget
  slice passed 22 tests in an isolated worktree and was committed separately.
- Session save restarted journal sequence at one. Complete corrupt final lines
  were silently truncated. Recovery could modify a live writer's journal.
  Public storage APIs accepted traversal IDs. Four new regressions failed
  before fixes and pass afterward. Journal open now scans under flock, only
  incomplete non-newline tails are truncated, storage entry points validate
  IDs, reads are byte capped/no-follow, and exclusive publication uses
  persist_noclobber. Full saved checkpoints can recover without a snapshot.
  Focused session suite: 18 passed. These sources are still under review.
- New remote catalog fetch buffered the entire response before checking its
  parser limit, restarted the full timeout for the body, and silently omitted
  malformed authorization headers. Streaming byte limits, a common absolute
  deadline and explicit invalid-header failures were added, with three local
  HTTP regressions. No external network is required.
- Public catalog API bypassed the existing native metadata publication and
  captured credential/epoch lifecycle, and returned stale fallback models as
  successful refresh. The owned adapter to the existing Rust HTTP/metadata
  services was restored. Provider/model UI introduced a global cross-owner
  cache and a second selection writer. The existing native configuration
  projection path is retained, along with independent Company input fixes.
  Focused catalog/model/provider/selection acceptance: 75/75 passed.

## Remaining findings requiring implementation review

- Native edit_by_lsp is explicitly unavailable in edit/prepare/parent.rs.
- loop/native.el still invents default application/session identities and
  revisions, assembles Bearer auth itself, logs raw native events and treats
  every successful RPC response as a successful run. Captured run/config/
  credential authority and terminal status need full integration.
- Elisp agent FSM/tool orchestration was moved from deleted machine/tools
  files into loop.el/ui.el; native enablement remains optional. Deleted loop
  tests must be reconciled with the remaining real consumers.
- LSP/Dape/context DTO foundations are not proof of complete consumer migration;
  standalone symbol/xref/context routes still need review.
- Session persistence RPCs in application/host.rs perform disk IO synchronously,
  permit missing epochs and do not bind storage to an application/session
  capability. Elisp storage/restore writers still exist. Delete/import/load
  locking, pinned directory identity, journal growth/compaction, protocol-ordered
  repair and snapshot/journal concurrency need completion before task 7 closes.
- New model refresh can collect credentials from other applications and publish
  metadata into all applications; owner isolation must be established. Other
  model/provider RPCs require the same scope audit. Public UI currently uses
  the existing owned pipeline; this does not fix direct RPC consumers.
- Monetary pricing helpers are not connected to actual native provider
  settlement. Hard pre-IO monetary reservation is absent; compaction/healing/
  verification still have Elisp orchestration.

## Validation record

Initial full ERT using a freshly built native binary: 1341 tests, 30 unexpected
failures, concentrated in the changed catalog and provider/model UI paths.
A previous invocation without the binary skipped native cases and is not
acceptance evidence. Full Rust/ERT and strict Clippy are being rerun after
corrections; final counts must be recorded before declaring closure. GUI/TLC
acceptance and review of all remaining paths have not been completed.
