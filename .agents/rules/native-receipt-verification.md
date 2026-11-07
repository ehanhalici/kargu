# Native file diagnostic verification consumer

A native agent `lsp_diagnostics` file read now consumes its own conversation's
pending receipt evidence when the exact captured document is fresh and has no
error diagnostics. Rust captures a non-deserializable, single-use ticket before
issuing the read. It binds session, edit ID, publication revision, file index,
content hash and document UUID/tick; capture also checks the workspace root.
Settlement rechecks the current ledger row and advances its revision before
clearing the pending flag. It does not require retained undo bodies or remove
them. Explicit editor-service rows and foreign sessions are excluded.

The existing read grant, parent RunId, deadline and actual reverse-call drain
remain in force. Stop/timeout ignores late payloads; project aggregation, another
document revision, prose-only results and incomplete observations do not consume
file evidence. Errors keep debt pending. A refused metadata settlement also keeps
debt and cannot complete the already finished read action a second time.

The native Emacs adapter now copies Flymake's actual severity property instead
of applying the legacy category formatter. Rust parses bounded positive integer
ranks (note=1, warning=2, error>=3). Missing, invalid or fractional severity is not
an informational fallback. A private parse-time marker distinguishes native
grading from compatibility strings. Canonical labels remain readable, but
preclassified findings cannot settle receipt evidence. The marker is neither
accepted from JSON nor serialized as a client authority field.

Four ledger tests cover exact/foreign ownership, incomplete/error observations,
reanchored revision/hash/document evidence and atomic overflow refusal. The actual
provider/stdio pipeline covers 18 cases including custom raw errors, unknown
severity, preclassified warnings/info, forged native grading, project reads,
reset, Stop and a newer document tick. It retains the file, undo metadata and
normal per-run request accounting.

A real Emacs integration performs native write/save, a synchronous synthetic
Flymake report, typed reverse diagnostics and the next provider turn. Rust's
terminal DTO reports pending=0, retained=1 and three model requests. Emacs only
runs primitives and forwards observations; it does not choose the verdict.

This is 6.4b1: an explicit file diagnostic tool read is a real verification
consumer. Automatic verification after every edit, fresh-pull barriers, diagnostic
baseline capture/delta handling, deleted/closed-file and explicit service cases,
bounded healing and legacy consumer removal remain open in 6.4b2. Pending=0 does
not certify project-wide cleanliness.

Validation: 612 locked Rust tests including 32 compile-fail; 35 native agent
integration tests; 1451/1451 full source ERT; strict all-target Clippy/fmt; changed
Elisp warning-as-error compilation, parentheses, nonmutating production checkdoc
and whitespace checks passed. No TLA+ source changed; TLC was not repeated.
