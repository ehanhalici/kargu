# Native conversation change evidence

Native terminal accounting now includes a `changes` DTO from the actor-owned
edit ledger: its revision, pending file count and retained metadata count. The
capture filters by the exact conversation and excludes explicit editor-service
records. It occurs in the same actor turn before run release. This is
conversation evidence, not a claim of complete per-run modification history.

The existing response/event RunScope supplies identity; duplicating the session
ID in this DTO exceeded the minimum 1 KiB envelope. Removing that redundant ID
restored the actual tiny-frame display regression without reducing the protocol
frame requirement. The oversized-capture native run must also remain responsive.

The native editor adapter projects the DTO into the run's terminal report, and
the chat renderer displays its counters. It does not query legacy maps, infer a
clean diagnostic result from zero pending files, or equate retained metadata
with all run modifications. Missing evidence remains explicitly unavailable.

Tests cover foreign conversation/editor-service exclusion, retained versus
pending counts after exact consume, actual write/edit/patch receipts reaching
terminal accounting, detached report projection and UI text without a fabricated
clean verdict. Full pending path readers, native diagnostic verification/healing
and complete run-modified accounting remain open in 3.8/5.9/6.4. No TLA+ source
changed and TLC was not rerun.

Validation: 599 locked Rust tests (32 compile-fail included), strict all-target
Clippy with panic/unwrap/expect denied, and formatting checks passed. The full
source ERT run passed 1422/1422 before the final chat-render helper/fixture; the
final affected native lifecycle/history/edit/UI suite passed 65/65. Changed Elisp
warning-as-error compilation, parenthesis checks and production checkdoc passed.
The working-tree totals include unfinished task 7/8 sources and are not acceptance
of those features. The original oversized/tiny-frame failures were corrected and
the full Rust rerun and real 1 KiB Emacs answer regression passed.
