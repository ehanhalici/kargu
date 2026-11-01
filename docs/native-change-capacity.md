# Native verification debt under capacity pressure

The Rust actor owns both the undo snapshots and the changed-file ledger. They
have different retention obligations: evicting an undo body must not discard a
file that still awaits verification.

Previously, `record_applied` removed the oldest changed-file row whenever the
256-row limit was reached, including pending verification. Admission now checks
the union of pending rows, still-claimed artifacts and the incoming artifact,
identified by `(session, edit service, canonical path)`. A new target exceeding
that bound is rejected before the preparation becomes claimed and before editor
write authority is issued. An existing target can still be edited or undone.
Revoked claims continue reserving their targets until actual release.

Publication can evict consumed metadata only. The actor cannot silently discard
pending debt to make room. An impossible missing reservation returns a cleanup
failure rather than losing an existing pending row. There is no second counter
or Elisp reservation authority.

Five unit regressions exercise the real preparation/claim boundary, a revoked
claim retaining the last slot, release reopening admission, consumed-only
eviction, existing-target admission and session isolation. A stdio regression
applies 17 edits with verified editor receipts: the first undo snapshot is
evicted at the 16-snapshot bound while all 17 verification rows remain. A wrong
hash cannot consume that first row; its exact edit/file/hash tuple can.

Validation on the current working tree: 593 locked Rust tests, including 31
compile-fail tests, strict all-target Clippy, and 1406/1406 full source ERT passed.
This count includes
uncommitted task 7/8 tests; it is not a claim that those tasks are accepted.
TLA+ sources were unchanged, so TLC was not rerun.

This completes todo 3.8a1 only. Consumed run-file metadata remains bounded; this
does not promise an unlimited audit trail. Native default selection, all change
reader/verification consumers and legacy Elisp engine removal remain open in
3.8–3.10. The matching boxes were reopened to reflect the source tree.
