# Native undo verification identity

Undo changes document evidence even when it restores identical text. Rust reopens
verification debt for the remaining edit under a new `edit_revision`. Consume now
requires the exact session/service/edit/revision/file/final-hash identity; a missing
revision is a protocol error and an old revision returns `consumed:false`.

The application actor captures publication revision with the verified receipt.
Both inline and paged receipt descriptors carry that immutable value. Emacs copies
it into passive references and sends it back unchanged. After rollback Emacs reads
the native pending-change projection before notifying the caller. It does not infer
that an empty local undo stack means the change or verification debt is gone.
A failed projection preserves the previous reference and reports projection failure;
a delayed projection cannot replace a newer local reference.

Rust retains the initial content identity independently of the bounded undo bodies.
Restoring a known baseline removes net-zero debt. If prior undo bodies have been
evicted while modified content remains, the rollback publication becomes the new
pending reference. Missing baseline evidence is represented explicitly and cannot
prove net-zero. No source bodies or additional history DTO fields are retained for
this baseline identity.

Real Emacs/stdio regressions cover an already consumed edit A, edit B, single-step
undo B, rejection of A's old proof, acceptance of the reanchored proof, and full
undo to the initial baseline. A second regression performs 17 edits and 16 undos:
the first undo body is evicted, but its remaining content still has pending debt
and a live native reference. Existing 1 KiB Rust and 1280-byte Emacs paged receipt
regressions assert that publication revision survives paging.

This is the 3.8a5 slice. General verification reader cutover, fresh diagnostic
barriers, service drain ownership, and legacy edit engine removal remain in todo.md.

Validation: 602 locked Rust tests including 32 compile-fail; final receipt suite
20/20 after the missing/stale revision cases; strict all-target Clippy and fmt;
1436/1436 full source ERT, affected Elisp Werror/check-parens and nonmutating
production checkdoc. No TLA+ source changed, so TLC was not rerun.
