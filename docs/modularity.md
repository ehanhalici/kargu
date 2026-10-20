# Module boundaries

The first structural slice separates loading definitions from application
composition. It does not yet replace global runtime ownership or make every
feature optional.

## Load contracts

- `kargu/core/data` contains the existing scalar/record helpers and compatibility
  aliases. Loading it does not initialize a session or state store.
- `kargu/core/group` defines the customization namespace only. Filesystem and
  path guards use it without importing the application facade.
- JSON, the process runner and async tasks use narrow data/log dependencies.
  These services load without the state, configuration, agent or chat sources.
- `kargu/api` does not load the Company/footer selector. Selection commands
  autoload their compatibility entry; the implementation is in `chat/select`.
- Loading a tool implementation exposes its registration function without
  registering tools. `kargu.el` explicitly registers built-ins in the existing
  order, preserving public tool names, aliases and policy declarations.
- `kargu/tools/registry` is an explicit, headless service. Loading it creates
  no default registry. The existing registration/execution facade delegates
  to this service, using `kargu-tool-definition` records rather than untyped
  specification alists. HTTP logging uses the facade's count operation, not
  the registry's storage representation.
- Tool implementations depend on `kargu/api/tools`, not the broad `kargu/api`
  facade. Loading LSP, Dape, search, diff, Bash, Git, skill or webfetch does
  not load the model HTTP client, catalog or chat. Permission and review
  dependencies are retained; this is not yet full UI independence.

## Tool registry contract

Every service operation receives a `kargu-tool-registry` handle. Registration
validates name, description, schema, executor and supported policy before
mutation. Definitions and nested schema/policy values are borrowed read-only
data; this is not yet the deep-copy/untrusted-extension boundary required by
the broader validation work. Runtime mode and availability gates remain in
the execution facade and still apply to direct and alias calls.

An alias stores a canonical name, not an old definition snapshot. Replacing
a tool therefore updates its aliases. Alias chains are flattened on entry;
aliases may be redirected but cannot overwrite a canonical definition.
Removing a canonical tool also removes its aliases; removing one alias does
not remove the tool. Registration, lookup and count use hash-table operations;
canonical removal scans the registered names once.

The existing `core`, `api` and `api/select` features remain compatibility
entry points. New internal consumers should use the narrow feature they need.
Existing public commands and scalar helper semantics have not changed.

## Plan artifact ownership

The plan store no longer keeps a global chat-to-plan hash table. The source
buffer owns its `kargu-plan-record`; its review holds a reference to that same
record. Closing either buffer, or changing its major mode, cancels the owned
record and detaches both references. Cleanup hooks are buffer-local, not
installed on every buffer in Emacs. A replacement retains the existing
superseded-record guard, and a reused review does not reset its major mode.
Creating a plan cannot steal another owner's review; current-record checks
also require the review to reference that exact record.

Plan records now hold a validated `kargu-plan-context`, with captured root
and session, current-owner validation, admission, dispatcher and optional
presenter callbacks. The context is immutable and has no duplicate identity
store. The plan domain loads without chat, engine or application state, and
an explicit headless dispatcher can retry a refused start and claim the
edited revision once. A missing dispatcher never consumes approval.

`kargu/chat/plan` is the composition-installed adapter for chat identity,
mode switching, startup and transcript buttons. Presenter errors cannot
undo an admitted dispatch; invalidated records cannot publish approval.
The adapter refuses unloading while plans still capture its callbacks.
This is not the complete chat/session or asynchronous mode-preparation
migration. The application's single-run gate and stale-owner checks remain
in the captured admission/dispatcher contract, not in a second plan engine.

## Missing editor adapters

The package root treats LSP and Dape source families as optional. Search,
chat completion, attachment parsing and the menu no longer load those
adapters themselves. Without them, textual tools and chat remain available;
symbol completion returns no symbols and asynchronous completion still
returns file candidates. Debug-session preparation reports unavailable and
Stop does not call a missing debugger adapter.

Post-edit verification uses the diagnostic adapter's public snapshot API.
Without that adapter it delivers unavailable evidence through the existing
verification path; it must not publish a clean/verified result. Tests remove
the adapter facade and implementation directory from a temporary package,
not just hide function definitions. This is startup absence support, not a
promise of safe live module unloading or complete context isolation.

## UI-independent confirmations and startup

Engine and permission consumers use `kargu/confirm`, not `ui/confirm`.
The port validates its callback and fail-closed default before presentation;
without an adapter it delivers reject, stop or cancel immediately. A test
mock decision cannot grant approval in that fallback. Requests are named
`kargu-confirmation` records; their nested options are borrowed read-only.

Package composition explicitly installs the existing UI adapter using Emacs
function advice, with no additional global handler table. Installation is
idempotent. Unloading refuses while confirmations are pending; after callers
dismiss them, unloading detaches the adapter and restores the safe fallback.
Closed requests remove their buffer cleanup hooks, and stale buttons remain
inert across unload/reload. This is not yet application/session-scoped UI
ownership: the adapter's existing pending list remains shared.

Set `(setq kargu-ui-enabled nil)` before loading `kargu` to skip chat, plan
review and UI composition. Source-absence tests remove all three source
families and complete a real loop run with a fake model boundary, without
stubbing chat functions. This does not prove an end-to-end HTTP exchange or
independent per-session contexts. Headless approval requests safely reject.

## Optional tool families

Text reading is in `kargu/files`, separate from the diff tool and review
adapter. LSP symbol reading and chat attachments use that service directly;
`kargu-diff-read-file` remains a compatibility alias. Permission checks,
owned tool-output buffers, unsaved/widened text and numbered ranges retain
their existing contract. Removing the diff source family does not remove
the read service. Editing still requires its separate guarded provider.

One ordered composition table loads and registers available tool facades.
Search, Bash, Git, skill and webfetch can each be physically removed, or
removed together with LSP and Dape. The remaining chat and text-file reader
still work; absent tools and aliases are not registered. Registration order
and existing policy gates are unchanged, and a broken installed adapter's
load error is not swallowed.

Diff is optional too: the engine observes changes through `kargu/edit`, and
LSP submits proposals through that port rather than private diff helpers.
Typed `kargu-change-query` and `kargu-edit-request` records cross that boundary.
Inputs and evidence/description outputs are validated there; asynchronous
results are delivered at most once. The original diff adapter still owns
permission, snapshot, review and identity-safe consumption. No adapter means
no editing grant; symbol editing is unavailable in both schema and execution.
The read-only `read_file` tool and its alias are composed independently.

Adapter installation uses idempotent native advice without a second registry.
Unloading refuses while a run, recovery snapshot, change, review or registered
diff tool remains. Explicitly resolving those resources and unregistering its
tools allows detachment; the fail-closed default then applies. It is not a
runtime module manager or a complete migration of shared runtime ownership.
Native run admission requires only plz/curl by default. Optional UI packages,
Git and language servers do not gate unrelated work. Explicit user additions
to the mandatory lists still apply. Package metadata likewise does not force
installation of the optional Transient/Magit integrations. Source removal
does not remove the permission boundary or make the model transport optional.

## Transport/application boundary

Raw `kargu-http-clear-busy` and `kargu-http-cancel` release only transport
ownership, timers, generation and process resources. They neither query the
agent loop nor transition application status. Legacy `kargu-api-*` cleanup
commands remain autoloaded compatibility entry points in the client facade,
which retains application status policy and the active-run guard.

Usage accounting also belongs to the facade's single-delivery claim, not
HTTP success callbacks. A duplicate or obsolete response cannot count usage
again through that path. Footer updates remain a view responsibility; the
HTTP layer no longer calls chat functions. A physically reduced package
without client/loop/chat/UI sources exercises raw cleanup without changing
the application's verification state. Request globals and per-logical-request
resource ownership still require the separate runtime-context migration.

## Regression gates

`tests/test-modules.el` loads boundaries in fresh batch Emacs processes with
temporary project directories. These tests cannot accidentally rely on the
full runner having loaded another feature first. One test copies only the
foundational source files into a temporary package tree: UI, API and runtime
sources are physically absent, not mocked as unavailable.
Another reduced tree loads and registers tool definitions with the model API
facade, HTTP, client and catalog source files physically absent.

`tests/module-boundaries.el` records the exact remaining consumers of broad
`core` and `api` facades. A migrated consumer must be removed from that list;
new imports are rejected. This checks literal top-level imports, not arbitrary
dynamic loading or all runtime/private call dependencies. Do not regenerate
the baseline to conceal a violation.

Run the full suite with:

```sh
emacs --batch -Q -L . \
  --eval '(progn (require (quote package)) (package-initialize))' \
  -l tests/run-tests.el
```

Only `tests/run-tests.el` bootstraps the test load path. Individual test
files use the supplied load path; load them with `-L <package-root>`.
The common runner also works by absolute filename from another directory.

## Remaining boundaries

The root still loads concrete features. Application-owned registries and
complete optional feature composition have not yet been implemented: the compatibility
facade still owns the existing `kargu--tool-registry` default reference, now
pointing at the service record. There is no second writable registry. Loading
Dape may still install its existing lifecycle hooks; removing tool auto-registration
is not a promise that every module is entirely side-effect-free.

The next slice must introduce explicit application/session ownership and
ports without creating another global singleton or a second writable state
store. Existing async cancellation, permission, debugger, protocol and review
guards remain in place during that migration. The open architecture records
in `todo.md` require their own complete acceptance tests before removal.
