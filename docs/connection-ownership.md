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

`models/service.el` selects the application's single `:metadata` service.
It owns the model records, catalog generations and cache, prefetch state, tool
refusals and circuit registry. `models/store.el` alone writes model entries.
Catalog callbacks retain the initiating application even when another buffer or
application becomes current. G09 must consume this service rather than create
another metadata store. A run captures its metadata service selection before
yielding and retains it through callbacks and retries.

Compatibility tables remain for callers without an explicit application owner.
Their consumers are `api/catalog.el`, `api/circuit.el`, `models/store.el`,
`selection.el` and provider selection in `config/schema.el`; default native
execution captures that compatibility choice too. The circuit default-state
mirrors and these detached tables are G13 cleanup bridges. G09 still owns the
catalog/selection UI migration, including catalog discovery's legacy credential
entry point. Native send, setup check and connection test use asynchronous
credential preparation now.

Offline evidence is in `tests/test-connection-native.el` and the existing config,
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
