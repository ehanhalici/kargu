---
name: native-migration
description: Step-by-step workflow for porting Elisp domain features to the Rust native backend in Kargu. Use when taking on migration tasks from todo.md or transitioning legacy Elisp logic to Rust.
---

# Kargu Native Migration Workflow

This skill guides the incremental migration of Kargu from legacy Emacs Lisp domain engines to the high-performance Rust native backend (`kargu-core`).

## 1. Governance & Source of Truth

- **Task Checklist**: [todo.md](../../../todo.md) is the **only authoritative checklist** for migration tasks and acceptance criteria.
- **Architecture Masterplan**: Follow [00_MIGRATION_ARCHITECTURE.md](references/00_MIGRATION_ARCHITECTURE.md).
- **Phased Roadmap**: Follow [04_PHASED_ROADMAP.md](references/04_PHASED_ROADMAP.md).
- **Core Patterns**: Apply [coding-standards](../coding-standards/SKILL.md) and [01_RUST_CORE_PATTERNS.md](../coding-standards/references/01_RUST_CORE_PATTERNS.md) to all Rust implementations.
- **Progress & Baseline**: Consult [12_MIGRATION_PROGRESS.md](references/12_MIGRATION_PROGRESS.md) and [13_MIGRATION_BASELINE.json](references/13_MIGRATION_BASELINE.json).

---

## 2. Standard Migration Step-by-Step

### Step 1: Scope & Contract Discovery
1. Identify the task item in `todo.md`.
2. Review existing contracts in [architecture-contracts.md](../../rules/architecture-contracts.md) and [kargu-laws.md](../../rules/kargu-laws.md).
3. Map legacy Elisp symbols to their intended Rust domain types.

### Step 2: Implement Domain Core in Rust
1. Add domain models, invariants, and state logic under `kargu-core/src/`.
2. Follow "Parse, Don't Validate" and zero-panic guidelines:
   - Use Newtypes for all domain keys and IDs.
   - Closed error enums via `thiserror`.
   - Overflow-checked counters and bounded values.
3. Expose typed DTOs and commands in the RPC layer (`kargu-core/src/host.rs` / `service.rs`).

### Step 3: Write Rust Unit & Integration Tests
1. Write comprehensive tests in Rust covering:
   - Happy path and state transitions.
   - Boundary limits, malformed inputs, and rejection conditions.
   - Cancellation and resource cleanup.
2. Verify all tests pass:
   ```bash
   cargo test -p kargu-core
   ```

### Step 4: Wire Elisp Thin Frontend
1. Replace Elisp decision-making code with an RPC call to the Rust backend.
2. In Elisp, consume only the typed DTOs returned by Rust.
3. Update UI hooks to render the Rust state without duplicating business rules.

### Step 5: Parity & Regression Verification
1. Run both unit and integration tests in Elisp:
   ```bash
   emacs -Q --batch -L . -l tests/run-tests.el
   ```
2. Confirm that all existing laws and behaviors pass without regression.

### Step 6: Eliminate Transition Debt
1. Once real editor consumers are cut over and parity is proven, delete the legacy Elisp functions.
2. Do not keep dead code, obsolete flags, or unused helpers.
3. Mark the corresponding item complete in `todo.md`.
