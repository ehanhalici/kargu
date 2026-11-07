# Stop, reset and late edit completion across native runs

The actual provider/stdio edit regression now combines Stop with reset and a
subsequent model run. It covers both an issued handler that never dispatches a
write and a handler that completes a verified save after Stop.

An early orchestration callback cannot release the issued claim. A reset during
drain also cannot admit a competing run. After the real receipt/quiescent witness
settles, the first run emits exactly one cancelled terminal result and one tool
result carrying the actual effect. A late verified save remains pending evidence.

The next model run is held in a controlled loopback provider exchange while an
old completion is replayed, an old receipt upload is attempted, and reset runs
again. The old receipt is rejected, a competing run stays busy, and the held run
finishes with its own request counter. Pending evidence equals the actual saved
effect; the file and inherited tool history do not change or duplicate.

Validation: 34/34 native agent integration tests, strict all-target Clippy and
fmt passed. No production or Elisp/TLA+ source changed in this slice, so their
prior checks were not rerun. This completes the combined runtime case in
3.8a9b; native default/legacy consumer cutover remains separately open there.
