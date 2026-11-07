# Native edit handle epoch ownership

Read-only preparation handles now capture the physical connection epoch in
addition to application/session scope. Both normal startup and explicit native
conversation preparation capture it before dispatch; rollback keeps the epoch
from dispatch rather than sampling the connection when its reply arrives.

Every preparation RPC rejects a mismatched epoch before sending and before
publishing its reply. A stale handle cannot read, authorize, continue uploading,
or abort a preparation in the replacement core. Cleanup still marks its local
handle released, while native EOF/owner cleanup is responsible for the old core's
remaining resources. A same-epoch cancellation continues to abort late allocated
tickets normally; it is not confused with a physical reconnect.

Two new regressions failed before the change: a prepared handle stayed current
under an unchanged scope after epoch replacement, and a late allocation emitted
`edit/prepare` and `edit/abort` to the replacement. Both pass with the fix. Further
cases reject late authorized replies and rollback allocations, including reused
request/ticket identifiers. Existing same-epoch late cancellation and stale-scope
cleanup tests remain passing with explicit fixture epochs.

This closes the preparation-handle portion of 3.8a7. General metadata and consume
readers still need the service lifetime lease, beyond their existing per-request
scope/epoch capture; they remain separately tracked in todo.md.

Validation: the two initial regression cases failed before the fix. All four
new epoch cases, 106/106 affected edit/service/native-agent ERT, and 1444/1444
full source ERT passed. Changed Elisp warning-as-error compilation, parentheses,
production checkdoc and whitespace checks are clean. No Rust or TLA+ source changed.
