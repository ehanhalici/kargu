# Typed native file diagnostic result port

The native lsp_diagnostics executor consumes a DiagnosticSnapshot observation
bound to the exact document resource captured before issuance. Its freshness
and formatting come from Rust. Editor-provided result text is ignored; a
prose-only success cannot certify diagnostics. Missing/foreign typed data fails
without falling back to the legacy formatter.

Freshness remains distinct from successful execution of a read. Only fresh
observations yield an OK read; pending, stale, unavailable and truncated reports
remain failures. A fresh snapshot can contain real error findings. Rendering
preserves scalar coordinates, severity, source and raw message, while explicitly
leaving project-wide effects unverified. The rendered body has a byte bound.
Stop keeps the actual issued read pending until its callback returns, then
suppresses its payload and preserves cancellation rather than publishing facts.

The real provider/stdio regression exercises fresh errors, pending, stale,
unavailable, truncated, foreign document, forged editor prose and cancellation
with an actual draining interval and no next provider request. Validation: 600
locked Rust tests including 32 compile-fail passed before the final cancellation
guard; the final native agent suite passed 34/34, the last raw-error rendering
fixture passed separately, strict all-target Clippy/fmt and 44 focused ERT passed.
These working-tree totals include unfinished task 7/8 tests.

This is todo 4.3a, not full diagnostic cutover. The Elisp raw fact producer,
project diagnostic collection, optional capability advertisement and actual
verification/healing consumers still need connection. Until then the standard
native UI does not advertise lsp_diagnostics. Existing Flymake/Eglot formatters
are migration debt. The next producer must preserve actual report generations,
backend identity, Eglot process incarnation/publication version, document tick,
truncation and negotiated frame limits; it cannot synthesize freshness from an
empty cache. No TLA+ source changed and TLC was not rerun.
