# Kargu
> [!WARNING]
> **Active Development**: Kargu is actively being developed and evolving rapidly. Errors or unexpected behavior may occur. Please feel free to [report issues](https://github.com/ehanhalici/kargu/issues) or submit feedback!

**Kargu** is an agentic AI coding assistant and pair-programmer for GNU Emacs.

Rather than running heavy external daemons or separate browser windows, Kargu turns Emacs itself into the agent runtime. It seamlessly integrates with the packages and workflows you already use every day—giving AI models structured, token-efficient access to your codebase while keeping you in full control.



---

## Key Highlights

- **Agentic AI & Autonomous Workflows**: Models can autonomously explore workspaces, inspect symbols, search across codebases, propose edits, and execute terminal commands through a secure loop.
- **Deep Emacs Native Integration**:
  - **LSP (`lsp-mode`)**: Structural project outlines, diagnostics, definitions, and symbol resolution without dumping raw files into context.
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
- **Human-in-the-Loop Safety**: Interactive UI approval buttons for destructive operations and bash commands, complete with fallback confirmations.

---

## Installation & Requirements

### Prerequisites
- GNU Emacs 29.1 or newer
- Required packages: `plz`, `transient`,`lsp-mode`, `dape`, `company`, `magit`
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

Run `M-x kargu-edit-config` to generate or edit your configuration:

```toml
# Local kargu credentials.  Copy this file to one of:
#   ~/.config/kargu/config.toml
#   ~/.emacs.d/kargu.toml
# Do not commit the copy; it is per-machine.

provider = "opencode"
model = "nemotron-3-ultra-free"



[providers.opencode]
apikey = "[ENCRYPTION_KEY]"

# --- DeepSeek (URL defaults to https://api.deepseek.com/v1) ---
[providers.deepseek]
apikey = "sk-..."

# --- Groq (URL defaults to https://api.groq.com/openai/v1) ---
[providers.groq]
apikey = "gsk_..."

# --- OpenAI (URL defaults to https://api.openai.com/v1) ---
[providers.openai]
apikey = "sk-..."

# --- Anthropic (URL defaults to https://api.anthropic.com/v1) ---
[providers.anthropic]
apikey = "sk-ant-..."

# --- Together AI (URL defaults to https://api.together.xyz/v1) ---
[providers.togetherai]
apikey = "..."

# --- Ollama (local runner, no key required) ---
[providers.ollama]
apikey = ""
# api defaults to "http://localhost:11434/v1"
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
