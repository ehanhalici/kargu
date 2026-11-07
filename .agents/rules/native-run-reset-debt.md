# Run reset preserves native verification debt

Starting another run previously sent `reset_changes`, which removed all owned
change rows including pending verification. Rust now clears only consumed rows
in the selected session/service. Pending rows, foreign sessions/services and undo
snapshots survive. Exact consume, proved net-zero rollback or service retirement
remains necessary to remove verification debt. Repeated resets that have nothing eligible to remove
do not advance history revision.

Consume and reset compute the next history revision before mutating records.
Revision overflow therefore cannot partially clear debt or metadata while
returning an error and leaving the previous revision visible.

The frontend clears its run display only after a valid native reset ACK. It
captures the passive row identities as well as the current display list: a late
ACK cannot clear a newer edit on the same path merely because the path/list
identity is unchanged. Failed/refused ACKs preserve the display; resetting one
explicit service does not clear another owner's compatibility list. This ACK
handling does not decide which verification rows may be removed; Rust does.

Two Rust regressions failed before the fix: reset erased pending rows, and
history overflow partially changed consume/reset state. Both pass now. A real
Emacs/stdio test writes file A, resets, writes file B, resets, consumes A through
the public ACK port, then resets again. Only consumed A metadata disappears; B
remains pending. A separate presenter test covers accepted/refused/failed resets
and a late ACK after another same-path publication. The actual native provider/
stdio test also starts a second model run after reset for write/replace/patch:
pending evidence and tool history survive while the new run gets its own request
counter.

This is 3.8a9a. Combined Stop/reset/late-ACK model-run acceptance and the native
lifecycle/default cutover remain in 3.8a9b and the parent migration tasks.

Validation: 604 locked Rust tests including 32 compile-fail, final strengthened
34/34 native agent cases, strict all-target Clippy/fmt, 112/112 affected ERT and
1449/1449 full source ERT passed. Changed Elisp warning-as-error compilation,
parentheses, production checkdoc and whitespace checks passed. TLA+ source was
unchanged; TLC was not repeated.
