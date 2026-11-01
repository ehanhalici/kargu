# Native edit service close

The frontend pins each native edit service to the connection object, connection
epoch and application/session scope observed before its first preparation RPC.
Later preparations and rollbacks must match this lease before dispatch. Closing
uses the same captured lease; it does not reconnect or close an identity in a
replacement core.

`kargu-edit-service-close` revokes new local work immediately and cancels owned
frontend tasks. It releases private buffers, directories and passive tables only
after the existing native close port reports `closed:true, drained:true`.
`closed-p` means revoked; the separate `drained` field projects successful native
settlement. A timeout, lost epoch or invalid reply preserves local resources and
records the failure. Repeated calls share an in-flight close; callers may retry a
failed close against the original lease. Callbacks receive `(VALUE FAILURE)`.
Services that have never dispatched a native preparation retain the immediate
legacy local-close behavior.

The bridge polls native drain without starting a new core, as before. Rust owns
service retirement and actual writer/preparation settlement. The frontend stores
the acknowledgement and releases Emacs resources; it does not infer quiescence
from cancellation, elapsed time or disappearance of a local task.

A real Emacs/stdio test closes the service inside an issued editor primitive.
Native close first returns `drained:false`; the owned UI buffer remains alive.
After the physical handler and receipt settle, polling observes `drained:true`
and releases the buffer. Additional tests cover shared close waiters, preservation
on epoch loss, and refusal to edit a replacement core with an old service.

The test harness now creates a separate compatibility default service per test,
matching its existing application/table isolation. This does not relax production
lease checks. Production default/global legacy state remains migration debt.
General history reader and verification consumer cutover remains in todo.md.

Validation: 103/103 affected edit/service/native-agent ERT and 1440/1440 full
source ERT passed. Changed Elisp passes warning-as-error compilation, parentheses,
nonmutating production checkdoc and whitespace checks. Rust and TLA+ source were
unchanged in this slice; their previously passing checks were not repeated.
