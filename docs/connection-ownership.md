# Connection and metadata ownership

Native admission claims the application before asynchronous configuration and
credential preparation. Configuration file selection, stat, parsing, auth-source
and callable secrets run in cancellable child workers. Readers consume the
validated in-memory configuration publication. Stop and the preparation deadline
cancel children; failures before admission preserve existing history, edits and
the unsent draft. A changed session, selection, endpoint or config revision
invalidates a pending credential result.

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
its revision echoes the editor's captured publication. The port creates no
application actor/lease, performs no network/credential IO and is bound to the
existing connection epoch. Before credentials the editor rechecks config/base
and known lease ownership. GET uses that same connection; lost/replaced epochs
never cause replay or automatic rebinding. Missing target capability fails
before credentials or HTTP. Rust modifies only URL paths and retains query
contents. The older API-base selector can still strip a query's terminal slash
before the port; its native cutover/regression remains tracked in todo 1.

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
config/endpoint policy remains open. The default local plaintext auth-source
child remains an editor interop port, not a newly implemented Rust credential reader.

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
`tests/test-setup.el` and the existing config,
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
