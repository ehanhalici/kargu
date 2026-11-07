---
name: native-tools
description: Runbooks, contracts, and invariants for native workspace tools in Kargu, including file search (find_files), listing (GNU ls), grep, Git queries, and persistent child process (bash/job) management. Use when designing, reviewing, or testing tool execution.
---

# Native Tools & Execution Architecture

This skill governs the execution lifecycle, process sandboxing, and output bounding for all workspace inspection and execution tools in Kargu.

## 1. Tool Families & Invariants

### 1.1 Filesystem & Search Tools
- **`find_files` & `list_files`**: Use native Rust traversal and the GNU `ls` adapter. Path traversal outside the workspace root is rejected before I/O.
- **`workspace_grep`**: Powered by `ripgrep` / GNU `grep` adapters with strict character/byte bounds on match capture.

### 1.2 Process Management & Bash (`bash`, `job`)
- **Process Group (PGID) Isolation**: Every command runs under an isolated process group (`setpgid(0)`). On cancellation or timeout, the entire process tree is terminated (`SIGTERM -> grace period -> SIGKILL`).
- **Bounded Framing & Output Streaming**: Standard I/O pipes enforce explicit buffer limits to prevent memory exhaustion (OOM).

### 1.3 Git Query & Inspection Tools
- **Read-Only Inspection**: `git_diff`, `git_log`, `git_blame`, `git_branches`, and `git_stashes` execute through the native supervisor.
- **Isolation Proofs**: Configuration filters, pager programs, and signing hooks are disabled to ensure deterministic execution.

---

## 2. Technical Specifications & Proofs

For complete cutover proofs and detailed architectural implementations, consult:
- [14_EXECUTION_FOUNDATIONS.md](references/14_EXECUTION_FOUNDATIONS.md): Foundations of native execution
- [15_NATIVE_FIND_FILES.md](references/15_NATIVE_FIND_FILES.md): Native file search
- [16_NATIVE_DIRECTORY_LISTING.md](references/16_NATIVE_DIRECTORY_LISTING.md): Directory traversal
- [17_UNIX_TOOL_COMPOSITION.md](references/17_UNIX_TOOL_COMPOSITION.md): Composition principles
- [18_COMMAND_EXECUTION_BRIDGE.md](references/18_COMMAND_EXECUTION_BRIDGE.md): Process supervisor bridge
- [19_GNU_LS_ADAPTER.md](references/19_GNU_LS_ADAPTER.md): GNU `ls` wrapper
- [20_PERSISTENT_PROCESS_SEMANTICS.md](references/20_PERSISTENT_PROCESS_SEMANTICS.md): Process lifetime semantics
- [21_PROCESS_JOB_WIRE.md](references/21_PROCESS_JOB_WIRE.md): Wire framing for subprocesses
- [22_OWNED_JOB_CLIENT.md](references/22_OWNED_JOB_CLIENT.md): Owned job client
- [23_NATIVE_BASH_CUTOVER.md](references/23_NATIVE_BASH_CUTOVER.md): Native bash integration
- [24_NATIVE_IDLE_POLICY.md](references/24_NATIVE_IDLE_POLICY.md): Idle process termination
- [25_NATIVE_INTERACTIVE_SESSION.md](references/25_NATIVE_INTERACTIVE_SESSION.md): Interactive process sessions
- [26_RECORD_CAPTURE_BUDGET.md](references/26_RECORD_CAPTURE_BUDGET.md): Output capture bounds
- [27_NATIVE_WORKSPACE_GREP.md](references/27_NATIVE_WORKSPACE_GREP.md): Grep adapter and limits
- [28_NATIVE_GIT_STATUS.md](references/28_NATIVE_GIT_STATUS.md): Git status parser
- [53_NATIVE_GIT_READ_QUERIES.md](references/53_NATIVE_GIT_READ_QUERIES.md): Git read queries
- [54_NATIVE_FILE_EXCERPTS.md](references/54_NATIVE_FILE_EXCERPTS.md): Excerpt reading bounds
- [55_GIT_CONFIG_ISOLATION_PROOF.md](references/55_GIT_CONFIG_ISOLATION_PROOF.md): Git config isolation
- [56_NATIVE_GIT_WORKTREE_READS.md](references/56_NATIVE_GIT_WORKTREE_READS.md): Git worktree handling
- [57_NATIVE_SKILLS.md](references/57_NATIVE_SKILLS.md): Skill metadata discovery
- [58_NATIVE_TOOLS_COMPLETE.md](references/58_NATIVE_TOOLS_COMPLETE.md): Tool cutover proof
