# Native edit transaction ownership

This is the contract and acceptance map for todo 3. The checkboxes and remaining
implementation work live only under item 3 in `todo.md`. A native parser library
is preparation evidence; it does not establish an editor consumer cutover.

## Authority and the editor boundary

Rust owns proposal text/hash, patch framing, hunk counts, review revisions,
approval/issuance, batch/journal state, snapshot stacks and rollback eligibility.
Emacs owns actual live buffers, document identities/ticks, atomic change groups,
undo/markers/point/narrowing, file coding and save hooks, Ediff controls/windows,
and notifications. All editor files, including closed files, go through the
editor transaction adapter. There is no competing native disk edit path.

A parsed patch, a content digest, a client-provided identifier and an editor UI
projection are never apply capabilities. An issued editor operation comes from
the shared native permission gate, under its actual application/session/run,
generation and config/policy revisions. Editor edit approval must extend that
gate with a closed edit action; it must not synthesize a fake command or create
a second permission ledger. The edit service owns transaction/journal state,
not an independent permission decision engine.

Preparation captures a canonical root and explicit target scope, immutable
base/proposed decoded text and hashes, disk identity/revision, and a live document
identity/tick when present. New targets capture absence and the existing ancestor.
All files are preflighted before the first buffer mutation. The native filesystem
worker is bounded and cancellable between OS calls; actual worker/process joins
retain their slot. Large uploads/captures must be chunked with backpressure before
the native editor capability is advertised. No source text belongs in Debug/logs.

The default tool contract preserves current dirty-buffer rejection without
changing the buffer or disk. Live document evidence still uses actual widened
buffer text, not a stale disk copy; an intervening tick, read-only state or disk
revision is a conflict. This does not authorize erasing or saving unsent user edits.
Save policy is an explicit `buffer_only` or `save` enum. Save hooks run in the
editor and their actual final content/hash/revision and failure are reported.
The currently recorded policy is frozen across asynchronous preparation/review.

## Protocol and lifecycle requirements

The intended owned transaction is:

1. Capture/upload bounded editor source facts and native path/revision evidence.
2. Prepare immutable native proposal. Literal replace is unique, case-sensitive
   and non-overlapping; full writes do not acquire implicit save rights.
3. For Unified Diff, validate framing and operation/path policy, then run real
   Git against an owned isolated workspace through the shared supervisor.
   Complete output and final targets become one immutable native proposal.
4. Register the actual proposal with the shared permission ledger. Auto policy
   is a captured native policy decision; interactive accept/reject/interrupt,
   deadline, owner/config/document changes, and missing presenter are distinct.
5. If Ediff changed the proposal, publish and validate a new native review
   revision before granting its exact text. UI content hashes do not silently
   rewrite the already reviewed action. A late button cannot approve a new revision.
6. Commit the appropriate native journal records before issuing the consuming
   native editor token. The adapter rechecks live evidence and
   applies through atomic change groups, preserving editor state and coding/EOL.
7. Accept the real per-file receipt, reconcile save-hook effects and journal the
   terminal result. On partial batch failure, request rollback only against a
   still-owned written revision. Foreign buffer/disk state is preserved.
8. Cancel/close revokes new writes and reviews first, then retains issued work,
   receipt/journal/rollback/process cleanup until actual drain. A lost receipt or
   interrupted journal leaves explicit unknown effects; no automatic replay.

The final implementation must use consuming typestates for prepare/review/issued/
settled transitions. DTOs cannot construct an issued grant. Duplicate edit IDs
return a recorded result or stale error, and never issue a second editor write.
Passive UI views are detached, owner/revision-qualified observations; they cannot
start IO, claim a service, or replace its canonical native state.

## One typed result

The native result has one edit identity and revision, canonical scope, and an
ordered file result list. Every file has its path/action, status, base/proposed/
accepted/final content evidence, actual document/disk post-revision, save state,
hook transformation and rollback/write effect. Statuses must distinguish applied,
partial, unchanged, rejected, interrupted, conflict, unavailable, failed,
rolled-back and outcome-unknown. Pending/staged review is lifecycle state, not a
terminal successful file result. Batch outcome derives from these actual records,
not a string prefix. A multi-file patch must not be wrapped as a synthetic one-file
`unknown` result or fabricate a one-hunk success.

Hunk counts belong to the revision that was actually granted/applied. A human
edited proposal is a new revision with its own measured preparation; original
requested hunks are separate evidence. If evidence is incomplete, an exact count
is unavailable rather than guessed. Save-hook transformation is measured against
the granted text. A passive observer failure cannot turn a completed write into
rollback, nor can a presenter error erase a recorded commit.

The journal records issuance before effects and settlement afterward, with bounded
records, sequence/integrity and explicit recovery. Started but unterminated work
is recovered as unknown, without issuing it again. Process-local batch recovery
is not a filesystem CAS, a filesystem lock, or multi-file crash atomicity.

## Existing consumers and acceptance map

| Current consumer/source | Native responsibility and acceptance evidence |
| --- | --- |
| `tools/diff.el` edit/write/patch tool executors and aliases | One registry/mode/gate path, real async callback and typed file/batch result. `test-tools`, `test-tool-gate`, `test-patch`, `test-security`. |
| `tools/diff/stage.el` literal replace, proposal and pre-state decisions | Move pure preparation and revision decisions; retain only live transaction/save/undo interop. Missing/ambiguous/case-sensitive matches, unchanged, narrowed full snapshots, read-only and dirty conflicts. |
| `tools/diff.el` parser, isolated Git staging and batch | Native framing/normalization, isolated Git through shared supervisor, preflight all targets, actual counts and partial/unknown results. `test-patch` and `test-edit-transaction`. |
| `tools/diff/context.el` plans/outcome wrapper and resource registry | Native immutable plan/grant and owner lifecycle, exact typed result; no string summary conversion and no hidden default service. `test-edit-service`. |
| `tools/diff/review.el` Ediff decision and pending state | Native review revision/decision; Emacs keeps controls and accepted text only. Stale/duplicate/foreign control, async/blocking/reject/C-g/missing presenter and active close. |
| `tools/diff/track.el` snapshots/change/baseline/stats/rollback decisions | Native journal/snapshot stack and CAS-style eligibility; retain editor rollback mutation/undo adapter. Single-step restoration, foreign change guards, save-hook mutation/failure and final hashes. |
| `edit.el` optional edit/change provider | Keep the optional port, one typed result and explicit unavailable; async native submission, no synchronous wait/fallback. |
| `tools/lsp/symbols.el` and `tools/lsp/register.el` | Preserve captured symbol response revision and use the same edit service. Live LSP request/sensor behavior remains todo 4. |
| `loop.el`, `loop/tools.el`, `loop/heal.el` | Read owner-qualified native change/baseline evidence and reset/consume/abort the same service. `test-edit-transaction`, verification and loop fixtures. |
| `chat/render.el`, `ui/transient.el` | Passive native stats/review views and owned interactive rollback; no synchronous disk scan or default/global edit lookup. |
| `tools/process.el` remaining diff consumer | Remove after isolated Git apply moves; Dape/session consumers remain outside todo 3. |

The named suites above remain the acceptance corpus, including related UI and
loop tests. Native integration tests complement rather than replace dirty/undo/
save-hook/multi-file/foreign rollback evidence. The relevant
bounded model is `proof/KarguEdit.tla` / `EditMC`, with application and approval
models updated if shared claim/permission transitions change. Compile-fail tests
must cover unit interchange and non-constructible/replayable apply authority.

## Native preparation evidence so far

`edit/types.rs`, `proposal.rs`, `review.rs` and `patch/` provide bounded text/hash/path units,
unique literal replacement and complete hunk framing/normalization. Git remains
the apply/matching engine. Quoted Git paths, including UTF-8 octal escapes, are
normalized to escaped headers; binary, rename/copy, unsupported modes, absolute/
traversing/reserved/control-bearing paths and incomplete/count-overflow framing
fail explicitly. Source lines resembling `---`/`+++` stay hunk body text.

The normalizer is checked against real Git add/update/delete/no-final-newline and
quoted Unicode/backslash/quote path fixtures, with no user index. The format
reference is Git's [diff-format](https://git-scm.com/docs/diff-format) documentation;
acceptance is established by the installed Git fixture, not a claim to implement
all of Git's diff formats. The `edit_preparation` capability advertises only
read-only preparation, not permission to edit. Existing Elisp mutation consumers
remain active until the complete native transaction boundary is ready.

## Owned native preparation port

`edit/begin`, `edit/append`, `edit/prepare`, `edit/read`, `edit/abort` and
`edit/close` use the application/session lease plus a typed source origin ID.
Begin freezes replace/write intent, root, policy/config revisions, review/save
policies and optional live document identity/tick/coding/disk evidence. Dirty and
read-only live captures refuse preparation. Text parts have declared UTF-8 byte
lengths; exact-offset chunks are capped at 32 KiB and adjusted to the negotiated
frame budget. The connection retains its 1 MiB ceiling, including control-byte
escaping. Source bodies do not enter descriptors, errors or implicit Debug.

One application actor owns at most two upload/inspection/collecting/preparing/ready
entries and 16 MiB of text-byte reservations. Adoption shrinks ready reservations
to actual base/proposed byte lengths, so small replacements do not retain their
worst-case capture budget forever. A patch reserves the full budget during capture
and Git preparation. Upload expires after 30 seconds; adopted immutable views
expire after five minutes. Preparing work consumes owned input on the existing
four-worker read pool, shared with file/configuration/skill reads. Workers return
a typed completion to the stdio actor; only that writer adopts it before replying.
Cancel, origin close, session/application close and expiry revoke publication;
worker admission and staging reservations remain occupied until actual join.
Pool admission failure releases the unstarted staging record.

Native capture holds root, canonical path and stat evidence. It rejects outside
or protected metadata targets, including symlink aliases into `.git`, broken
symlinks, directories and special files before reading data. Missing targets pin
the existing ancestor and preserve absence evidence. Disk decode reuses the
shared file decoder and bounds raw/decoded content; CRLF maps to editor LF.
A supplied clean live document permits editor-decoded content (including coding
not supported by native decode), but its exact disk revision must still match.
Both hashes are computed off the actor and retained with the immutable contents.
Read pages perform no filesystem IO. No operation writes the original file,
returns an apply grant, claims an applied hunk, or refreshes captured evidence.

`kargu/bridge/edit.el` detaches metadata and owned UTF-8 text before its first
yield, sends a single chunk until its exact ACK, and checks source/document guard,
deadline and exact application lease at each boundary. It releases late native
allocations even after task cancellation. A successful handle is transferred to
the caller for explicit release; it only permits bounded base/proposed reads.
Missing capability reports unavailable without editor file IO or a replacement
engine. Public edit tool consumer cutover belongs to todo 3.8.

## Supervised native patch preparation

The `edit_patch_preparation` capability adds `edit/inspect`, `edit/targets`,
`edit/document` and `edit/files`. Inspection parses the already uploaded patch on
the shared read workers. Its actor-owned plan supplies bounded target pages;
Elisp has no second target parser. Named live documents can be attached once to
those exact targets, with native file-index upload parts and exact-offset ACKs.
Dirty/read-only, foreign/duplicate document identities and incomplete uploads
refuse preparation. Patch input and source lifetime stay captured throughout.

Final `edit/prepare` consumes the plan into the existing command mailbox. A worker
captures all canonical source pins and complete decoded bases, rejects target
aliases and invalid add/update/delete preconditions, and checks zero-context
ambiguity before Git. It creates a private repository/worktree with explicit
config, index and patch paths. The existing shared ExecutionGate and
ProcessSupervisor execute fixed Git argv. Git has no original file path in its
command or environment; original pins remain in the result report and are
revalidated off the actor before publication. No original project index is read
or written. Global/system Git configuration is disabled; private highest-priority
attributes neutralize filter/EOL/encoding effects even when `.gitattributes` is
itself a patch target. Actual matching/application remains Git's work.

The consuming `PatchPrepared → RunningPatch → immutable batch` states retain the
private workspace until actual process-group/pipe drain and final snapshot IO.
Cancellation, expiry or source/application close revoke publication while the
command and preparation reservation remain held. Failure, missing Git, oversized
or incomplete output, stale source pins and resource overflow publish no file
prefix. The owned workspace closes explicitly on success, error or discard.
Private output is read as exact bounded UTF-8, retaining literal BOM and final
newline state. Original source coding/disk evidence remains separate.

Batch descriptors contain actual parsed requested hunk counts and paged immutable
file views with operation, hashes, source evidence and file index. Target and file
metadata paging serializes each item once rather than repeatedly serializing an
expanding page on the actor. Read-only preparation still issues no editor grant.
Revised review text, effective save-hook results and actual editor outcomes belong
to the later revision/gate/transaction/journal boundary, not these prepared counts.

`kargu/bridge/edit/patch.el` supplies only inspected target/document transport,
preparation and paged views. It detaches metadata/text and reuses the bounded
ACK-driven uploader. It never calls the legacy parser or writes editor files.
Oversized caller text is rejected before copying/encoding or native startup.

## Current verification and next integration boundary

Preparation/review domain: 9/9, including real isolated Git. Native file preparation
pipe: 6/6, including two small same-path replacements with distinct source owners.
Supervised patch pipe: 8/8, including 256 targets through 2 KiB metadata frames,
CRLF/Unicode/literal BOM/no-final-newline, named live coding, aliases, ambiguity,
source replacement during Git, private filter/config isolation, missing Git,
aggregate/expanding output bounds and TERM/KILL/actual cleanup. Shared worker
regressions: 8/8. Real Emacs file/patch transport: 8/8, including capture guards,
late allocation release, metadata detach, old-core refusal and pre-copy bounds.
Compile-fail: 26/26. Strict locked all-targets Clippy, fmt and changed Elisp
warning-free bytecompile/checkdoc pass.

After the filesystem/network sandbox restriction was removed, the unfiltered
locked Cargo suite passed all 394 tests (67 library, 301 integration, 26
compile-fail), and the full ERT suite passed 1,279/1,279 without skips. This includes
the HTTP and Unix socket fixtures previously rejected at bind. These are full
regression results for the preparation slice; actual native editor writes,
save-hook settlement, native rollback and consumer cutover are still open.

Standard BFS TLC now completes with an empty queue for Edit (560 distinct states),
Application (4,624), Approval (49,152), Process (179) and native preparation (319,746).
The preparation/approval counts include the editor admission extension below.
The native preparation model retains two preparation IDs and two separate
source-owner IDs modulo identity-renaming symmetry. It models byte/worker
reservations, inspector/command/process joins, cancellation/close/expiry and the
full-capture/Git/drain publication order. A mutant dropping a live cancellation
reservation violates `ActualJoinBeforeRelease`. A depth-limited EditMC run returning
zero without a completed-exploration verdict is rejected by the hardened runner.
This is bounded safety evidence, not a proof of concrete IO, content hashing,
editor transactions or liveness. See `proof/README.md` for commands and counts.

The shared `ExecutionGate` now has a closed `EditorAction` branch in the same
bounded pending map as commands. It commits to ordered file operations, native
source/review revision, base/proposed hashes, capture digest, pinned workspace,
config/policy and review/save policy. Action types have no implicit Debug or
Serialize implementation exposing source bodies. Native run settings must share the exact captured workspace handle;
a separately recaptured directory at the same path cannot substitute for it.

`EditorAdmission` returns either a pending review or a consuming
`AuthorizedEditorEdit`. Auto policy authorizes without a presenter; async and
blocking require one. Delete requires auto policy. Foreign owners, stale review
revisions and wrong action kinds cannot consume another pending entry. Reject,
interrupt, expiration and source/run revocation use the existing tool ledger and
shared drain. Accepted authorizations retain the actual run lease until explicit
unissued cancellation or the future issued transaction consumes them. They cannot
be forged or cloned, and do not claim an applied effect.

Seven integration tests cover these shared-ledger owner/replay/deadline/resource
boundaries and command coexistence. The unfiltered locked Rust suite passes
403/403, including 28 compile-fail cases; strict all-targets Clippy and fmt pass. The extended approval model checks both action
kinds and twelve authority fields: 360,452 generated / 49,152 distinct states,
empty queue, depth 15. Removing the kind guard violates `Safety_ExactActionKind`
after 16 distinct states. Preparation IDs/capture hashes remain insufficient
permission; this does not establish an editor write port.

The actual `edit/authorize` RPC now consumes one ready preparation into that
shared gate. It accepts only the preparation/source and presenter availability;
callers cannot submit a replacement root, action text, policy, mode or config.
`edit/decision` accepts one exact native edit ID/source/review revision and an
explicit accept/reject/interrupt. Replies contain lifecycle state and the actual
native run scope, always `applied:false`. Proposal text and per-file evidence stay
available through the existing bounded preparation pages during review.

A new `RunPurpose::EditorEdit` has an independently bounded actor-owned lifetime.
It neither impersonates a process job nor holds the foreground turn during async
review. File/root pin revalidation and action hashing run on bounded command
preparation workers. The actor only adopts a consuming `PreparedEditorSettings`,
without filesystem IO. Command and editor preparation share the same global
worker admission bound; their actual permission entries share one `ExecutionGate`.

Preparation records transition to a retained `Claimed` state before worker launch.
Base/proposed `Arc<EditText>` references share immutable source allocations rather
than duplicating reserved text. The original file/document evidence and source
reservation remain owned while preparing, reviewing or authorized. Abort, expiry,
source/session/application close, shutdown and EOF revoke publication first;
only actual worker join and explicit native unissued-grant/tool/run cleanup
release the record. Claiming or deciding twice cannot produce a second grant.

Seven real pipe tests cover foreign source/session, stale revision, replay,
missing presenter, rejection/interruption, 1 KiB frames, retained paging/capacity,
source replacement, foreground command coexistence and all close paths. The
unfiltered locked Rust suite passes 411/411 (28 compile-fail), strict all-targets
Clippy and fmt pass, and the existing Emacs preparation/patch pipe tests pass 8/8.
A held
blocking-worker test verifies capacity remains occupied after cancellation until
its actual join. Native preparation TLC now includes claim/review/authorization:
480,956 generated / 97,230 distinct states, depth 28, empty queue. Freeing a
reviewed claim on cancellation violates `ClaimOwnership` after 765 distinct
states. Application and shared approval scans also complete without errors.

The admission branch now feeds consuming journalled issuance as described below.
The actual Emacs transaction adapter and complete receipt settlement remain open. Its consuming
issued state must retain the real editor settlement/drain barrier across
cancellation; timing out a reverse RPC alone is not proof that a queued or
executing editor write stopped. Revised Ediff text still needs a new measured
native revision. The old Elisp consumers remain active until that boundary and
native journal/rollback are wired and tested, then are removed. Todo 3 remains open.

## Native journal storage boundary

`edit/journal` now provides the bounded metadata-only issuance store. Its closed
schema records the native edit ID, scope, review revision, ordered path/operation,
base/proposed/capture hashes and frozen policies. Source text cannot deserialize
into that schema. Recovered `RunScope` values remain data; only private live
`RunHandle` ownership participates in permission checks.

The caller supplies an existing private state directory outside the captured
editor workspace. Worker IO pins that directory and requires effective-UID
ownership and mode 0700. New journal files use fd-relative `O_EXCL`/`O_NOFOLLOW`,
mode 0600, regular-file/single-link checks and an exclusive writer lock. Existing
names are never truncated or replaced. Root/path replacement, changed file
revision, symlinks/hardlinks, special files and permissive modes fail closed.
Recovery first takes a metadata-only pin, so a FIFO/device never receives a data
open. Advisory locks exclude cooperating writers/readers; they are not a sandbox
against another process with the same user's write authority.

The consuming `IssuedJournal → UncertainJournal → JournalCommit` types permit one
issuance, an optional uncertainty marker, and one terminal receipt commitment,
explicit no-dispatch record or unknown result. Direct issuance-to-commit is also
valid. Every record is newline-framed, versioned, sequenced and SHA-256 chained;
file and directory sync finish before a committed state is returned. Limits are
4 MiB per encoded record, three records and 12 MiB plus framing per file. These
are per-file bounds, not a store-wide retention policy.

Recovery takes a shared lock and returns Busy while the real writer remains
owned. Missing, cut, malformed, reordered, mismatched or corrupt records yield
unconfirmed/unknown evidence rather than implicit success. Even a valid terminal
record followed by junk becomes unknown. Recovery never creates a live run,
constructs a grant, appends or replays an editor write. A receipt commitment means
that receipt was recorded; actual file/batch status still comes from native
receipt validation. Checksums detect inconsistent records; they do not authenticate
against a same-user process capable of rewriting the complete chain.

The unfiltered locked Rust suite passes 420/420, including 29 compile-fail cases;
strict all-targets Clippy and fmt pass. Eight native tests exercise real
file/lock/permission operations, every byte cut
in a terminal record, lost receipt, late resolution, source-free schema, limits,
cancellation, root replacement and foreign writes. The new `--edit-journal` TLC
model completes 4,077 generated / 1,116 distinct states at depth 14 with an empty
queue. Treating an issuance-only prefix as terminal violates
`NoPrematureResolution` after 49 distinct states. The model assumes synced-prefix
persistence and does not prove filesystem/hardware power-loss guarantees.

The storage kernel now feeds the actual IPC issuance/quiescence worker stages
below. It does not close 3.6: complete actual adapter receipts, native outcomes/
counts, snapshot-stack/rollback ownership and consumer cutover remain outstanding.

Claim lifetime expiry uses a typed owner-scoped status rather than a boolean.
The preparation/source deadline may precede the later gate/run deadline; this
must complete both pending reviews and accepted unissued authorizations as
Timeout, without changing explicit cancellation or foreign-owner behavior.
A real preparation/actor/gate regression covers auto and async policy, releases
the native run and reservation through normal cleanup, and checks actual tool
results. The unfiltered locked Rust suite passes 421/421 (29 compile-fail), with
strict all-targets Clippy/fmt and the preparation TLC scan clean. This fixes todo
3.12; it does not establish editor issuance or completion.

## Complete native preflight observations

`edit/preflight` accepts one closed live-document witness per file under the
existing edit/source/review revision. The actor compares only cached evidence:
base hash and UTF-8 byte count, exact initial live identity/tick/coding when one
was captured, disk revision and clean/writable flags. Duplicate file indices or
document identities and foreign/stale owners cannot advance the count. There is
no replacement text, path, policy or root in this input.

The complete set transitions to a consuming bounded worker. That worker rechecks
all captured root/file pins and hashes the ordered, typed witness set. Only its
actual completion can publish `state:preflighted`, with a native fingerprint and
real total/checked file counts. Partial sets remain partial. The completed state
retains the immutable witnesses and the original unissued grant. Command and
editor preparation still share one admission bound, and source cancellation,
close or deadline holds the grant/reservation until actual worker join/cleanup.

Five real pipe tests cover single-file and multi-file/out-of-order witnesses,
duplicate identities, stale live metadata, base/disk mismatch, a foreign change
to an earlier file before final preflight, a 1 KiB frame and owner closure. A held
blocking-worker regression checks that cancellation releases neither capacity nor
the run lease before the actual join. Unfiltered locked Rust passes 427/427 (29
compile-fail), with strict all-targets Clippy and fmt clean.

The preparation model now includes per-target witnesses, preflight-worker
ownership and full-set publication. Its exhaustive scan completes 1,568,116
generated / 319,746 distinct states, depth 36, empty queue. Removing the full-set
guard violates `CompletePreflight` after 775 distinct states. This is a bounded
resource/completeness model, not a filesystem CAS or an atomic observation of
all Emacs buffers. Witnesses describe observed state; the actual adapter must
recheck every live target before its first mutation.

No editor mutation capability is advertised to the product yet. The actual Emacs
witness producer, editor transaction/complete receipt, revised-review measurement
and native rollback/consumer cutover remain outstanding.

No-op classification now has one native implementation for full writes and final
Git batch proposals. Equal logical hashes do not make saving an absent target a
no-op, even when an existing clean live buffer already has that text. A live-only
buffer can satisfy `buffer_only` without creating a disk file. Actual deletion of
an existing empty file remains an effect, while an absent add/delete net result
remains unchanged. Real red→green pipe fixtures cover eight empty full-write
existence/live/save combinations and empty Git adds under both save policies.
Preparation still never writes originals. The unfiltered locked Rust suite passes
429/429 (29 compile-fail), strict Clippy/fmt and preparation TLC pass. This closes
3.13, not the outstanding actual editor create/save/receipt boundary.

## Actual native issuance and quiescence

`edit/issue` accepts only a preflighted native edit/source/review revision plus the
trusted editor's private journal directory. It consumes the unissued grant and
rechecks every source pin on a bounded worker, then records the actual operation,
scope, issuance nonce and immutable preflight fingerprint. File and directory sync
finish before the actor can revalidate ownership and return `state:issued` with
one opaque token. No root, proposal text, mode or policy can be replaced here.
Existing v1 journals without issuance fields keep their original checksum bytes;
a separately encoded legacy fixture verifies backward read compatibility.

If cancellation wins before the IO completion is adopted, the native actor keeps
the grant until the real join and records explicit no-dispatch before cleanup.
After publication, a consuming `IssuedEditorEdit` owns the run lease. Source close,
Stop, deadline and application/session retirement revoke execution first and emit
`editor/revoke_edit`; none implies editor quiescence. The global editor writer
fence and one cleanup-worker reservation stay held throughout issued activity and
terminal journal IO. Other sources may prepare/review while this fence is held.

`edit/quiescent` requires the exact original connection-owned scope, source,
edit/review revision and issuance token, including after that session/application
retires. It currently accepts only explicit `not_dispatched` or `outcome_unknown`
facts. Claimed success strings are rejected: an ordinary applied receipt still
needs bounded native text/evidence validation in the next integration. Quiescence
ACKs are lifecycle facts, not synthesized file/batch success or hunk counts.
Terminal journal append runs off the actor with its own cleanup lifetime. Only
its actual join completes the native tool/run and releases the preparation.
Settlement IO failure reports unknown, never success or automatic replay.

EOF/writer failure closes admission for that connection and records terminal
unknown before native IO drains. That does **not** prove an external editor handler
stopped: the actual Emacs adapter must retain a local activity fence across
connection replacement until its handler is truly quiescent. An issue acquisition
observer must also survive UI cancellation long enough to handle a late token or
failure; dropping that observer is not resource drain. The mutation capability
remains unadvertised until those platform guards and full receipts are connected.

Seven real pipe tests verify sync-before-token, cross-process journal locking,
nonce/owner/revision/replay rejection, complete preflight, unusable journal/source
change refusal, 1 KiB frames, global fence, retired-owner completion, failed
settlement, EOF unknown and preservation of controlled editor/foreign effects.
Two controller tests hold a synced journal completion and expire an issued timer,
verifying that actual join/quiescence remains required. Unfiltered locked Rust:
439/439 including 29 compile-fail; strict all-targets Clippy/fmt and existing Emacs
prepare/patch pipe tests 8/8 pass.

`--edit-issuance` checks the composition of complete preflight, journal worker
sync/join, one writer, revocation, explicit quiescence, terminal IO and EOF without
replay: 1,631 generated / 440 distinct states, depth 15, empty queue. Early release
on revoke violates `HoldIssuedUntilReceipt` after 53 distinct states; omitting the
sync evidence violates `JournalBeforeDispatch` after 24. The journal prefix model
also remains clean. These bounded native models assume truthful quiescence and
do not prove actual Emacs behavior or a fence spanning multiple connections.

## Live editor document primitives

`bridge/edit/document.el` captures bounded widened text, stable buffer identity,
tick, coding, dirty/read-only state, canonical path and the same stat fields as
native `DiskVersion` (excluding atime). A copied buffer cannot borrow the original
document identity. Its native witness encoder preserves integer nanoseconds and
hashes the actual captured text rather than echoing the proposal's base hash.

A consuming replacement rechecks the clean snapshot immediately before entry,
uses `atomic-change-group` and `replace-buffer-contents`, and preserves undo,
point, mark, narrowing and markers in unchanged text. Explicit save retains the
captured coding/EOL and invokes actual save hooks, including empty absent-file
creation. It checks live issuance before replacement/save and disk/path identity
again before save. Failed hooks retain actual observations; foreign disk changes
are never blindly restored. A killed or oversized final buffer has explicit
observation failure. Recorded primitive stages are not domain applied verdicts.

Fifteen real-buffer tests cover these cases. One real native pipe test uses the
shared gate and complete preflight, waits for synced issuance, performs a real
CRLF/Unicode editor save and records terminal `outcome_unknown`. Positive receipt
validation is still absent; the test deliberately does not fabricate success.
A second pipe test proves that a stale clean buffer with unchanged tick and the
same byte count cannot pass native preflight against different disk contents.
These primitives are not connected to public tool consumers. Full receipts,
batch/rollback and consumer cutover remain required before advertising native
mutation capability. The issued observer and activity fence are connected below.
Full ERT passed 1,294/1,294 before the final witness/read-only additions; the final
affected suite passed 17/17. Changed Elisp sources compile with warnings treated
as errors and pass checkdoc. Native Rust state transitions/models are unchanged.

## Emacs issued activity lifetime

`bridge/edit/activity.el` acquires `edit/issue` only on the captured connection,
source, scope, revision and complete-preflight fingerprint. The forward observer
has no UI buffer owner or delivery timeout: a separate source timer/kill/mode
cleanup revokes via native abort without discarding a late nonce. A late token
after revocation is settled as not dispatched. Actual source validity is checked
again after caller guards, and native revocation notices match their original
connection/edit/source/token. Duplicated responses cannot rerun a handler.

One Emacs activity fence spans native applications and connection epochs. It
remains held during queued acquisition, synchronous handler execution and native
terminal settlement. EOF inside a handler revokes new primitive entry but cannot
release the fence; the handler's actual unwind does. EOF after quiescence finishes
once even when pending request callbacks are subsequently drained. Malformed or
rejected settlement drains the original connection; a different connection is
never substituted. Observer failures after settlement do not reverse it.

Eleven held-peer tests exercise real bridge waiters/notifications/EOF, actual timer
expiry, late/duplicate replies, source kill, reentrant guards, native revoke,
Stop, C-g/nonlocal exits and settlement failure. The real CRLF/Unicode native pipe
test now acquires, applies and settles through this controller and the document
adapter. This controller currently reports entered handlers as outcome unknown:
positive native receipt ingestion and the production batch producer are still
required. Handler callbacks must be synchronous and must not schedule deferred
file effects; their return is the platform quiescence fact.

`--editor-activity` explores two activity identities and two connection epochs:
933 generated / 356 distinct states, depth 15, empty queue. It composes with the
native issuance model by assuming actual native publication follows that model's
gate/preflight/journal sync. It checks physical fence retention, observation
ownership, single entry and no overlap across disconnect/reconnect. Releasing on
EOF while a handler is running violates `PhysicalFence` after 20 distinct states.
These are bounded safety checks, not a liveness or arbitrary save-hook IO proof.
Full ERT passed 1,306/1,306 before the final Stop/unwind addition; the final native
edit suite passed 33/33. Changed Elisp files pass warning-as-error byte compilation
and checkdoc. Native Rust sources and their original-file IO ownership are unchanged.
