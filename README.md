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
- Required packages: `plz`, `transient`, `eglot`, `dape`, `company`, `magit`
- Command-line utilities: `rg` (ripgrep) or `grep`, `curl`, `git`

### Setup

Clone the repository and add it to your Emacs `load-path`:

```elisp
(add-to-list 'load-path "/path/to/kargu")
(require 'kargu)
```

---

## Configuration

Kargu can be configured via a simple TOML configuration file (`~/.config/kargu/config.toml` or `~/.emacs.d/kargu.toml`), environment variables, or Emacs `auth-source`.

Run `M-x kargu-edit-config` to generate or edit your configuration. A commented example is in [`config.toml.example`](config.toml.example).

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

| Command | Description |
| :--- | :--- |
| `M-x kargu-menu` | Open the main Transient control panel |
| `M-x kargu-chat` | Open or focus the interactive chat buffer (`*kargu*`) |
| `M-x kargu-set-mode` | Switch mode (`ask`, `plan`, `agent`, `debug`) |
| `M-x kargu-set-provider` | Switch active provider |
| `M-x kargu-set-model` | Select active model |
| `M-x kargu-check-setup` | Check environment, API keys, and package dependencies |
| `M-x kargu-test-connection`| Ping active provider endpoint |

### Plan Mode Workflow
1. Switch to `plan` mode (`M-x kargu-set-mode` -> `plan`).
2. Submit your feature or refactor prompt.
3. Kargu drafts an implementation plan in an unsaved, in-memory `*kargu-plan*` buffer.
4. Click **`[✏ View / Edit Plan]`** to adjust steps in Emacs without writing to disk.
5. Click **`[✓ Approve & Apply]`** to automatically switch to `agent` mode and execute the verified plan.

---

## License

GPL-3.0-or-later
