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

The existing `core`, `api` and `api/select` features remain compatibility
entry points. New internal consumers should use the narrow feature they need.
Existing public commands and scalar helper semantics have not changed.

## Regression gates

`tests/test-modules.el` loads boundaries in fresh batch Emacs processes with
temporary project directories. These tests cannot accidentally rely on the
full runner having loaded another feature first. One test copies only the
foundational source files into a temporary package tree: UI, API and runtime
sources are physically absent, not mocked as unavailable.

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

## Remaining boundaries

The root still loads concrete features. Optional feature composition and
application-owned registries have not yet been implemented. Loading Dape may
still install its existing lifecycle hooks; removing tool auto-registration
is not a promise that every module is entirely side-effect-free.

The next slice must introduce explicit application/session ownership and
ports without creating another global singleton or a second writable state
store. Existing async cancellation, permission, debugger, protocol and review
guards remain in place during that migration. The open architecture records
in `todo.md` require their own complete acceptance tests before removal.
