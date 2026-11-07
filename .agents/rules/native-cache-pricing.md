# Canonical cache pricing

Native wire normalization includes cache-read and cache-creation counters in
the canonical prompt-token total. The old pricing helper charged that entire
total at the input rate and then added cache reads again. It also accepted a
fixture with more cached tokens than total input, and omitted cache-write rates.

`PricingUsage` now accepts complete typed counters and checks that the two cache
subsets fit inside total input. It retains the remaining uncached input, output,
cache reads and cache writes separately. Cache creation has its own token type,
also used at wire ingestion; a compile-fail example rejects swapping cache-read
and cache-write counts. There is no implicit zero for missing billing counters.
Callers without complete usage pass `None` and receive unknown cost.

`PricingRates` captures four distinct rate types. Each nonzero category needs its
own rate. Explicit zero rates are free; absent rates are unknown. Zero observed
categories do not require prices. Checked arithmetic preserves the decimal
fraction across categories before checking the final integer micro-USD boundary.
A fractional final result remains unknown; an overflowing result fails rather
than wrapping. This local exact sum neither rounds spend nor reserves money.

Regression coverage includes disjoint read/write billing, invalid or overlapping
subsets, missing versus free rates, fractional sums, large denominators and
integer overflow. A wire-to-pricing test normalizes provider input that excludes
cache, then prices the inclusive canonical total exactly once per category.

This completes todo 6.2b only. Actual model-price capture, conservative admission
reservation, provider settlement/refund and concurrent hard monetary enforcement
remain open in 6.2. No runtime consumer currently invokes this pricing helper;
the corrected foundation must be connected before hard-limit claims are valid.
The Elisp accounting state remains migration debt, not a second authority.

Validation on the current working tree: 598 locked Rust tests (32 compile-fail
included), 1414/1414 full source ERT, strict all-target Clippy with panic/unwrap/
expect denied, and formatting checks passed. These counts include uncommitted
future task 7/8 tests and do not certify those unfinished features. The preceding
metadata adapter also passed warning-as-error byte compilation and checkdoc.

TLA+ sources were unchanged; TLC was not rerun.
