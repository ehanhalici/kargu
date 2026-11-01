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

The capacity change completes todo 3.8a1; the transport change below completes
3.8a2. Consumed run-file metadata remains bounded; this
does not promise an unlimited audit trail. Native default selection, all change
reader/verification consumers and legacy Elisp engine removal remain open in
3.8–3.10. The matching boxes were reopened to reflect the source tree.

## Editor metadata transport

The undo list, undo files and changed-file DTO readers now share one bounded
paging implementation. They capture the original connection epoch as well as
scope and revision. A replacement connection cannot publish a successful old
read or receive an old request's cancellation, even if IDs and scope fields are
reused. Only the currently outstanding page is retained for cancellation;
inline callbacks cannot overwrite a newer page's request ID. The higher-level
undo path reader also retains that original epoch and detaches its service ID.
No change selection, verification decision or undo eligibility moved to Elisp.

The stale-epoch regression failed against the previous implementation and
passed after the fix. Eight new ERT tests cover the three paging projections,
malformed/stale pages, cancellation, scope replacement, absent leases, aggregate
path reads and an actual native editor receipt. The pipe test reads only one
service's changes and undo paths, consumes its exact identity and confirms that
a sibling service remains pending. The complete affected edit suite passed
77/77, alongside changed Elisp warning-as-error compilation, parenthesis checks
and non-mutating production checkdoc. Rust was unchanged after the validation
above. Conversation-scoped readers and the remaining legacy verification
consumers are still open.

## Close acknowledgement ownership

The close-service port also captures scope and connection epoch. A stale reply
cannot certify drain, a pending poll cannot switch epochs, and cancellation
cannot target a replacement connection's reused request ID. Inline completion
is recorded before accepting the returned request ID, so an already completed
request does not remain active while waiting for the next poll.

Three close regressions fail against the preceding implementation and pass with
this change. The affected edit/service/metadata suite passed 92/92, together with
warning-as-error Elisp compilation, parenthesis checks and production checkdoc.
Rust and TLA+ were unchanged. This is todo 3.8a3, not public service-close cutover:
that caller still needs to retain its original edit lease and await native drain
before discarding its remaining resources. Its uncommitted WIP was preserved.
