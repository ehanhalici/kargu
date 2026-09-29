# Kargu — Architecture, Operating Logic & Specification

Kargu is an advanced autonomous agentic coding assistant for GNU Emacs. It interfaces with OpenAI-compatible LLM endpoints (via `plz` asynchronous HTTP/SSE), integrates workspace intelligence from `eglot` and `dape`, applies file changes through `ediff` shadow buffers, provides interactive workflow controls via `transient`, and maintains rigorous formal protocol safety verified with TLA+.

---

## 1. Core Architecture & Design Philosophy

- **Non-Blocking Asynchrony**: All network requests (HTTP POST, SSE streaming) run via `plz` child processes or timers. The Emacs UI thread is never blocked, keeping editor interaction smooth.
- **Magit-Style Modular Layout**: Entry point is `(require 'kargu)` / `M-x kargu-menu`. Submodules follow predictable path conventions (`kargu/loop/machine` → `kargu/loop/machine.el`).
- **Strict Protocol Safety**: A bidirectional protocol firewall ensures message payloads strictly conform to LLM provider requirements (OpenAI, Anthropic, Gemini, DeepSeek, OpenRouter), preventing protocol rejections.
- **Self-Healing Edit Cycle**: Tool modifications automatically trigger LSP and Flymake diagnostics, providing automated error-correction loops within configurable round budgets.
- **Formal Verification**: The core state machine and protocol invariants are modeled in TLA+ under `proof/` and exhaustively verified via the TLC model checker.

---

## 2. Operating Modes & Tool Gating

Kargu defines four distinct operational modes. The mode lives only in the state store (`kargu-state-mode`):

| Mode | Mutating Tools Allowed | Description |
|---|---|---|
| `ask` | ❌ No | Pure conversational query mode. Answers questions without modifying files or running commands. |
| `plan` | ❌ No | Implementation planning mode. Inspects workspace architecture and drafts plans without applying changes. |
| `debug` | ❌ No | Interactive debugging mode. Inspects stack traces, breakpoints, and runtime variables via `dape`. |
| `agent` | ✅ Yes | Full autonomous mode. Searches, reads, edits files, runs shell commands, and conducts self-healing edits. |

### Tool Visibility & Execution Gating
- Mutating tools (`edit_file`, `write_file`, `edit`, `write`, `bash`, `debug_toggle_breakpoint`, `apply_patch`, `patch`, `git_commit`, `git_stage`, `git_unstage`, `git_branch`, `git_stash`) are only advertised in the LLM tool schema and executable when `kargu-state-mode` is `agent`. Whether tools are used at all is one decision, `kargu-tools-enabled-p`: the API metadata must not disable them, the provider must not have refused them in this session, and the run must not have switched them off (compaction).
- If an unauthorized mutating tool call is attempted in a read-only mode, `kargu-loop--gate-tool` intercepts it and returns a descriptive error message without executing the tool.
- **Mode Switching Isolation**: Mode changes via `kargu-set-mode` are blocked while an agent loop is in flight (`kargu-loop-running-p`), preventing mid-turn mode corruption.

---

## 3. LLM Protocol & Message Firewall

The protocol firewall (`kargu--validate-history` in `kargu/history/repair.el`) sanitizes `kargu--message-history` prior to every outgoing request and immediately after run completion:

### Firewall Invariants
1. **System Prompt Head**: The first message is always `role: "system"`. An unchanged head is kept byte for byte (provider prompt cache); a changed mode, model, tool support or compaction overlay rebuilds it (`kargu-prompt-system-key`). Every other system message is dropped.
2. **No Trailing Assistant Turn**: Payloads must never end on a model turn (rejected by OpenRouter / OpenAI with 400 Bad Request). Controlled by `kargu-trailing-assistant-fix`:
   - `'strip` (protocol default): Discards trailing assistant messages.
   - `'nudge`: Appends a synthetic user `"Continue."` turn.
3. **Strict Tool Call Pairing**: Every assistant message containing `tool_calls` must be immediately followed by matching `role: "tool"` results for *all* calls, in call order. When the next turn arrives, a run is interrupted or a run finishes, `kargu--flush-pending` injects synthetic error results for the calls still open.
4. **No Orphan Tool Results**: Any `role: "tool"` message lacking a matching preceding assistant call ID is dropped.
5. **Consecutive User Merging**: Consecutive `user` turns are automatically merged into a single turn separated by `\n\n`.
6. **Consecutive Assistant Merging**: Consecutive assistant text turns are merged, and a text turn is folded into the assistant turn with calls that follows it.

Repair order: head system message, one forward scan (drop orphans, flush open calls), merges, then the trailing-assistant fix. A trailing assistant turn with calls was answered by the flush, so it is not stripped. A finished run and a compaction keep a trailing answer; only the send path strips it.
7. **Content Normalization & Reasoning Support**:
   - Models returning reasoning tokens (`reasoning_content`) without text content maintain `content: ""` to satisfy provider schemas requiring string content.
   - Null, `:json-null`, or empty string `content` is stripped when tool calls are present (satisfying providers that reject empty text blocks alongside tool calls).
8. **Empty Object Schema Serialization**: Parameterless tools (e.g. `lsp_project_skeleton`, `debug_get_context`) serialize `"parameters": {"type": "object", "properties": {}}` using `:json-empty-object` in `kargu/json.el` and `kargu--sanitize-tool-parameters` in `kargu/api/tools.el`. Tool arguments that are not a JSON object never reach an executor: the model receives `ERROR: the arguments of tool X are not a valid JSON object`.

---

## 4. Autonomous Agent Loop (`kargu/loop/`)

The agent loop executes an asynchronous state machine. It never blocks: three states wait for the user and are answered by callback.

```
[IDLE]
  │
  ▼  (kargu-loop-send)
[REQUEST] ◄──────────────────────────────────────────────────┐
  │                                                          │
  ├──────────────┬───────────────┬───────────────┐           │
  │ (compact)    │ (turn cap)    │ (send)        │ (breaker  │
  ▼              ▼               ▼                open)      │
[COMPACT_WAIT] [PAUSE]         [WAIT_MODEL]        │         │
  │ ok ─► REQUEST  │ continue ─► REQUEST │           ▼         │
  │ fail ─► ERROR  │ stop ─► LIMIT       ├─► [DONE: answer]    │
                                         ├─► [REQUEST: length / empty / upstream retry / tools off]
                                         ├─► [COMPACT_WAIT: overflow]
                                         ├─► [ERROR: tools refused in agent mode]
                                         ├─► [RECOVER: failure] ─ retry ─► REQUEST
                                         │                      └ stop ──► ERROR
                                         ▼ (tool_calls)
                                       [EXEC_TOOLS] ─► [DOOM_WAIT] ─ approve ─► run the call
                                         │                         └ stop ────► ERROR
                                         ├─► [VERIFY_FILES] ─► REQUEST / EXEC_TOOLS
                                         └─► REQUEST
(kargu-loop-stop ends any live state in STOPPED.)
```

### Event Classification & Dispatch (`kargu/loop/machine.el`)

Both paths are `classify -> alist lookup`. Adding an event is one classifier arm and one table row.

#### Request Classification
- `stale`: Run cancelled or replaced; request ignored.
- `busy`: Compaction in progress; request ignored.
- `compact`: History is over the threshold and the run has its one compaction left; starts a tools-off compaction turn that counts as an iteration.
- `send`: Normal model turn. At the turn cap the run goes to `PAUSE` and asks the user (`kargu-loop--prompt-continue`); `Continue` raises the cap by one batch (`kargu-max-iterations`), `Stop` ends the run in `:limit`.

#### Response Classification
The classifier tries the events in this order:
- `stale`: Inactive run; ignored.
- `overflow`: Context window exceeded; compacts if the run may, else asks the user (`RECOVER`).
- `tools-unsupported`: The provider refused tool use. The refusal is remembered for this session (`kargu-model-mark-tools-refused`). Agent mode ends in `:error`; other modes retry without tools.
- `upstream-retry`: A retryable failure (`kargu-http-retry-statuses`) with retries left. Retried with backoff up to `kargu-loop-upstream-retries`; if the circuit breaker is open the user decides instead.
- `error`: Any other failure. The user chooses to retry (the breaker is reset) or stop.
- `content-filter`: The provider blocked the reply. The user decides.
- `tools`: Queues tool calls for sequential execution.
- `length`: Truncated by `max_tokens`; injects a `"Continue."` nudge (one per run, only below the turn cap).
- `answer`: Final assistant response; ends run in `:done`.
- `empty`: Empty response with no tools; re-prompts up to `kargu-loop-empty-retries`, then finishes `:done`.

---

## 5. Tool Execution & Safety Architecture

### Sequential Queue & Doom-Loop Detection (`kargu/loop/tools.el`)
- Tool calls returned in a single assistant turn are queued and executed sequentially.
- **Doom-Loop Detection**: Every tool call generates a signature `name \0 args`. On the third identical signature in a row the run waits in `DOOM_WAIT` and asks the user. Approving clears the signatures and runs the call (three more identical calls are allowed); stopping writes synthetic error results for the current and all remaining queued tools and ends the run in `:error`.
- **Turn cache**: Within one assistant turn a repeated cacheable call reuses the first result.

### Diff Staging & Ediff Review (`kargu/tools/diff.el`)
- Mutating file tools (`edit_file`, `write_file`, `apply_patch`) go through the staging layer.
- Changes are staged in shadow buffers:
  - **Buffer A**: Original file content from disk.
  - **Buffer B**: Proposed new content from the model.
  - **Ediff Interaction**: Pressing `b` accepts the model's proposal; pressing `a` restores/keeps original code.
- Review modes (`kargu-diff-review-mode`):
  - `'auto` (default): Changes are applied immediately, saved, and shown; each write leaves a rollback snapshot (`kargu-diff-rollback`).
  - `'blocking`: Opens Ediff for hunk-by-hunk approval; nothing is saved before it; the tool result arrives when the human quits Ediff (Emacs never waits).
  - `'async`: The tool returns a `STAGED` result at once; the final outcome arrives when Ediff is quit.
- `apply_patch` is all-or-nothing: every operation is planned against the current text first, and nothing is written unless all of them apply. `*** Delete File` really deletes (in `auto` mode only) and leaves a rollback snapshot; `*** Add File` refuses an existing file.
- Dangerous shell commands and paths outside the project ask for approval in every review mode.

### Diagnostic Self-Healing (`kargu/loop/heal.el`)
- After file edits, the loop enters `VERIFY_FILES` and waits for LSP/Flymake diagnostics to settle (`kargu-lsp-wait-diagnostics`).
- Error count evaluation:
  - If diagnostics contain errors, the `:healing` round counter increments; verification runs only while rounds remain (`kargu-max-healing-steps`, default 3). A `SELF-HEALING (round N of M)` block with diagnostic details is appended directly to the tool result.
  - If errors are 0, a clean verification confirmation is appended.
  - When the healing budget is spent, files are consumed without auto-verification and the model is instructed to verify manually.

---

## 6. Context Compaction & Tail Retention (`kargu/history/compact.el`)

When history character cost exceeds the compaction threshold (calculated dynamically by `kargu-history-compact-threshold` as 70% of the active model's context window, or falling back to `kargu-history-compact-chars`), or upon upstream context overflow:
1. A tools-off compaction turn is initiated (`:no-tools t`, max 1 per run).
2. `kargu-history-compact-tail` extracts the suffix of the last `kargu-history-compact-keep` messages:
   - System prompts and previous compaction notices are discarded.
   - The tail walks forward to begin on a `user` turn (or skips leading orphan tool calls if no user turn exists).
3. The model summarizes prior work using `kargu-prompt-compaction-system` and `kargu-prompt-compaction-user`.
4. `kargu-history-apply-compaction` reconstructs history:
   - Refreshed system prompt.
   - `user`: `COMPACTION_ACK: Prior work summary:\n<summary>`.
   - `assistant`: `"Acknowledged. Continuing from the summary."`.
   - Bridging `user` turn (`"Please proceed with the task."`) if the preserved tail begins with an assistant message.
   - Preserved tail messages.
5. The protocol firewall validates the resulting history before resuming work.

---

## 7. Chat Interface & Context Attachments (`kargu/chat/`)

- **Sidebar Interface (`*kargu-chat*`)**: Header with model indicator, provider status, and interactive mode buttons (`[ask]`, `[plan]`, `[debug]`, `[agent]`).
- **Real-Time Streaming (`kargu/chat/render.el`)**: Streams assistant text deltas and collapsible thought blocks (`<thought>...</thought>`). Multi-turn tool runs dynamically reset stream preamble markers to prevent rendering lockouts.
- **Mention Cleaning (`kargu-chat--clean-at-token`)**: Robust mention extractor cleans `@` tokens:
  - Strips outer brackets (`@[...]`, `@{...}`, `(<...>)`),
  - Strips quotes (`"..."`, `'...'`, `` `...` ``),
  - Strips sentence-ending punctuation (`,`, `:`, `;`, `)`, `]`, `.`),
  - Supports symbol-level anchors via `@file::symbol` or `@[file::symbol]`,
  - Preserves internal file paths and extension dots (e.g. `@[tanim.md]` → `tanim.md`).
- **Context Attachments (`kargu/chat/attach.el`)**: Resolves mentions to files or LSP symbols and synthetically prepends file contents (bounded by `kargu-chat-attach-max-lines`) to the user prompt.

---

## 8. Formal Verification with TLA+ (`proof/`)

Kargu's protocol invariants and agent loop state machine are formally specified in TLA+ and verified using the TLC model checker:

- `proof/KarguProtocol.tla`: Models message records, role invariants, tool pairing, and the exact `kargu--validate-history` repair algorithm.
- `proof/KarguLoop.tla`: Models every loop state (`IDLE`, `REQUEST`, `WAIT_MODEL`, `EXEC_TOOLS`, `DOOM_WAIT`, `VERIFY_FILES`, `COMPACT_WAIT`, `PAUSE`, `RECOVER`, `DONE`, `LIMIT`, `ERROR`, `STOPPED`) and one action per handler of the code: doom approval, healing budget, compaction and its failure, the turn cap and `Continue`, error recovery, tool refusal, circuit breaker and cancellation.
- `proof/MC.tla` & `proof/MC.cfg`: TLC model-checking harness, with deadlock checking on.
- `proof/run_tlc.sh`: Exhaustive scan by default (the proof); `--simulate` is a random smoke test and proves nothing. Exit status 0 only when TLC finished without error. See `proof/README.md` for the numbers of the last run.

---

## 9. File & Module Structure

```
kargu/
├── kargu.el               # Package header, load-path setup, require ordering
├── config.toml.example    # Example TOML configuration (provider keys, models)
├── skills.md              # The laws, contracts and coding style
├── shell.nix              # TLC for proof/run_tlc.sh
├── kargu/
│   ├── core.el            # Alist helpers, notify, OS/shell, kargu-cap-text
│   ├── core/
│   │   ├── custom.el      # All defcustom declarations
│   │   ├── log.el         # Logging engine: kargu-log, wire-log, kargu-show-log
│   │   └── session.el     # Session state plist, usage counters, session-reset
│   ├── contract.el        # Ingress/egress contract validation facade
│   ├── contract/
│   │   ├── assert.el      # kargu-contract-assert, kargu-contract-validate
│   │   ├── constants.el   # Mode enums, message roles, buffer names, HTTP codes
│   │   ├── result.el      # Railway-Oriented Programming: kargu-ok, kargu-err
│   │   └── types.el       # Type predicates: kargu-contract-message-p, -history-p…
│   ├── state.el           # Centralized state store facade
│   ├── state/
│   │   ├── store.el       # State plist, kargu-state-get/set/update
│   │   ├── selectors.el   # Pure read selectors: kargu-state-mode, -status, -busy-p
│   │   ├── transitions.el # Validated lifecycle mutations: kargu-state-set-mode…
│   │   └── hooks.el       # Event bus: kargu-state-change-hook, subscribe/unsubscribe
│   ├── permission.el      # Project sandboxing facade
│   ├── permission/
│   │   ├── guards.el      # The one project root, kargu-permission-resolve
│   │   ├── bash.el        # Command tokenization and escape validation
│   │   └── policy.el      # Approval through kargu-ui-confirm (Approve / Reject)
│   ├── config.el          # TOML config, provider & API key resolution facade
│   ├── config/
│   │   ├── toml.el        # Pure Elisp TOML parser
│   │   ├── key.el         # API key order: override, TOML (${VAR}), keyless "", env, auth-source
│   │   └── schema.el      # Config caching, setup check, kargu-edit-config
│   ├── providers.el       # Provider registry facade
│   ├── providers/
│   │   ├── catalog.el     # Built-in catalog: endpoints and per-format behavior
│   │   ├── registry.el    # Runtime registration and format-field accessors
│   │   └── params.el      # Parameter schemas; :params-menu / :params-post hooks
│   ├── languages.el       # Language profile facade
│   ├── languages/
│   │   ├── core.el        # Profile record (extensions, LSP, toolchain, guidance)
│   │   └── *.el           # rust golang python c cpp java haskell ocaml elisp javascript typescript
│   ├── json.el            # JSON encoder/decoder, empty object support
│   ├── fs.el              # Bounded project tree walk, directory ignore filters
│   ├── prompt.el          # System prompt builder
│   ├── prompt/            # Base system prompt text
│   ├── plan.el            # Plan mode facade
│   ├── plan/              # buffer.el, dispatch.el (single-shot approval buttons)
│   ├── ui.el              # Transient control menus facade
│   ├── ui/
│   │   ├── confirm.el     # Callback-style approval prompts (kargu-ui-confirm)
│   │   ├── transient.el   # kargu-menu transient dispatch
│   │   └── notify.el      # kargu-notify UI notification
│   │
│   ├── api.el             # High-level API facade
│   ├── api/
│   │   ├── catalog.el     # Live /models catalog, metadata cache, tool-refusal memory
│   │   ├── circuit.el     # Circuit breaker (closed / open / half-open probe)
│   │   ├── client.el      # kargu-api-send, cancel, connection test
│   │   ├── http.el        # Async plz client, payload build, retry with backoff
│   │   ├── response.el    # Response accessors, reasoning extraction
│   │   ├── select.el      # Model selection (company / transient)
│   │   ├── stream.el      # SSE chunk parser and tool-call fragments
│   │   ├── tools.el       # Tool registry, schema builder, argument check
│   │   └── wire.el        # Wire-level logging
│   │
│   ├── history.el         # Message history and protocol firewall facade
│   ├── history/
│   │   ├── protocol.el    # kargu--message-history, -add, -reset
│   │   ├── repair.el      # Protocol firewall: kargu--validate-history
│   │   └── compact.el     # Compaction: threshold, tail, apply
│   │
│   ├── loop.el            # Run lifecycle, kargu-tools-enabled-p, stop, finish
│   ├── loop/
│   │   ├── machine.el     # Request/response classifiers and handler tables
│   │   ├── ui.el          # Turn-limit prompt and continue decision
│   │   ├── tools.el       # Tool queue, doom-loop approval, turn cache
│   │   ├── heal.el        # Post-edit diagnostics and self-healing rounds
│   │   └── compact.el     # Compaction turn (one per run)
│   │
│   ├── chat.el            # Chat buffer and major mode
│   ├── chat/
│   │   ├── attach.el      # @mention parsing and read attachments
│   │   ├── complete.el    # Company backend for files and LSP symbols
│   │   ├── header.el      # Header line with mode buttons
│   │   ├── prompt.el      # Prompt input area, submit, preflight
│   │   ├── render.el      # Fontification, streaming deltas, thought blocks
│   │   ├── session.el     # Session save / load / list
│   │   ├── tune.el        # Effort and parameter tuning
│   │   └── tune-params.el # Per-format parameter menus
│   │
│   └── tools/
│       ├── process.el     # The one timed make-process helper (callback style)
│       ├── bash.el        # Shell tool with approval and async output
│       ├── dape.el        # Debugging context, breakpoints, eval
│       ├── deps.el        # Mandatory dependency and language-server check
│       ├── diff.el        # Edit, write and atomic apply_patch, rollback
│       ├── diff/          # stage.el, review.el, track.el
│       ├── git.el         # Git tools (callback style)
│       ├── lsp.el         # Skeleton, diagnostics, xref, symbols
│       ├── search.el      # ripgrep / grep / fd search (callback style)
│       ├── skill.el       # SKILL.md discovery and load
│       ├── toolchain.el   # Register API; strategies come from language profiles
│       └── webfetch.el    # curl fetch; every redirect hop is checked
│
├── tests/                 # ERT suites; `run-tests.el` loads them all
│   ├── test-helpers.el    # Scratch root, temp git repo, state isolation
│   ├── test-laws.el       # One named test per contract (a)-(f) of skills.md
│   └── test-*.el          # One suite per module or feature
│
└── proof/
    ├── KarguContract.tla  # Roles, modes, message schema, contract predicates
    ├── KarguProtocol.tla  # Protocol wall (repair order), compaction
    ├── KarguCircuit.tla   # Circuit breaker, response classification events
    ├── KarguTools.tla     # Mode gate, doom-loop signatures
    ├── KarguState.tla     # State store, statuses, busy and run-live classes
    ├── KarguLoop.tla      # The loop state machine and its safety invariants
    ├── MC.tla / MC.cfg    # TLC harness: parameters, invariants, deadlock check
    ├── README.md          # Formal proof documentation
    └── run_tlc.sh         # Exhaustive scan (default) or --simulate
```
