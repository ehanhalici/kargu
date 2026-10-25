# Default native model metadata consumers — 2026-10-25

## Completed cutover

Public metadata put/property/refusal/clear writers now submit to the existing
application-owned native actor. Catalog publication is one replace_catalog
operation, not a Lisp loop of put/prune mutations. General UI readers and
connection settings select the actor's canonical DTOs. The old Lisp entry/table,
alias search, override merge, retention writer, refusal table and numeric/effort/
capability parsers were removed. models/store.el is only a command/projection
facade. Label composition stays UI-side, but price labels come from native exact
decimal text; there is no editor price multiplication or string-to-number policy.

This supersedes the earlier pending-public-consumer notes in 41/12. It does not
complete native run/history, installed-app backends, monetary hard reservation,
all credential discovery entry points or the whole Rust/API migration.

## Public contract

- set-metadata(id, data, provider?, callback?) returns a publication ticket.
- set-prop(id, key, value, :provider, :callback, :owner) returns a ticket.
- Callbacks receive (VIEW FAILURE), once, after completion; submission is not a
  successful publication. Getters keep the last committed observation meanwhile.
- A definite native failure preserves the revision/cache; subsequent explicit
  valid updates can proceed. Unknown commit outcome still fails the service
  closed and requires explicit same-lease reconciliation, never replay/rebind.
- Inspector completion is reported only after commit, under its captured buffer
  owner. It captures provider/model and sends numeric input as exact source text.
- Input rates and capacities accept decimal strings or integers, not floats that
  already lost precision. input-cost is now an exact decimal string; price-label
  is already formatted native text. Invalid prices are unknown, never free.

models/encode only converts plist/alist/vector/hash containers to JSON. It does
not normalize domain fields or merge records. It preserves nil flag semantics,
rejects cyclic/improper/deep containers and rounded price/capacity values,
including one-object pricing wrappers, and does not echo failed DTOs.
Provider effort specs are captured before yielding and parsed only in Rust.

## First read and passive UI

With no prior publication intent, real preparation explicitly acquires its first
service lease and reads models/snapshot + models/read. It captures that ticket
before config yield, waits before credential resolution, and freezes that actual
native receipt. Initial head zero is an observed revision, not a fabricated
successful update. The operation issues no begin/append/commit command. It cannot
repair an uncertain commit or replace an application's earlier lost API lease.

Passive UI reads never start/reconnect a core or await RPC. Before any native
view they consume kargu-core/assets/models-empty.json, which a Rust test compares
exactly to ModelStore::new().snapshot(). Package this small asset alongside the
provider manifest. It is UI bootstrap data, not native lease/admission authority;
preparation cannot fall back to it after native failure. Later UI reads may keep
the last committed observation while the captured preparation fails closed.

Private weak-key indexes select exact supplied DTO IDs/aliases/refusals, rather
than rescanning every catalog vector for every annotation. They infer no aliases
or permissions. UI-only field reads do not copy large opaque inspector text.
Public records/receipts/fields remain recursively detached. No performance
benchmark or universal zero-copy claim is made.

## Catalog ordering and cancellation

Old GET replies still deliver to their own callers but are not enqueued once a
newer provider generation supersedes them. A queued/uploading publication may
be revoked; late allocation is aborted and ACK/drained before its successor.
After commit is issued, a newer generation cannot pretend it was undone: the
single writer completes that revision before applying the next catalog. Owner/
scope loss still revokes delivery and unknown commit outcome remains closed.
Tests cover generation changes both during begin and after the actual commit
with a withheld receipt. The latest catalog cannot be resurrected by old data.

UI ID cache/prefetch/generation compatibility tables remain observations for
selection, not record/capability/override authorities. Failed/malformed/empty,
provider-only prune, override-only records, alias ambiguity, case identity and
exact-ID request-parameter contracts are retained. Canonical GET bodies still
cross the editor before the owned native publication; no direct worker-to-store
or zero-copy HTTP commit claim is made. Discovery's synchronous credential entry
point remains a separate open port (docs/connection-ownership, G09/G13).

## Verification and fixture migration

Existing fixtures now explicitly await real native public writers, rather than
making the product synchronous or replacing metadata business logic with mocks.
Old hash-table snapshot assertions now assert detached native receipt stability;
alias/override/provider isolation assertions remain. The old mixed-writer refusal
test now proves all public producers share the same actor and monotonic revision.
Pure effort-parser fixtures exercise captured specs through actual native
publication. The previous simulated circuit peer was replaced by a real core
lease when the fixture also needs real metadata. No dependency baseline or
assertion was removed to accommodate the cutover. Tests track real native owners
only to cancel/drain/close their resources after each case.

Four additional real consumer tests cover public async/last-committed semantics,
exact numeric/invalid9 UI behavior, typed failed override without publication,
read-only initial preparation and catalog supersession across upload/commit.
The native bootstrap equality test also passed. Full native gate: **259 tests +
16 compile-fail**, fmt, locked build and strict all-targets Clippy passed. Touched
ten production Lisp files pass Werror bytecompile/checkdoc. Bytecompile outputs
are redirected to a task-specific /tmp directory, never the source tree.
Full source ERT results and final timestamp are recorded in 12 after completion.
No new TLC refinement proof is claimed: existing abstract preparation models do
not encode this concrete metadata revision protocol. Native/stdio/editor tests
are the executable evidence, not proof of every interleaving or all 01 compliance.

The user's shell.nix/07 edits and 01 are untouched. No external provider account,
model request, CLI installation, credential migration, merge or push was used.
