# Kargu

> [!WARNING]
> **Active Development**: Kargu is actively being developed and evolving rapidly. Errors or unexpected behavior may occur. Please feel free to [report issues](https://github.com/ehanhalici/kargu/issues) or submit feedback!

**Kargu** is an agentic AI coding assistant and pair-programmer for GNU Emacs.

Rather than running heavy external daemons or separate browser windows, Kargu turns Emacs itself into the agent runtime. It seamlessly integrates with the packages and workflows you already use every day—giving AI models structured, token-efficient access to your codebase while keeping you in full control.



---

## Key Highlights

- **Agentic AI & Autonomous Workflows**: Models can autonomously explore workspaces, inspect symbols, search across codebases, propose edits, and execute terminal commands through a secure loop.
- **Deep Emacs Native Integration**:
  - **LSP (`eglot`)**: Structural project outlines, diagnostics, definitions, and symbol resolution without dumping raw files into context.
  - **Interactive Diffs (`ediff`)**: Review proposed AI file edits with hunk-level inspection, approval, rejection, and full rollback capabilities.
  - **Live Debugging (`dape`)**: Inspect paused debug sessions, read call stacks, inspect variables, and evaluate expressions during active debugging.
  - **Version Control (`magit` / Git)**: Inspect branches, diffs, commits, and status directly.
  - **Interactive Menus (`transient`)**: Fast keyboard-driven menus for configuration, modes, and tuning.
  - **Non-blocking Asynchronous Core (`plz`)**: UI operations stay smooth and responsive with streaming SSE output.
- **Multi-Provider Support**: Connects to OpenAI, Anthropic, OpenRouter, Google Gemini, Ollama, LM Studio, llama.cpp, and more.
- **Multiple Operational Modes**:
  - **`ask`**: Instant read-only answers and explanations.
  - **`plan`**: Multi-step implementation planning in an in-memory buffer before executing.
  - **`agent`**: Autonomous multi-turn problem solving with tool execution.
  - **`debug`**: Contextual assistance plugged directly into your active DAP session.
- **Human-in-the-Loop Safety**: Dangerous shell commands and paths outside the project always ask. File edits follow the review mode: `auto` (default) applies them at once and keeps a rollback snapshot, `async` and `blocking` write only after you accept the diff. Approvals are non-blocking buttons with a prompt fallback.
- **Formally Checked Loop**: The agent loop and the protocol wall are specified in TLA+ (`proof/`) and checked exhaustively with TLC.

---

## Installation & Requirements

### Prerequisites
- GNU Emacs 29.1 or newer
- Required for the native model transport: `plz` and the `curl` executable.
- Optional interface packages: `transient` (menu), `company` (completion),
  `magit` (Git interface).
- Optional integrations: `eglot` and a language server for LSP tools; `dape` and a configured debug adapter for debug mode. Kargu works without LSP.
- Feature-specific utilities: `rg` (ripgrep) or `grep` for search, `git` for
  version control. Their absence does not block unrelated model runs.

Set `(setq kargu-ui-enabled nil)` before `(require 'kargu)` for headless use.
Explicit custom additions to `kargu-deps-mandatory-packages` or
`kargu-deps-mandatory-executables` remain mandatory.

### Setup

Clone the repository and add it to your Emacs `load-path`:

```elisp
(add-to-list 'load-path "/path/to/kargu")
(require 'kargu)
```

---

## Configuration

### Experimental Rust core

The Rust core provides bounded JSON-RPC IPC, application/session lifecycle,
native `find_files`, GNU `ls` listing, `rg`/GNU `grep` search (including aliases),
`git_status`, and Bash/interactive jobs. The Elisp
agent still owns prompts and model requests; this is not yet a Rust agent backend.

The Rust library now includes typed run admission, single-use approvals and a
Linux process supervisor with bounded interactive I/O and group/subreaper
cleanup. Command execution uses exact-action reverse approval; persistent jobs
have scoped start/claim/status/read/write/EOF/cancel/forget ports. The Bash
tool uses this Rust engine, with no duplicate Elisp execution fallback.

Build with Rust 1.95.0 (Linux is the initial target):

```sh
cargo build --manifest-path kargu-core/Cargo.toml --locked
```

```elisp
(setq kargu-bridge-binary-path "/absolute/path/to/kargu-core/target/debug/kargu-core")
;; M-x kargu-bridge-start, kargu-bridge-status, kargu-bridge-stop
```

Loading Kargu does not start the binary. The first native search/listing or Bash invocation
starts and negotiates a shared connection asynchronously. Configure the binary
path above or install `kargu-core` on PATH. Missing binaries/capabilities are
reported explicitly; there is no duplicate Elisp glob implementation or silent
fallback. `kargu/bridge` can also be loaded independently of the agent, UI
packages, credentials, and `plz`.

Native discovery includes hidden sources, honors `kargu-fs-skip-dirs`, and skips
compiled/backup artifacts. It does not depend on fd/rg or machine-global Git
ignore settings. Visit/output limits report incomplete searches explicitly;
discovered symlinks are not followed. Direct directory listings delegate to GNU
`ls -lAh` with fixed safe options, returning its text unchanged. Missing GNU
tools report failure, not a custom scanner fallback. Listing keeps compiled/
backup entries, unlike glob discovery. The former entry-count limit and
`[DIR]`/`[FILE]` labels are gone; shared process timeout/output bounds apply.
Those bounds do not constrain GNU ls's internal sorting memory. The Lisp entry
point is asynchronous:
`(kargu-search-list-files path callback)`; calls without a callback return an
explicit error, never an implicit wait or an Elisp directory scan.
Stop revokes only the owning request.
Filesystem cancellation is cooperative between OS calls, not a guarantee of
interrupting a stalled filesystem syscall.

Run the Rust and real-pipe bridge checks with:

```sh
cargo test --manifest-path kargu-core/Cargo.toml --locked
KARGU_CORE_TEST_BINARY="$PWD/kargu-core/target/debug/kargu-core" emacs --batch -Q -L . -l tests/test-bridge.el -l tests/test-bridge-jobs.el -f ert-run-tests-batch-and-exit
```

### Model configuration

Kargu can be configured via a simple TOML configuration file (`~/.config/kargu/config.toml` or `~/.emacs.d/kargu.toml`), environment variables, or Emacs `auth-source`.

The configuration reader intentionally supports a strict TOML subset:
single-line basic/literal strings and string arrays (including multiline
arrays and comments). Top-level keys are `provider`, `model`, `name` (legacy
alias), `api`, `apikey`, and `review_mode`; provider tables accept `api`,
`apikey`, `model`, and `models`. Review modes are `auto`, `async`, and `blocking`.
Unknown keys/tables, duplicate definitions, wrong types and unsupported TOML
constructs are rejected with a file/line error. A malformed reload is not
partially applied and must be corrected before requests can use that config.

Run `M-x kargu-edit-config` to generate or edit your configuration.

Native sends and connection tests prepare configuration and credentials in
cancellable workers. Stop also cancels preparation. Each run captures its
endpoint, model, wire policy and credentials once; retries retain that target.
Authenticated HTTP requests refuse redirects and keep TLS verification enabled.
See [connection ownership](docs/connection-ownership.md) for service boundaries
and compatibility consumers.

Project walks and searches exclude names in `kargu-fs-skip-dirs` at every
directory depth. Customize this list when names such as `build` or `vendor`
contain your source code; the same setting applies to fallback traversal.

The API key of the active provider is looked up in this order:

1. the `kargu-api-key` variable (applies to the active provider only)
2. `apikey` in the provider's TOML table; `${VAR}` is replaced by the environment variable `VAR`
3. an explicit empty `apikey = ""` means "no key needed" and ends the search
4. the environment variable the provider catalog names (for example `OPENAI_API_KEY`)
5. `auth-source`, by the host of the provider's API URL

```toml
provider = "openrouter"
model = "anthropic/claude-sonnet-4.5"

[providers.openrouter]
apikey = "${OPENROUTER_API_KEY}"   # read from the environment

[providers.ollama]
apikey = ""                        # local runner, keyless

[providers."302ai"]                # names that start with a digit or hold dots are quoted
apikey = "${AI302_API_KEY}"
```

---

## Quick Start & Usage

The tuning menu retains temperature, output-token limit, reasoning effort and
thinking budget. Provider-specific JSON parameters and the `[params]` footer
have been removed. Legacy `kargu-provider-parameters` settings are ignored;
configure provider-side routing presets in the provider dashboard instead.

| Command                     | Description                                           |
|:----------------------------|:------------------------------------------------------|
| `M-x kargu-menu`            | Open the main Transient control panel                 |
| `M-x kargu-chat`            | Open or focus the interactive chat buffer (`*kargu*`) |
| `M-x kargu-set-mode`        | Switch mode (`ask`, `plan`, `agent`, `debug`)         |
| `M-x kargu-set-provider`    | Switch active provider                                |
| `M-x kargu-set-model`       | Select active model                                   |
| `M-x kargu-check-setup`     | Check environment, API keys, and package dependencies |
| `M-x kargu-test-connection` | Ping active provider endpoint                         |

### Plan Mode Workflow
1. Switch to `plan` mode (`M-x kargu-set-mode` -> `plan`).
2. Submit your feature or refactor prompt.
3. Kargu drafts an implementation plan in an unsaved, in-memory `*kargu-plan*` buffer.
4. Click **`[✏ View / Edit Plan]`** to adjust steps in Emacs without writing to disk.
5. Click **`[✓ Approve & Apply]`** to automatically switch to `agent` mode and execute the verified plan.

---

## Development

Wire JSON uses string-keyed hash tables for objects and vectors for arrays.
Empty objects, arrays, null and false remain distinct. Native agent records
still use alists internally; their adapter is `kargu-json-encode-record` /
`kargu-json-to-record`. New wire code must not infer objects from Lisp lists;
represent arbitrary nested arrays with vectors.

Process-filter scaling can be measured with
`emacs --batch -Q -L . -l tests/bench-process.el -f kargu-benchmark-process`.
On Emacs 30.2, three trials at 2/8/32 MiB took about 0.013/0.069/0.324 seconds
through the real filter. Appending with `position-bytes` did not show an extra
scaling penalty against appending alone in this workload, so no speculative
byte-counter optimization was introduced. These are local measurements, not
cross-platform performance guarantees.

### Native request parameters

Native requests send at most one output-limit field. Model-declared supported
parameters select an accepted alias; otherwise format/provider request policy
selects it. OpenAI's catalog entry prefers `max_completion_tokens`, consistent
with its [Chat Completions reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create).
Other compatibility formats default to `max_tokens`. An explicit token cap is
refused if known metadata offers neither field, never silently discarded.
Sampling fields are omitted when a nonempty supported-parameter list excludes
them. With unknown metadata, OpenAI conservatively omits temperature; other
compatibility providers keep the existing temperature default. Explicit metadata
can enable it. Format/provider `:request` records set these defaults without
model-name heuristics. Conditional sampling/reasoning compatibility remains
tracked in `todo.md`.

Each buffer-owned session has one protocol history and usage record. Async
delivery captures that owner; changing the current buffer cannot redirect a
reply or Stop cleanup into another conversation. Connectivity tests use an
isolated history. Queue append copies only the new message, while request and
persistence snapshots detach message lists and vectors. Scalar strings are
borrowed read-only. Provider/model/effort choices form one validated immutable
value per session; UI changes do not overwrite configured defaults. Selection
callbacks capture their session and selection identity, so obsolete lists cannot
change a replacement owner. Each session starts in `ask` and owns its mode.
Asynchronous mode preparation has an owned, cancellable completion; callbacks
cannot switch a different chat or a replacement session. Stop, replacement and
close cancel its resources. Lifecycle, duplicated token totals and application
coordination remain shared; this is not yet complete runtime isolation.

Session restore prepares a detached owner and complete transcript/footer before
publishing either. Failed rendering or publication keeps the old draft, history,
selection, usage, markers, undo and narrowing. A changed target or cancelled mode
preparation refuses publication. Notifications follow the commit. This local
transaction cannot undo arbitrary external effects of user mode hooks. Schema
version 2 stores effort as inherited, explicitly off, or an API value; legacy
records migrate in memory without rewriting storage. Unknown versions refuse.

Model metadata now has one owner in `kargu/models/store.el`, indexed by the
provider/model pair. Provider IDs normalize case; opaque model IDs retain it.
Readers default to the active provider, or take an explicit provider argument.
Short display aliases must be unique within that provider; request parameter
policy always requires the exact model ID. Local property overrides belong to
that same identity and survive catalog refreshes during the Emacs session.
They are not written to disk. Metadata inspectors retain their captured provider
when chats switch. Model APIs such as `kargu-model-set-metadata` accept an
explicit provider; `kargu-model-set-prop` uses `:provider`. Restart Emacs to rebuild
the in-memory catalog after updating from the old global cache.

A successful catalog refresh removes raw metadata for models no longer
advertised by that provider; local property overrides remain. An ID-only
catalog replaces older capability data with unknown fields. Empty catalogs
are authoritative, while failed or malformed requests retain the last valid
catalog. Model selection never appends a stale active ID or merges fallback
IDs into a known live list; delayed callbacks cannot replace a newer cache.
Use `M-x kargu-api-list-models` to explicitly refresh an empty/stale catalog.

### Prompt caching and low usage

Enable `kargu-low-usage-mode` with `setq` or the tuning menu's `l` key.
It caps tool-result context at 6,000 characters and project outlines at 200
symbols (both customizable). Tool output is archived in Emacs buffers and can
be read in ranges. The archive retains at most 32 untouched buffers and
8,000,000 characters by default (`kargu-tool-output-archive-max-buffers` and
`kargu-tool-output-archive-max-chars`). Oldest archives are evicted; oversized
results retain a prefix and the model is told exactly what was kept. User-edited
or saved-as buffers are never evicted. The selected model and output-token limit stay
unchanged; disabling the mode restores the normal context limits.

Schemas contain sorted canonical tool names; compatibility aliases still
execute but are not repeated in prompts. Stable instructions precede a changing
environment suffix. Explicit cache markers use content blocks and survive the
native Messages adapter. OpenRouter also receives a stable session header.
`M-x kargu-session-usage` shows provider-reported cache reads/writes and a hit
ratio for requests with measured input and cache-read counts. Missing counters
remain `unknown`, not zero. Actual hits depend on provider/model eligibility,
minimum prefix size and expiry; no cache-warming requests are sent.

Wire behavior follows the [OpenRouter caching guide](https://openrouter.ai/docs/guides/best-practices/prompt-caching)
and [Anthropic caching guide](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).

### Long-running shell jobs

Shell tools have no duration limit by default (`kargu-bash-timeout` is nil).
Use `M-x kargu-bash-show-process` to follow a live log and `C-c C-k` in
that log to cancel the job. The assistant can use `bash` commands `list`,
`status p1`, and `kill p1`. Output retains a bounded recent tail without
terminating the process. Stop cancels the foreground tool; background
jobs continue until explicitly cancelled. Other bounded tools keep their
normal timeouts. A positive `kargu-bash-timeout` opts into a deadline.
Bash now requires the Rust core and Agent mode. Starting either foreground or
background work from Lisp requires a callback; background startup is reported
only after the real native receipt. Cancellation is acknowledged separately
from completed process-group cleanup. Background jobs remain owned by their
original source buffer/session; closing that owner cancels and drains them.
The captured environment is explicit (at most 512 entries / 64 KiB), and its
values are withheld from the approval display. Output retention is 0..4 MiB.

Interactive `kargu-process-session-start` uses the same Rust job engine and
returns a starting handle immediately. Await its `:on-ready` callback before
sending input or EOF. Each send is bounded to 32 KiB of UTF-8; optional input
callbacks acknowledge actual delivery, without automatic replay. Idle timeouts
run in Rust. The private output buffer is released after native terminal drain
or an explicit transport/owner failure. `result` and `failure` accessors retain
the typed evidence; a local closed view is not proof of OS cleanup. Callbacks
are revoked when their original source/session is lost.

`read_file` normalizes its line window once. `from_line`/`to_line` are positive
1-based inclusive integers; `limit` alone reads the first N lines. The legacy
`offset` is a 1-based start alias, with zero also meaning the first line.
Malformed, null and conflicting bounds are rejected. Explicit windows still
obey `kargu-diff-read-max-chars`; totals remain `unknown` when counting the
unrequested tail would require more scanning.

After project context is resolved, native reads delegate target path lookup and
disk reads to an owned helper process. Input is bounded cumulatively by
`kargu-file-read-max-bytes`; decoded snapshots also respect
`kargu-file-read-max-scan-chars`. Narrow live-buffer ranges are sliced in place,
including unsaved text, without copying or splitting the whole buffer. Batch
callers retain the synchronous `kargu-file-read` compatibility entrypoint;
native tool calls use callbacks. Remote reads require a separate adapter and
currently return unavailable. The helper ignores file transformation handlers.

`workspace_grep` enforces `max_matches` across the whole search, not per
file. Both ripgrep and GNU grep use line-buffered output; Kargu stops the
producer after at most one extra captured record to detect omitted hits.
The omission notice does not invent a total count. An intentional record
limit is distinct from byte-quota or timeout failures, which still reject
the result rather than presenting it as a successful search. Rust owns execution,
record/byte budgets and process-group cleanup; there is no Elisp grep fallback.
The configured process timeout and output-byte limit are captured per search;
a nil timeout remains unlimited. Cancellation/intentional capture waits for
actual TERM/grace/KILL/reap (the default grace is five seconds). Oversized IPC
results fail explicitly instead of silently dropping hits. GNU grep's fallback
glob filtering remains basename-only; it is not identical to ripgrep's glob syntax.

Git commands use a separate `kargu-git-timeout` (nil by default), allowing
hooks and signing to finish. Stop cancels Git work owned by the agent and
prevents cancelled callbacks from launching fallback commands. An interrupted
Git write may leave a lock file; check for another Git process before recovery.
`git_status` uses Rust's owned, complete-output service and preserves its
Magit-style sections. It disables optional index writes and executable
fsmonitor config, honors host ignore settings, and supports linked worktrees.
Incomplete/malformed/non-UTF-8 status data fails explicitly; no Elisp status
engine is kept as fallback. Other Git commands are not yet migrated.
`git_branches` and `git_stashes` are read-only in all modes. Stash `apply`
requires an explicit `stash@{N}` entry from `git_stashes`; its immutable object
ID is resolved before approval, and applying never deletes the stash. `pop`
and `drop` are refused because an index may change while approval is pending.
Delete entries manually through Git/Magit after reviewing the applied result.

Git and Bash approvals capture their session, run, project, directory identity,
environment and executable search path. A delayed answer cannot start a changed
request; duplicated decisions enter the continuation only once, without replaying
tool preparation. Cancelling its task dismisses only that task's prompt.

Session restore resolves its destination by project, never by a shared buffer
name. An explicit target belonging to another project is refused; an implicit
target reuses a matching chat or gets a new unique buffer. A missing record does
not allocate a chat. Transactional restore remains tracked in `todo.md`.

Shell validation and approval are best-effort guards, not an operating-system
sandbox. Rust shell execution always requires explicit approval, even if the
legacy `kargu-permission-confirm-bash` option is nil. Command strings
can invoke scripts and interpreters whose filesystem effects cannot be inferred
by the path tokenizer. Missing variables and shell-local `PWD`/`OLDPWD` expansions
require explicit approval as well.
Remaining parser limitations are tracked in `todo.md`.

Webfetch validates numeric resolver results before pinning a connection and
repeats that check for each redirect. Numeric URLs need no DNS; missing or
unsupported `getent ahosts` falls back to the system resolver in an isolated
Emacs child process, bounded by the resolution timeout and cancelled on Stop.
The main UI thread never calls the blocking system resolver. Its conservative address policy uses the
[IANA IPv4](https://www.iana.org/assignments/iana-ipv4-special-registry/) and
[IPv6 special-purpose registries](https://www.iana.org/assignments/iana-ipv6-special-registry/);
it also excludes the whole IPv6 IETF-assignment and transition ranges rather
than allowing their individual exceptions. IPv4-mapped and well-known NAT64
addresses inherit the embedded IPv4 restrictions; the well-known NAT64 prefix
comes from [RFC 6052](https://www.rfc-editor.org/rfc/rfc6052.html). Arbitrary network-specific
translation prefixes or public proxy services are not an OS-level sandbox.

Chat sessions default to central storage under `kargu-sessions-directory`,
even if a project already contains `.kargu/sessions/`. Set
`kargu-session-storage-location` to `project` to explicitly opt into local
records; keep that directory out of version control yourself. Kargu never
changes your Git ignore rules or index. `M-x kargu-session-import-local`
copies a selected old local record to central storage, retains the source,
and refuses to overwrite an existing central record. Switch back to `central`
to restore imported records. Session storage receives an explicit project root
and does not depend on chat buffers. Records are bounded by
`kargu-session-max-file-bytes` (16 MiB by default); saves use private temporary
files and atomic rename so failed publication leaves the previous record intact.
Loading validates metadata, counters, native protocol message/tool-call shapes,
file identity, depth and size before changing a conversation. Typed multipart
content retains text and opaque attachment blocks across restoration. Restore
prepares its complete session and view before the guarded publication described
above; failed publication restores the old local editing state.

The LSP and Dape entry points load focused submodules for session access,
data collection, formatting and tool registration. HTTP request construction,
retry handling and SSE decoding are separate modules. Chat transcript insertion
and streaming parsing are independent of tool activity and run reporting.

Dape source selection and adapter discovery stay inside the selected workspace.
Connections need a concrete `:cwd` / `command-cwd` (or an owned parent); unknown
working directories and globally selected adapters from other projects are
not adopted. Startup approval captures the source file/version, project,
chat session and verified adapter/environment. Reassigned or edited sources,
changed selections and newly opened local adapters invalidate that decision;
late approval after run cancellation cannot launch anything. Verification uses
the captured source's environment without changing adapter preferences.
Kargu watch expressions are separate from Dape's global UI watch list and
belong to the captured adapter, project and chat session. Replacing an adapter
starts with an empty Kargu list. Inspection callbacks check that ownership
before continuing to another watch expression.
Source excerpts and breakpoint lists are restricted to canonical paths inside
the selected workspace. Foreign stack locations can still be shown as adapter
metadata, but do not authorize source reads or automatic remote connections.
Execution waits use connection-bearing state events, not Dape's global UI
stop/exit hooks. Context reports remain pinned to the original adapter and
state generation; a continue/stop cycle invalidates old replies even when
the same adapter is paused again. Stop releases the wait's listeners and timers.
Context reads also capture the original thread/frame before requesting data;
UI selection changes cannot mix another frame's variables with that stack.
Saved selections from an earlier execution state cannot start a fresh request.
Missing explicit frames are unavailable, not silently replaced. Navigation
checks the original selection before moving and captures its own new frame.
Inspection admits only the live paused selected thread; an explicit missing or
running selection never falls back to another thread. Only no selection may
default to a paused thread. Each inspection refreshes its stack into private
data, keeping Dape's shared stack/scope/variable cache untouched even by late
replies. Every callback rechecks the exact live thread and adapter generation.
Any thread event on that adapter invalidates old reads; unrelated adapters do
not. Watch expressions share the original prepared frame, despite UI changes.
The existing positional evaluate API also accepts `:selection` for that reuse.
Startup readiness belongs to the captured chat, project, session, mode and
source identity. Existing adapters are pinned; new launches use a unique local
token and admit only their matching root adapter, never an unrelated or child
connection. Stop also cancels readiness before an agent run starts, preserving
the draft. Timeout and all terminal paths release owned listeners and timers.
Cancellation invalidates the deferred launch continuation without killing
unrelated compilation resources. Adapter port establishment remains synchronous
and is tracked separately in `todo.md`.

Kill, disconnect and quit now close only the captured adapter and its owned
children, with asynchronous requests and a bounded forced-close deadline.
Managed connections also replace Dape's blocking shutdown callback and private
shutdown path, including protocol-triggered shutdown. No global buffer sweep or
foreign selection cleanup runs. Transport/server/stderr resources are captured
before waiting, released once, and completion follows all cleanup. Unsupported
Dape/JSONRPC ownership shapes refuse startup before creating a process. This
adapter boundary is tested with Dape 0.27.1 and Emacs 30.2; nonterminal Dape UI
event isolation and asynchronous port startup remain separate open work.

Debugger source quotes prefer the full unsaved visiting buffer, preserving its
narrowing and point. Inspection is bounded to 64 KiB on disk or 65,536 live
buffer characters. Larger sources and missing lines are unavailable, not
truncated quotes. Disk reads have a growth sentinel and bypass transformation
handlers; slow local filesystem I/O is still synchronous (see `todo.md`).

Post-edit diagnostic verification captures the source buffer, document tick,
project, server and Flymake report-function generations. Every configured
checker must report; stable or empty caches do not prove a completed check.
Stop cancels the owned polling/deadline timers without adopting late reports.
Each verification batch also owns the exact pending edit records captured at
startup. Completion or cancellation releases only those records, including
files not yet visited; intervening edits remain pending. Releasing a change
signal does not certify that its diagnostics were available or clean.
Eglot replays are additionally checked against a versioned diagnostic push;
Kargu advertises `publishDiagnostics.versionSupport` on new Eglot connections.
Reconnect existing servers to negotiate that capability. Because the
[LSP diagnostic version is optional](https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.17/language/publishDiagnostics.md),
servers omitting it remain unverified and time out rather than certifying a
clean edit. Ordinary diagnostic tools show cached observations, not freshness
certificates, and unopened files are not opened or checked implicitly.

Implementation plans have one authoritative record per source chat, capturing
its project and session. Each chat has its own in-memory review buffer. Approval
reads the full edited buffer and dispatches from the captured chat; another
active run refuses startup without consuming the decision. Old transcript
buttons cannot approve replacement plans, and closing the chat/review or changing
its project/session invalidates the artifact. Failed startup leaves a still-current
plan pending. Plans are extracted only from their own completion report, never
another chat's global history. The bounded ownership workflow has a separate
exhaustive check: `proof/run_tlc.sh --plan`.

Plan approval stays claimed while mode preparation is pending. Only actual
successful startup approves it. Stop or closing/replacing its review cancels
owned preparation; changed drafts, plan revisions, selections or owners refuse
late dispatch. Startup refusal restores the previous mode only if the plan's
own mode revision is still current. The dispatcher accepts an asynchronous
completion callback; legacy synchronous headless dispatchers remain supported.

With the required Emacs packages installed, run the offline ERT suite with:

```sh
emacs --batch -Q -L . --eval '(progn (require (quote package)) (package-initialize))' -l tests/run-tests.el
```

Tests use temporary projects and mocked provider responses. See
[`proof/README.md`](proof/README.md) for the exhaustive TLA+ checks required
when loop transitions or protocol invariants change.

## License

GPL-3.0-or-later
