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

This is an artifact-ownership migration, not the complete chat/session
migration. Root/session validation, single claim, failed-startup handling and
the application-wide active-run guard remain unchanged. Plan dispatch still
depends on the chat adapter; the dispatcher port in `todo.md` remains open.

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

The root still loads concrete features. Optional feature composition and
application-owned registries have not yet been implemented: the compatibility
facade still owns the existing `kargu--tool-registry` default reference, now
pointing at the service record. There is no second writable registry. Loading
Dape may still install its existing lifecycle hooks; removing tool auto-registration
is not a promise that every module is entirely side-effect-free.

The next slice must introduce explicit application/session ownership and
ports without creating another global singleton or a second writable state
store. Existing async cancellation, permission, debugger, protocol and review
guards remain in place during that migration. The open architecture records
in `todo.md` require their own complete acceptance tests before removal.
