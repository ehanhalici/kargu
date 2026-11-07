# Diagnostic baseline origin compatibility

A fresh current diagnostic snapshot does not establish that an older baseline
came from the same live checkers. The native `compare_errors` primitive previously
compared any two fresh snapshots of the same document identity/path, including
snapshots separated by a language-server restart or checker replacement.

Rust now requires the same checker identity set and the same server presence/
identity. Server versions and document ticks must move forward or remain equal.
Backend ordering and new report-function generations do not invalidate a baseline;
they are expected across a real edit. Per-source semantic error identities and
duplicate counts continue to ignore position-only shifts.

An incompatible baseline produces no delta. This does not change whether the
current snapshot itself is fresh or contains zero errors, and it does not certify
project-wide effects. It prevents labeling findings as new/pre-existing/resolved
using evidence from a different producer cohort or a later document revision.

The restart regression failed before the change. Cases now cover server restart/
removal, checker replacement/addition/removal, reversed document tick and reversed
server version. A positive case advances tick/version/report generation while
reordering the same checkers; the existing duplicate/position-shift case remains
valid.

This repairs the native comparison primitive in 6.4a. Native receipt-bound baseline
capture, automatic post-edit verification/healing and deletion of their legacy
Elisp consumers remain open in 6.4b and the parent tasks. The primitive is not yet
an end-to-end verification consumer.

Validation: 606 locked Rust tests including 32 compile-fail, 9/9 sensor contract
tests, strict all-target Clippy and fmt passed. Elisp and TLA+ source did not
change; ERT/TLC were not repeated for this native primitive change.
