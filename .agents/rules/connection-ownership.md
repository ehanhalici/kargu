# Connection and metadata ownership

Native admission claims the application before asynchronous configuration and
credential preparation. Configuration file selection, stat, capture and
TOML/schema/legacy import run in the bounded native read pool. Auth-source and
callable secrets remain cancellable editor interop workers. Readers consume the
validated in-memory configuration publication. Stop and the preparation deadline
cancel children; failures before admission preserve existing history, edits and
the unsent draft. A changed session, selection, endpoint or config revision
invalidates a pending credential result.

`configuration/parse` accepts captured bounded UTF-8 source and refresh generation
on the exact ready connection epoch. It performs no filesystem, environment,
credential or network IO and creates no application/session state. Generation is
an editor-ordering echo, not native config authority. Rust owns the TOML parser,
closed schema, legacy import, content digest and payload-free line diagnostics.
The old Elisp TOML engine was deleted. Header normalization preserves the legacy
top-level `provider` plus `[provider.NAME]` combination before standard TOML
parsing; it does not rewrite values or line boundaries.

The actual editor refresh now uses `configuration/read` (`configuration_read`
capability): it captures at most eight explicit local absolute candidate names
before startup yields, expanding editor `~` paths without filesystem IO. Rust
selects the first existing candidate and reads/parses it in one blocking worker,
outside the actor loop. A malformed/unreadable/oversized/non-regular first existing
candidate never falls through to another file. Missing candidates return `absent`
with the first path; native policy commits the empty projection. An explicit
refresh therefore starts the shared core even for absence. Missing core or read
capability fails closed; passive getters still never start a core or perform IO.
The old editor file script, decoder, source handoff and parser bridge were deleted;
the native pure parser remains a shared implementation, not a second parser.

Candidate names are narrow editor configuration read grants, not workspace/model
tool paths. Rust rejects relative/traversing/control-bearing/oversized paths.
Canonical targets support legitimate symlinks. A root-anchored `openat` walk uses
no-follow directory descriptors and an `O_PATH` final descriptor: devices, FIFOs
and directories are rejected without opening them for data IO. Linux
`/proc/self/fd` reopens only that pinned regular inode. Device/inode, size, mode,
mtime/ctime and current path are checked before/after bounded UTF-8 capture.
This depends on the existing Linux/procfs platform, not portable path-only APIs.
It detects observed identity/revision changes; it is not a filesystem transaction
against a privileged adversary or a hard realtime network-filesystem deadline.

Connection epoch owns native readonly IO, not an editor application lease or a
native config actor. Config and workspace reads share four slots. Cancel/expiry/
shutdown suppress late success; a slot remains occupied until its blocking worker
actually joins. Shutdown/EOF drain actual completions; cancellation is cooperative
between OS calls and cannot interrupt a kernel-blocked filesystem syscall.
No config child process or new subprocess lifecycle was introduced.

The application actor is the sole configuration publication/revision writer.
`configuration_policy` supplies owner/session-bound prepare/commit/abort tickets,
snapshot, exact-revision resolve and default-model selection. One fixed root
deadline covers startup, file capture, parsing, staging and commit observation.
Only a live ticket can commit; newer generations supersede older staging and
unclaimed tickets expire within five seconds, including transport-tick cleanup.
Closed owners cannot adopt late replies. Cancel before commit aborts an acquired
ticket, including a late prepare reply. An issued commit is not rolled back on
lost acknowledgement: the stale editor revision cannot authorize a connection;
explicit refresh with a newer generation reconciles it. No blind commit retry.

Rust owns global/config/env/keyless/interop precedence and provider/model/endpoint
defaults. Editor globals and literal registry data are inputs, not a policy engine.
Before yielding, the editor freezes at most 2 MiB of environment data behind a
private capability; only names requested by native policy cross IPC. Capture is
cleared on completion/cancel. Native environment capture is separately bounded
to 2048 names / 256 KiB; reference expansion is bounded and single-pass. Native
source identity hashes count/length-framed config, endpoint/key options, registry
and requested environment values, never another session's UI selection. Unchanged
sources reuse the revision; explicit per-request selection remains captured input.
Typed preview profiles may describe invalid endpoints, but consuming conversion
to a ready target requires a parsed HTTP(S) endpoint and valid nonempty model
identity (explicit empty model is the catalog preparation sentinel).

Elisp only observes committed DTOs and retains UI intent. Passive getters never
start RPC/IO, unlock credentials or read environment values; eligibility changes
become visible on explicit refresh. Direct requests capture fresh inputs and
resolve against the native head, rechecking it after external credential yields.
Cold standalone catalog/selection bootstrap can commit defaults without file IO;
its empty projection is not a filesystem absence claim. Normal send/setup performs
the explicit file refresh. Raw file source no longer crosses editor IPC; native
buffers use Zeroizing wrappers. Parsed credentials still deliberately enter private
editor projections; physical erasure of IPC/JSON/GC copies is not guaranteed.
Only an admitted live refresh advances the editor generation: closed/inactive
parents or elapsed deadlines cannot invalidate another in-flight publication.
The root checks elapsed time before starting its native read, without waiting
for a timer callback. Its fixed five-second bound cannot be disabled or extended
by the optional timeout; positive shorter values and earlier parent deadlines win.

The execution context owns one connection snapshot across every request and
retry. It captures provider, model, endpoint, wire record, model metadata,
sampling/reasoning policy, headers and configuration revision. Input and public
accessor strings and containers are detached recursively. Internal settings are
borrowed read-only. A transport response cannot change its format by rereading a
mutated provider registration. Redirects are refused before following Location,
including custom authorization headers; TLS certificate verification remains on.

Credential scope and settings use opaque cells to avoid ordinary struct printing
of secrets. Closing the request/run wipes its private credential string. This
does not wipe transport/header copies, debugger retention, earlier configuration
publications or garbage collector memory. Custom headers and configured keys
remain configuration data for the lifetime of their owner; no secure physical
erasure guarantee is made.

The Rust application actor exclusively owns model records, overrides, refusal
observations and capability/price/count normalization. `models/store.el` now
only submits async native commands and reads detached committed DTOs. Public
setters return tickets, not synchronous success; callbacks receive `(VIEW FAILURE)`.
The inspector waits for completion. There is no Lisp alias/override/field engine.
`models/service.el` selects application UI catalog generations, ID cache and
prefetch state; these are observations rather than model authorities.
Catalog callbacks retain the initiating application even when another buffer or
application becomes current. G09 must consume this service rather than create
another metadata store. A run captures an exact publication ticket before
yielding and retains its immutable receipt through callbacks and retries. With
no earlier publication, preparation explicitly acquires its first lease and
reads native head/pages without a mutation. Passive UI getters use last-committed
data or Rust's packaged unknown-model bootstrap and never start a core. Bootstrap
equality is tested against `ModelStore::new()`; it never authorizes a live lease.
Failed/uncertain publications cannot fall back to that offline snapshot for
preparation. Reconciliation stays explicit and bound to the same live lease.

Compatibility tables remain for callers without an explicit application owner.
Their consumers are `api/catalog.el`, `api/circuit.el`,
`selection.el` and provider selection in `config/schema.el`; default native
execution captures that compatibility choice too. The circuit default-state
mirrors and these detached tables are G13 cleanup bridges. G09 still owns the
remaining catalog/selection UI migration. Catalog discovery now resolves through
the same cancellable connection credential port as native sends. It consumes
already-published configuration; explicit configuration/UI refresh owns file IO.
The readonly native `provider/catalogTarget` port derives the URL and public/
provider-auth decision from captured API-base/default/dedicated/native-path facts.
Only an explicitly public dedicated endpoint without a base override skips
provider credentials. Provider, base, config revision, wire record, raw header
bindings and application are captured before yielding;
another chat's bound connection cannot lend its wire or credential. Credential
completion checks the initiating application's config revision and endpoint,
even when another application is current. Discovery is independent of agent
Stop/selection changes, but origin close/mode change, cancellation or deadline
release its children and transport. Its private credential scope and request's
key copy are wiped on closure; this is not complete physical memory erasure.

The target projection is not a native config publication or an execution grant:
its revision echoes the observed native config publication. The target port creates no
application actor/lease, performs no network/credential IO and is bound to the
existing connection epoch. Before credentials the editor rechecks config/base
and known lease ownership. GET uses that same connection; lost/replaced epochs
never cause replay or automatic rebinding. Missing target capability fails
before credentials or HTTP. Rust modifies only URL paths and retains query
contents. The older API-base selector stripped a query's terminal slash before
the port; this was fixed by removing that editor normalizer. Base readers
now retain the exact captured spelling, including path slashes and opaque query
values. API-base selection itself now comes from the exact-revision native config
resolver, before this separate catalog target projection. The expected base is
checked again before credential interop, not only after the lookup.

Normal chat sends pass that base and a chat-target intent, not a concatenated
endpoint, through the existing transport. Native `RequestTarget::Chat` is a
closed POST-only profile; `WireSpec` parses a bounded private `ChatPath` and
changes only the base URL's path. Origin and query remain captured. The final
endpoint is bounded and used for continuation identity and HTTP authority before
admission/replay/IO. Retries therefore never append the path again or consult
new metadata. The editor chat URL helper was deleted, with no Lisp fallback.
Missing `api_chat_target` support fails before owner startup or HTTP. Explicit
low-level URL requests retain their exact-target semantics; catalog GET retains
its separate native target/auth projection and connection pinning.

The obsolete synchronous credential entry points and editor auth-source search
were removed. `kargu-config-api-key-fast` is a memory-only availability check,
not an auth-source resolver. Setup now uses the shared connection resolver too;
the duplicate async key facade/dispatch/delivery helpers were removed. Its
buffer-owned root covers config and credential resolution with one deadline,
independent of an agent run. Closing/changing mode or replacing that origin's
check cancels its children; stale session/selection results cannot report a new
provider with an old key. Reports borrow the frozen snapshot, then wipe both
the private scope and report key copy, including callback failures and discarded
late results. Placeholder warnings never print the key itself. Native
configuration refresh starts the native core and acquires the application's config
lease, but setup does not perform model/metadata discovery or test upstream health.
A cold shared bridge still creates its own standalone
read-service application/session during bootstrap, independently of the parser.
The local plaintext auth-source child remains an editor interop port, not a newly
implemented Rust credential reader. The broader credential-process lifecycle and
general log-egress audits remain separate migration work, not certified by this cutover.

Catalog publication is one atomic native replace operation. Stale responses still
deliver to their own callers but cannot overwrite newer state. A new generation
may revoke an uncommitted upload; it cannot undo an issued commit. The single
writer completes that revision before the newer publication. Scope/owner loss
still revokes delivery; an uncertain commit requires explicit reconciliation.
Prices/capacities reach Rust as exact source text, never recovered Lisp floats.
The UI uses native price labels; an invalid price is unknown, not free.

Offline evidence is in `tests/test-native-model-consumers.el`,
`tests/test-native-model-publication.el`, `tests/test-connection-native.el`,
`tests/test-catalog-connection.el`, `tests/test-catalog-target.el`,
`tests/test-setup.el`, `tests/test-config-native.el` and the existing config,
snapshot, model-store, parameter and application suites. It includes real child
workers, real loopback curl redirects for Bearer and x-api-key, Stop and draft
restoration, immutable retries, late selection rejection, two application owners
and a synthetic conditional reasoning/temperature contract. The synthetic
fixture makes no claim about a live provider's current API version.

The application, connection, transport and main loop TLC models cover bounded
lifecycle behavior. Exhaustive completion of these models is evidence about
those models, not proof of Emacs, curl or the whole system.

G02 validation on 2026-10-23: full ERT 1116/1116; warning-free byte compilation
and checkdoc for all 28 changed Elisp files. Exhaustive TLC completed for
application (1,681 distinct states), connection (101,708), transport (693),
plan (72,313), mode (5,958) and the main loop (84,273,208 distinct states,
718,447,752 generated; no states left on the queue).
