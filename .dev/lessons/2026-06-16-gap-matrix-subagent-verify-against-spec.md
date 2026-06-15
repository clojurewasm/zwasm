# Gap-matrix subagents get spec semantics wrong — verify each against the primary spec before impl

**Date**: 2026-06-16
**Context**: Front ② (wasmtime async `.wast` gap-mining). An Explore subagent
read wasmtime's ~44 `component-model/async/*.wast` + zwasm's impl and produced a
prioritized gap matrix (`private/notes/p17-wasmtime-async-gaps.md`).

**Observation**: the subagent's TIER-1 list named two gaps —
"stream.cancel-read/write when NOT copying → returns 0 (no-op)" and the future
analogue — as cleanly-bounded chunks. Both are **WRONG**: CanonicalABI.md
`cancel_copy` (line ~4749) is `trap_if(e.state != CopyState.COPYING ...)`, i.e.
cancel-when-not-copying **TRAPS**. zwasm already traps (NotCopying →
mapAsyncFault → guest trap), and the prior-cycle `async_cancel_no_copy.wat`
asserts exactly that — it was already spec-correct. Implementing the subagent's
"return 0" would have introduced a regression.

The subagent also under-stated effort and mis-cited line ranges, though the
file names (`task-return-traps.wast`, `trap-if-done.wast`) and the genuinely-real
gaps (async export must call task.return when it declares a result; signature
validation) checked out against the actual `.wast` assertions.

**Why it matters**: a gap matrix is a *lead list*, not ground truth. A subagent
summarising a reference impl can invert a trap/no-op polarity — the most
dangerous error class because "implement the gap" then writes a regression.

**How to apply**: before implementing ANY gap-matrix row, (1) read the cited
primary spec (`CanonicalABI.md` def, not the test's prose) and (2) read the
actual `.wast` `assert_trap`/`assert_return` lines. Only then write the fixture.
Treat the matrix's tier/effort/polarity as hypotheses. Cross-ref:
[[feedback_perf_measure_first]] (same "measure/verify before building" posture).
