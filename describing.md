# Kargu — Architecture, Operating Logic & Specification

Kargu is an advanced autonomous agentic coding assistant for GNU Emacs. It interfaces with OpenAI-compatible LLM endpoints (via `plz` asynchronous HTTP/SSE), integrates workspace intelligence from `lsp-mode` and `dape`, applies file changes through `ediff` shadow buffers, provides interactive workflow controls via `transient`, and maintains rigorous formal protocol safety verified with TLA+.

---

## 1. Core Architecture & Design Philosophy

- **Non-Blocking Asynchrony**: All network requests (HTTP POST, SSE streaming) run via `plz` child processes or timers. The Emacs UI thread is never blocked, keeping editor interaction smooth.
- **Magit-Style Modular Layout**: Entry point is `(require 'kargu)` / `M-x kargu-menu`. Submodules follow predictable path conventions (`kargu/loop/machine` → `kargu/loop/machine.el`).
- **Strict Protocol Safety**: A bidirectional protocol firewall ensures message payloads strictly conform to LLM provider requirements (OpenAI, Anthropic, Gemini, DeepSeek, OpenRouter), preventing protocol rejections.
- **Self-Healing Edit Cycle**: Tool modifications automatically trigger LSP and Flycheck diagnostics, providing automated error-correction loops within configurable round budgets.
- **Formal Verification**: The core state machine and protocol invariants are modeled in TLA+ under `proof/` and exhaustively verified via the TLC model checker.

---

## 2. Operating Modes & Tool Gating

Kargu defines four distinct operational modes (`kargu-active-mode`):

| Mode | Mutating Tools Allowed | Description |
|---|---|---|
| `ask` | ❌ No | Pure conversational query mode. Answers questions without modifying files or running commands. |
| `plan` | ❌ No | Implementation planning mode. Inspects workspace architecture and drafts plans without applying changes. |
| `debug` | ❌ No | Interactive debugging mode. Inspects stack traces, breakpoints, and runtime variables via `dape`. |
| `agent` | ✅ Yes | Full autonomous mode. Searches, reads, edits files, runs shell commands, and conducts self-healing edits. |

### Tool Visibility & Execution Gating
- Mutating tools (`edit_file`, `write_file`, `edit`, `write`, `bash`, `debug_toggle_breakpoint`, `apply_patch`, `patch`, `git_commit`, `git_stage`, `git_unstage`, `git_branch`, `git_stash`) are only advertised in the LLM tool schema and executable when `kargu-active-mode` (or `kargu-state-mode`) is `agent`.
- If an unauthorized mutating tool call is attempted in a read-only mode, `kargu-loop--gate-tool` intercepts it and returns a descriptive error message without executing the tool.
- **Mode Switching Isolation**: Mode changes via `kargu-set-mode` are blocked while an agent loop is in flight (`kargu-loop-running-p`), preventing mid-turn mode corruption.

---

## 3. LLM Protocol & Message Firewall

The protocol firewall (`kargu--validate-history` in `kargu/history.el`) sanitizes `kargu--message-history` prior to every outgoing request and immediately after run completion:

### Firewall Invariants
1. **System Prompt Head**: The first message is always `role: "system"`, refreshed with the active mode's instructions (`kargu--get-system-prompt`).
2. **No Trailing Assistant Turn**: Payloads must never end on a model turn (rejected by OpenRouter / OpenAI with 400 Bad Request). Controlled by `kargu-trailing-assistant-fix`:
   - `'strip` (protocol default): Discards trailing assistant messages.
   - `'nudge`: Appends a synthetic user `"Continue."` turn.
3. **Strict Tool Call Pairing**: Every assistant message containing `tool_calls` must be immediately followed by matching `role: "tool"` results for *all* calls. If a run is interrupted or cancelled, `kargu--flush-pending` injects synthetic tool error results.
4. **No Orphan Tool Results**: Any `role: "tool"` message lacking a matching preceding assistant call ID is dropped.
5. **Consecutive User Merging**: Consecutive `user` turns are automatically merged into a single turn separated by `\n\n`.
6. **Consecutive Assistant Merging**: Consecutive assistant text turns without tool calls are merged.
7. **Content Normalization & Reasoning Support**:
   - Models returning reasoning tokens (`reasoning_content`) without text content maintain `content: ""` to satisfy provider schemas requiring string content.
   - Null, `:json-null`, or empty string `content` is stripped when tool calls are present (satisfying providers that reject empty text blocks alongside tool calls).
8. **Empty Object Schema Serialization**: Parameterless tools (e.g. `lsp_project_skeleton`, `debug_get_context`) serialize `"parameters": {"type": "object", "properties": {}}` using `:json-empty-object` in `kargu/json.el` and `kargu--sanitize-tool-parameters` in `kargu/api/tools.el`.

---

## 4. Autonomous Agent Loop (`kargu/loop/`)

The agent loop executes an asynchronous state machine:

```
[IDLE]
  │
  ▼  (kargu-loop-send)
[REQUEST] ◄─────────────────────────────────────────────┐
  │                                                     │
  ├───────────────┬─────────────────┐                   │
  │ (compact req) │ (max iter)      │ (send)            │
  ▼               ▼                 ▼                   │
[COMPACT_WAIT]  [PAUSE]           [WAIT_MODEL]          │
  │               │ (ui continue)   │                   │
  │ (summary)     └───────────────► ├─► [DONE: answer]  │
  └───────────────────────────────► ├─► [ERROR: api]    │
                                    ├─► [REQUEST: retry/length/empty]
                                    │                   │
                                    ▼ (tool_calls)      │
                                  [EXEC_TOOLS]          │
                                    │                   │
                                    ├─► [VERIFY_FILES] ─┤
                                    │      (LSP heal)   │
                                    └───────────────────┘
```

### Event Classification & Dispatch (`kargu/loop/machine.el`)

#### Request Classification
- `stale`: Run cancelled or replaced; request ignored.
- `busy`: Compaction in progress; request paused.
- `compact`: History length exceeds threshold and compaction budget available; triggers compaction turn.
- `send`: Normal model turn dispatch. Iterations counter incremented; on `kargu-max-iterations`, tools are hidden (`:no-tools t`) and a conclusion nudge is sent.

#### Response Classification
- `stale`: Inactive generation; ignored.
- `overflow`: Context window exceeded; triggers compaction if allowed, else `:error`.
- `error`: Upstream failure. If retryable (502, 503, 429, overload), retried with exponential backoff up to `kargu-loop-upstream-retries` without polluting history; otherwise ends in `:error`.
- `tools`: Queues tool calls for sequential execution.
- `length`: Truncated by `max_tokens`; injects a `"Continue."` nudge (max 1 continue per run).
- `answer`: Final assistant response; ends run in `:done`.
- `empty`: Empty response with no tools; re-prompts with system notice up to `kargu-loop-empty-retries`, then finishes `:done`.

---

## 5. Tool Execution & Safety Architecture

### Sequential Queue & Doom-Loop Detection (`kargu/loop/tools.el`)
- Tool calls returned in a single assistant turn are queued and executed sequentially.
- **Doom-Loop Detection**: Every tool call generates a signature `name \0 args`. If three consecutive identical signatures occur, the run is immediately aborted with `:error`, and synthetic error results are written for the current and all remaining queued tools.

### Diff Staging & Ediff Review (`kargu/tools/diff.el`)
- Mutating file tools (`edit_file`, `write_file`) never overwrite disk directly without staging.
- Changes are staged in shadow buffers:
  - **Buffer A**: Original file content from disk.
  - **Buffer B**: Proposed new content from the model.
  - **Ediff Interaction**: Pressing `b` accepts the model's proposal; pressing `a` restores/keeps original code.
- Review modes (`kargu-diff-review-mode`):
  - `'auto`: Changes applied immediately and auto-saved.
  - `'blocking`: Starts interactive Ediff in a recursive edit.
  - `'async`: Opens Ediff non-blockingly.

### Diagnostic Self-Healing (`kargu/loop/heal.el`)
- After file edits, the loop enters `VERIFY_FILES` and waits for LSP/Flycheck diagnostics to settle (`kargu-lsp-wait-diagnostics`).
- Error count evaluation:
  - If diagnostics contain errors, the `:healing` round counter increments up to `kargu-max-healing-steps` (default: 3). A `SELF-HEALING (round N of M)` block with diagnostic details is appended directly to the tool result.
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
- `proof/KarguLoop.tla`: Models loop states (`IDLE`, `REQUEST`, `WAIT_MODEL`, `EXEC_TOOLS`, `VERIFY_FILES`, `COMPACT_WAIT`, `PAUSE`, `DONE`, `ERROR`, `STOPPED`), parallel tool execution, doom loops, self-healing, compaction, interactive continuation, and cancellations.
- `proof/MC.tla` & `proof/MC.cfg`: TLC model-checking harness.
- `proof/run_tlc.sh`: Execution script verifying all safety invariants across 26,000+ states with zero errors.

---

## 9. File & Module Structure

```
kargu/
├── kargu.el               # Package header, load-path setup, require ordering
├── config.toml.example    # Example TOML configuration (provider keys, models)
├── kargu/
│   ├── core.el            # Slim core: alist helpers, mode state, notify, OS/shell
│   ├── core/
│   │   ├── custom.el      # All defcustom declarations (API key, model, temperature…)
│   │   ├── log.el         # Logging engine: kargu-log, wire-log, kargu-show-log
│   │   └── session.el     # Session state plist, usage counters, session-reset
│   ├── constants.el       # Bridge → kargu/contract/constants (backward compat)
│   ├── contract.el        # Ingress/egress contract validation facade
│   ├── contract/
│   │   ├── assert.el      # kargu-contract-assert, kargu-contract-validate
│   │   ├── constants.el   # Mode enums, message roles, buffer names, HTTP codes
│   │   ├── result.el      # Railway-Oriented Programming: kargu-ok, kargu-err
│   │   └── types.el       # Type predicates: kargu-contract-message-p, -history-p…
│   ├── state.el           # Centralized state store facade
│   ├── state/
│   │   ├── store.el       # kargu--state-store plist, kargu-state-get/set/update
│   │   ├── selectors.el   # Pure read selectors: kargu-state-mode, -status, -busy-p
│   │   ├── transitions.el # Validated lifecycle mutations: kargu-state-set-mode…
│   │   └── hooks.el       # Event bus: kargu-state-change-hook, subscribe/unsubscribe
│   ├── permission.el      # Project sandboxing facade
│   ├── permission/
│   │   ├── guards.el      # Project root resolution, within-project assertion
│   │   ├── bash.el        # Command tokenization and escape validation
│   │   └── policy.el      # Approval buttons UI (Approve / Reject)
│   ├── config.el          # TOML config, provider & API key resolution facade
│   ├── config/
│   │   ├── toml.el        # Pure Elisp TOML parser
│   │   ├── key.el         # Multi-tier API key & endpoint resolution
│   │   └── schema.el      # Config caching, setup check, kargu-edit-config
│   ├── providers.el       # Provider registry facade
│   ├── providers/         # Individual provider implementations & catalog
│   │   ├── catalog.el     # Dynamic provider/model definitions & metadata
│   │   ├── registry.el    # Dynamic runtime registration
│   │   └── *.el           # One .el per provider (openrouter.el, anthropic.el, …)
│   ├── json.el            # JSON encoder/decoder, empty object support
│   ├── fs.el              # Bounded project tree traversal, directory ignore filters
│   ├── result.el          # Bridge → kargu/contract/result (backward compat)
│   ├── prompt.el          # System prompt builder, model-specific prompt templates
│   ├── prompt/            # Model-specific system prompt text files
│   ├── plan.el            # Plan mode facade
│   ├── plan/              # Plan sub-modules (buffer.el, dispatch.el)
│   ├── ui.el              # Transient control menus facade
│   ├── ui/
│   │   ├── transient.el   # kargu-menu transient dispatch
│   │   └── notify.el      # kargu-notify UI notification
│   │
│   ├── api.el             # High-level API dispatch facade
│   ├── api/
│   │   ├── catalog.el     # Live /models catalog fetcher & metadata cache
│   │   ├── circuit.el     # Circuit breaker (3-state: closed/open/half-open)
│   │   ├── client.el      # Payload builder, provider-specific request shaping
│   │   ├── http.el        # Async plz HTTP client with exponential backoff
│   │   ├── response.el    # Response accessors, reasoning extraction
│   │   ├── select.el      # Model selection UI (company / transient)
│   │   ├── stream.el      # SSE chunk parser and stream dispatcher
│   │   └── tools.el       # Tool registry, schema builder, parameter sanitizer
│   │
│   ├── history.el         # Message history storage, protocol firewall facade
│   ├── history-compact.el # Bridge → kargu/history/compact (backward compat)
│   ├── history/
│   │   ├── protocol.el    # History storage: kargu--message-history, -add, -reset
│   │   ├── repair.el      # Protocol firewall: kargu--validate-history
│   │   └── compact.el     # Compaction: tail extraction, ACK generation
│   │
│   ├── loop.el            # Agent run lifecycle facade
│   ├── loop/
│   │   ├── machine.el     # Request/response event classification and dispatch
│   │   ├── ui.el          # Interactive UI: turn-limit prompt, continue/stop buttons
│   │   ├── tools.el       # Sequential tool queue, doom-loop detection, batch dedup
│   │   ├── heal.el        # Post-edit LSP diagnostics and self-healing rounds
│   │   └── compact.el     # Compaction turn handling and single-compaction cap
│   │
│   ├── chat.el            # Chat sidebar buffer management and major mode
│   ├── chat/
│   │   ├── attach.el      # Mention parsing (@[file]), synthetic read attachments
│   │   ├── complete.el    # Company completion backend for files and LSP symbols
│   │   ├── header.el      # Chat buffer header line with mode buttons
│   │   ├── prompt.el      # Interactive prompt input area and keybindings
│   │   ├── render.el      # Markdown fontification, streaming deltas, thought blocks
│   │   └── tune.el        # Model parameter tuning UI (temperature, reasoning effort)
│   │
│   └── tools/
│       ├── bash.el        # Shell execution tool with approval gate
│       ├── dape.el        # Live debugging context, breakpoints, eval
│       ├── diff.el        # Shadow buffers, ediff review, rollback facade
│       ├── diff/
│       │   ├── stage.el   # Shadow buffer creation and staging logic
│       │   ├── review.el  # Ediff interaction (blocking/async/auto modes)
│       │   └── track.el   # Changed-file tracking: kargu-diff-changed-files
│       ├── git.el         # Git operations: stage, commit, branch, stash
│       ├── lsp.el         # LSP skeleton, diagnostics, xref, symbol lookup
│       ├── search.el      # Ripgrep workspace search and glob file matching
│       ├── skill.el       # Agent skill loader and custom instructions
│       ├── toolchain.el   # Project toolchain and build system detector
│       └── webfetch.el    # Web page fetcher via curl
│
└── proof/
    ├── KarguContract.tla  # Roles, modes, message schema, contract predicates
    ├── KarguProtocol.tla  # Message firewall, history validation, compaction
    ├── KarguCircuit.tla   # Circuit breaker state machine
    ├── KarguTools.tla     # Tool gating, doom-loop detection, batch dedup
    ├── KarguState.tla     # Centralized state store & lifecycle transitions
    ├── KarguLoop.tla      # Full agent loop state machine (all states & safety)
    ├── KarguLoop.cfg      # Default TLC configuration
    ├── MC.tla             # Model checking wrapper
    ├── MC.cfg             # Bounded parameters & invariants for TLC
    ├── README.md          # Formal proof documentation
    └── run_tlc.sh         # Shell script to run TLC model checker
```
