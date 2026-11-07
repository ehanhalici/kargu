---
name: coding-standards
description: Enforces Rust core architectural patterns, memory and concurrency safety, zero-panic invariants, and the thin-Elisp UI bridge contracts for Kargu. Use whenever designing, writing, refactoring, or reviewing Rust or Elisp code.
---

# Kargu Coding Standards & Architecture Patterns

This skill defines the non-negotiable coding and architecture standards for Kargu. All contributions to Rust (`kargu-core`) and Emacs Lisp (`kargu/`) must strictly adhere to these principles.

## 1. Prime Directive: Rust Backend, Thin Elisp Frontend

- **Rust is the Backend**: All orchestration, business logic, configuration parsing, provider/model discovery, HTTP/SSE transport, caching, event loops, permissions, tool dispatch, history, token budgeting, compaction, healing, and verification live in Rust (`kargu-core`).
- **Elisp is the Editor Bridge**: GNU Emacs Lisp is strictly a thin user interface and editor adapter. It only renders DTOs received from Rust, handles buffer navigation/presentation, coordinates native Emacs UI (diffs, completions), and passes user actions back to Rust.
- **No Duplicate State**: Never introduce parallel domain state stores, second decision engines, or shadow validation layers in Elisp.

Related documents:
- [.agents/rules/AGENTS.md](file:///home/emrehan/.emacs.local/kargu/.agents/AGENTS.md)
- [.agents/rules/kodlama_standardi.md](file:///home/emrehan/.emacs.local/kargu/.agents/rules/kodlama_standardi.md)
- [.agents/rules/architecture_principles.md](file:///home/emrehan/.emacs.local/kargu/.agents/rules/architecture_principles.md)
- [01_RUST_CORE_PATTERNS.md](references/01_RUST_CORE_PATTERNS.md): Rust core architectural patterns and zero-panic invariants
- [39_RUST_PATTERN_AUDIT.md](references/39_RUST_PATTERN_AUDIT.md): Rust pattern audit and compliance proof

---

## 2. Rust Core Architecture Patterns (`kargu-core`)

### 2.1 Type System & "Parse, Don't Validate"
- **No Primitive Obsession**: Never use bare `u32`, `usize`, or `String` for domain identities, limits, coordinates, or counters. Define explicit newtypes (e.g., `SessionId`, `RequestId`, `EditRevision`, `ByteBudget`).
- **Parse, Don't Validate**: Validate external inputs at the boundary (DTO / JSON / CLI) via `TryFrom` or `FromStr`. Once a type enters the core domain, functions do not perform defensive `if x <= 0` checks—the type itself guarantees valid invariants.
- **Numeric Discipline**:
  - Never use floats (`f32`/`f64`) for money, tokens, or budgets; use fixed-point or rational integers.
  - Required floats (temperature, top_p) must forbid `NaN` and `Infinity` and use validated bounded ranges (`BoundedFloat<MIN, MAX>`).
  - Use overflow-protected operations (`checked_*`, `saturating_*`) for arithmetic.
- **Zero Panics in Library Code**:
  - `unwrap()`, `expect()`, and `panic!()` are strictly forbidden in `kargu-core`.
  - Slice indexing must use `.get(index)` and handle `None`.
  - Errors must use closed `thiserror` domain enums (`CoreError`), never unstructured strings.

### 2.2 Lifecycle, State Machines & Ownership
- **Typestate Pattern**: Model deterministic transitions (e.g. `Initial -> Ingesting -> Executing -> Completed`) such that methods consume `self` and return the new state. Invalid transitions must fail at compile time.
- **Single Writer Principle**: Only a single Actor loop owns and mutates session state. Background I/O (network, subprocesses, disk) communicates purely through typed message channels.
- **Cascading Teardown & Drain**: Cancellation (`Cancel`) must trigger orderly teardown:
  1. Drop active network streams via `CancellationToken`.
  2. Cancel pending async response channels.
  3. Flush unfinished tool calls with synthetic cancellation error results so protocol invariants are preserved.
  4. Ensure all resources drain before accepting new requests.

### 2.3 Process Management & OS Hygiene
- **Process Group (PGID) Isolation**: Every child process must run as a distinct process group leader (`setpgid(0)`). On cancellation or timeout, terminate the entire process tree (`-pgid`) using `SIGTERM -> grace period -> SIGKILL`. Never leave zombie or orphan processes.
- **Filesystem Sandboxing**: Canonicalize all file paths (`canonicalize()`) and verify they stay within the active workspace root. Reject path traversal (`../`) before performing I/O.
- **Tool Privilege Separation**:
  - Categorize tools: `SafeReadOnly`, `MutatesState`, `ExecutesArbitraryCode`.
  - Mutating operations require explicit user approval barriers.

### 2.4 IPC, Wire Framing & Bounded Buffers
- **Bounded Buffer Framing**: Line-based protocols (NDJSON / JSON-RPC over stdio) must enforce an explicit maximum frame limit (e.g. 1024 bytes for handshake frames). Reject unbounded streams to prevent OOM.
- **Reverse RPC**: Editor-provided data (diagnostics, live buffers) are requested via typed reverse calls with a unique `RequestId` and correlation handle.

---

## 3. Emacs Lisp Thin Bridge Standards (`kargu/`)

### 3.1 Non-Blocking Asynchrony
- Never block the Emacs UI thread with `sleep-for`, synchronous HTTP, or synchronous subprocess execution.
- All network and process calls run via `plz` / child processes / timers with completion callbacks.

### 3.2 UI Selection Contracts
- **Candidate Integrity**: Selection candidates come exclusively from the Rust API / DTOs. Never accept arbitrary free-text strings for provider, model, or mode selections.
- **Two-Step Interaction**:
  - First `RET` on a field activates editing and presents the complete list of valid candidates without automatically selecting the first item.
  - User filters or highlights a choice, and a subsequent `RET` confirms and commits the selection.

### 3.3 Buffer and Context Isolation
- Session state must be stored in buffer-local variables (`defvar-local`) or structs (`cl-defstruct`), never in mutable global state variables.
- Cleanly separate display views from the underlying data transport.

### 3.4 Error Reporting
- Pre-run validation rejections must raise `user-error` with actionable guidance, never leaving the UI in a broken or half-busy state.
- Provider errors must be classified into structured classes (token overflow, rate limit, authentication, timeout).

---

## 4. Verification Checklist Before Any Change

1. [ ] Does this logic belong in Rust? If it is a decision, validation, or state update, move it to Rust.
2. [ ] Are all Rust types safe from panics (`unwrap()`, `expect()`, `[i]`)?
3. [ ] Are inputs parsed at the boundary into strong Newtypes?
4. [ ] Does the Elisp layer remain a pure presentation bridge?
5. [ ] Do all tests in `cargo test -p kargu-core` and ERT `tests/run-tests.el` pass?
