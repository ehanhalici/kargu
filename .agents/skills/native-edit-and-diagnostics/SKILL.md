---
name: native-edit-and-diagnostics
description: Procedures and invariants for file modifications, shadow buffer diffs, edit transactions, diagnostic captures, self-healing loops, and undo verification in Kargu. Use when working on file editing tools, LSP diagnostics, or undo mechanisms.
---

# Kargu Native Edit & Diagnostics Architecture

This skill details the architecture and operational invariants governing native file editing, shadow buffer review, LSP diagnostic verification, and undo tracking in Kargu.

## 1. Edit Transaction Lifecycle

```
[Agent Tool Request] 
         │
         ▼
[Rust Native Edit Service] ──(Prepare)──► Capture shadow buffer & compute diff
         │
         ▼
[Editor Review / Approval Gate]
         ├── Auto: applied immediately, keeps rollback snapshot
         └── Async/Blocking: awaits explicit user acceptance
         │
         ▼
[Disk Write & Revision Bump] ──► Record in owned change ledger (New edit_revision)
         │
         ▼
[Diagnostic Verification] ──► Fresh LSP DiagnosticSnapshot captured
```

### Invariants:
1. **Connection Epoch & Service Lease**:
   - Every edit preparation handle captures the physical connection epoch and session scope ([native-edit-handle-epoch.md](../../rules/native-edit-handle-epoch.md), [native-service-close.md](../../rules/native-service-close.md)).
   - Rollback and consume operations require matching the captured service lease.
2. **Atomic Writes & Rollback Snapshots**:
   - All file mutations preserve an undo snapshot prior to modification.
   - Deletions and edits must be reversible via native undo.

---

## 2. LSP Diagnostics & Self-Healing

1. **Typed Diagnostic Result Port**:
   - Diagnostic captures consume a `DiagnosticSnapshot` observation bound to the exact document resource captured prior to issuance ([native-diagnostic-port.md](../../rules/native-diagnostic-port.md)).
   - Freshness and formatting are owned by Rust; editor-provided raw text is never parsed for control flow.
2. **Baseline Origin Compatibility**:
   - Comparing diagnostic snapshots requires verifying they originated from the same live checkers and document revision ([native-diagnostic-baseline-origin.md](../../rules/native-diagnostic-baseline-origin.md)).
3. **Freshness Receipts**:
   - Verification consumes a non-deserializable, single-use ticket issued by Rust when the document is confirmed fresh and error-free ([native-receipt-verification.md](../../rules/native-receipt-verification.md)).

---

## 3. Undo Verification & Ledger Retention

1. **Identity Integrity**:
   - Undoing an edit creates a new `edit_revision` and reopens verification debt ([native-undo-verification.md](../../rules/native-undo-verification.md)).
   - Consume requires the exact `(session, service, edit, revision, file, final-hash)` tuple.
2. **Capacity Pressure Retention**:
   - The Rust actor owns both undo snapshots and the changed-file ledger. Evicting an undo body under memory pressure must NEVER discard a file that still awaits verification ([native-change-capacity.md](../../rules/native-change-capacity.md)).
3. **Run Reset & Stop Behavior**:
   - Initiating a subsequent run or issuing a Stop command preserves pending verification debt across sessions ([native-run-reset-debt.md](../../rules/native-run-reset-debt.md), [native-stop-reset-acceptance.md](../../rules/native-stop-reset-acceptance.md)).
