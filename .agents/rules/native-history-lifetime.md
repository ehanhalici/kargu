# Native edit metadata lifetime lease

The list/files/changes readers, undo path aggregation, consume and reset ports
accept an explicit captured service lease. Native UI references retain the first
edit lease and return it unchanged to these ports. Rollback projection and the
interactive snapshot list use that same lease. Explicit callers without a service
lease continue to capture the current application binding for their own request.

An explicit lease selects the original connection object, epoch and scope before
any RPC. A reconnect cannot silently retarget the request. Read paging retains
its existing revision, cursor, cancellation and same-epoch response validation.
Nonpaged consume/reset replies now also validate their captured lease: a late
`consumed:true` after owner loss cannot delete the old passive UI reference.
Lease strings/scope metadata are detached before yielding, so caller mutation
cannot rewrite an outstanding request's ownership evidence.

Regressions exercise all six entry points after epoch replacement and assert that
none emits an RPC. Public consume preserves its exact reference both before
initial dispatch on a replacement core and after a stale ACK. The latter covers
epoch and scope loss, with caller-owned lease metadata also rewritten to the new
values; the already captured request still rejects the ACK.

Validation: 110/110 affected edit/service/native-agent ERT passed, followed by
the strengthened lease-detachment case. Changed Elisp warning-as-error compilation,
parentheses, production checkdoc and whitespace checks passed. The prior preparation
slice passed 1444/1444 full ERT; that count is not a rerun of this slice. Rust/TLA+
source did not change. General verification and legacy reset-run policy cutover
remain separately tracked in todo.md.
