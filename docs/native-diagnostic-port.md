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

The Rust result port is todo 4.3a and the file capture below is 4.3b, not full
diagnostic cutover. Project diagnostic collection, optional capability
advertisement and actual verification/healing consumers still need connection. Until then the standard
native UI does not advertise lsp_diagnostics. Existing Flymake/Eglot formatters
are migration debt. The next producer must preserve actual report generations,
backend identity, Eglot process incarnation/publication version, document tick,
truncation and negotiated frame limits; it cannot synthesize freshness from an
empty cache. No TLA+ source changed and TLC was not rerun.


## Raw Emacs file producer

The diagnostic reverse dispatcher now captures detached raw Flymake findings,
actual report-function generation handles and the original document stamp.
Rust receives the current observations and evaluates freshness. The bridge no
longer invokes the old diagnostic formatter. Severity category conversion is a
shared editor primitive in freshness.el; the new producer does not require the
legacy diagnostic formatting module.

Capture limits findings, source-coordinate traversal work, aggregate JSON and
individual message prefixes. Omission marks truncation. Metadata exceeding the
negotiated frame produces a compact typed failure with actual quiescence; no
fallback formatter or disk reader runs. Source replacement remains an observed
tick mismatch or failure, and C-g settles the owned read as cancelled.

Eglot publication observations retain the actual process object. Raw capture
maps that process incarnation to an opaque identity, preserving server/version
facts without considering an old publication fresh after process replacement.
A regression uses two actual Emacs pipe-process objects to exercise this case.

The real loopback provider acceptance enables a synthetic trusted Flymake
backend only within the test: Flymake reports a raw Unicode error, the scoped
reverse port captures it, and the next provider request contains Rust's formatted
finding. The production trusted-content check is preserved. Full source ERT
passed 1427/1427 before the last process/quit/shared-helper changes; the final
affected sensor/LSP suite passed 73/73. Changed Elisp passed warning-as-error
compilation, parenthesis checks and production checkdoc. Rust and TLA+ sources
were unchanged. Project collection and default capability cutover remain open;
the standard native UI still does not advertise the partial diagnostic capability.
