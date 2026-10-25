# Config-backed provider selector — 2026-10-25

## Observed failure

The reported config.yaml path does not exist in this environment. The actual
file is ~/.config/kargu/config.toml; it parses successfully and declares five
providers. No file was renamed, converted, edited or copied. No YAML parser or
fallback was added: the documented input contract remains the strict TOML subset.
Diagnostic output included provider names/counts only, never configuration
contents, API keys or environment values.

The config service intentionally has passive memory-only readers. Provider UI
entry had not been migrated to an explicit refresh, so a cold menu saw an empty
application config even though the file existed. A real worker refresh changes
the observed provider count from zero to five. Separately, connected-providers
only enumerated registered catalog IDs; authenticated custom IDs in the config
were excluded even after successful publication.

## Implemented boundary

The footer provider selector now resolves its view before starting an owned,
cancellable config refresh. chat/select/config is the small UI lifecycle port:
it calls the existing bounded worker, not another file reader/parser. Repeated
opens cancel only that view's predecessor. Kill/major-mode change cancels the
actual child; other views/application workers remain independent. Synchronous
test adapters and reentrant completion cannot leave stale task/hook ownership.

The popup opens only while application owner, session, immutable selection,
selector generation, focus, point and draft remain captured and work is idle.
Failure reports the existing payload-free configuration error, does not open a
misleading stale/empty picker, and keeps the last valid configuration snapshot.
Reopening refreshes edits rather than reading files from a passive getter.

Connected provider candidates are the deduplicated sorted union of registered
IDs and published custom IDs, filtered by the existing fast credential/keyless
reader. No auth-source unlock, credential-function execution or upstream API
request was added. Custom IDs are not inserted into the global provider catalog.

## Evidence

The new real-XDG regression failed on the old implementation: provider selection
returned without a refresh task. After the fix it covers cold startup, custom
authenticated/keyless IDs, placeholder exclusion, reload after edit, malformed
reload retaining the last good snapshot, secret-free notes/errors, no editor-
thread file reading and no upstream HTTP. Three additional tests cover stale
application/session/selection/focus/draft/point/busy results, supersession and
independent owners, and actual child termination on kill/mode change.

Existing general workflow/matrix tests explicitly inject their already-published
synthetic config adapter; they do not read the user's config. Real config/worker/
selector integration tests remain unmocked at that boundary. No assertions or
module dependency baselines were removed. 32/32 focused tests and **1216/1216
full source ERT**, 0 unexpected, **129.27 s** at 18:57:14 Europe/Istanbul passed.
Three production files passed Werror bytecompile and checkdoc. Their three
generated elc artifacts were moved to /tmp/kargu-provider-picker-elc.5Tbx7D
before the full source run; no generated elc remains in the source tree.

A separate read-only check against the user's actual TOML through the patched
selector returned GUI candidates llama_cpp, llamacpp, nvidia, opencode and
openrouter. The user's file and unrelated shell.nix/07 edits were untouched.
Native production did not change; the prior 258 native + 16 compile-fail,
fmt/strict Clippy/locked build gate is historical, not a newly claimed rerun.

This is a UI config-consumer regression repair during migration, not completion
of native config parsing or the public model metadata setter/catalog/UI cutover.
Those remaining migration obligations are unchanged; no account/CLI/API model
turn, dependency install or external coordination was performed.
