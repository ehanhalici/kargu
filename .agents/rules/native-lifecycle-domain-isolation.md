# Native lifecycle domain isolation

The native run's shared editor lifecycle previously queried legacy modified and
pending tables when producing its terminal report. It also reset legacy change
state before native dispatch and invoked legacy edit abort/history repair on
Stop or error. Those tables and engines do not identify the native conversation.

Backend selection is now captured in the run before asynchronous preparation.
Dispatch uses that captured selection. Native startup skips legacy change reset;
terminal reports skip legacy change queries and explicitly mark change evidence
unavailable until the native projection is connected. This is not an empty or
clean verification verdict. Native cleanup retains task cancellation and editor
session activity cleanup while skipping legacy edit abort, overlay mutation and
history repair. Legacy runs retain their existing behavior.

Regression coverage checks done/error/Stop reports against a legacy-query trap,
selection capture before startup, and cleanup against legacy history acquisition,
abort and repair traps. The final lifecycle/history/ownership suite passed 60/60;
changed Elisp passed warning-as-error byte compilation and parenthesis checks.
The full source ERT run passed 1419/1419 before the final cleanup guard and two
additional fixtures; the final focused run covers those changes. Production
checkdoc also passed. Native pending-file/report projection and actual verification remain open in
3.8/5.9/6.4. Rust and TLA+ sources were unchanged in this slice.
