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
diagnostic cutover. The project collection/capability work below completes 4.3c. Public/standalone
formatter migration, fresh pull/barriers and actual verification/healing consumers
still need connection. The native UI now advertises lsp_diagnostics for typed file/project reads. Existing Flymake/Eglot formatters
are migration debt. The next producer must preserve actual report generations,
backend identity, Eglot process incarnation/publication version, document tick,
truncation and negotiated frame limits; it cannot synthesize freshness from an
empty cache. No TLA+ source changed and TLC was not rerun.


## Raw Emacs file producer

The diagnostic reverse dispatcher now captures detached raw Flymake findings,
actual report-function generation handles and the original document stamp.
Rust receives the current observations and evaluates freshness. The bridge no
longer invokes the old diagnostic formatter. The producer now copies Flymake's
raw severity property; classification belongs to Rust. The legacy category
helper remains only for unmigrated consumers. The receipt-bound file verification
consumer and raw grading contract are documented in native-receipt-verification.md.

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
were unchanged. Project collection and native UI capability cutover are completed by the next
section; standalone/public formatters and verification remain migration debt.


## Project collection and native UI capability

Project reads collect bounded live snapshots and raw foreign/list-only Flymake
file-cache records. They use the native-captured workspace without invoking
project-root discovery or opening files. A file-locus record has a known line
and an optional scalar column, not an invented live document/version or range.
Flymake's missing/zero column remains unknown; positive columns are converted
from its one-based character coordinates. Foreign loci are rejected before
reading diagnostic text. Aggregate bytes/items/documents and frame truncation
are explicit, with a real 1 KiB project roundtrip regression.

Rust parses a bounded ProjectDiagnostics value. It groups output, deduplicates
cached observations by their full semantic/location identity and supersedes an
old cache only when the same producer has a fresh live snapshot for that path.
Other sources remain visible as unversioned and unavailable. Empty, stale,
pending or truncated collections cannot certify a clean project. Even complete
live observations explicitly leave unopened/unreported files and project-wide
build/test effects unverified. The native UI now advertises lsp_diagnostics.

The preparation boundary binds the requested file/project selection to the
resource class before issuance; project reads cannot silently acquire a current
buffer and file reads cannot widen to project scope. The native result handler
uses that prepared contract. Public/standalone legacy formatters, fresh pull/
barrier orchestration and actual post-edit verification/healing remain open.

Validation: 602 locked Rust tests including 32 compile-fail, strict all-target
Clippy/fmt, 1431/1431 full source ERT before the last gate/capture changes, and
78/78 final affected sensor/LSP tests. Changed Elisp Werror compilation,
parenthesis checks and production checkdoc passed. The working-tree totals
include future task 7/8 tests and do not certify those uncommitted features.
Rust catalog/agent acceptance also passed after the final resource gate change.
No TLA+ source changed; TLC was not rerun.
