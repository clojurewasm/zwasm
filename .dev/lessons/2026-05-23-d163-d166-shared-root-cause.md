# D-163 + D-166: shared root cause — scratch_typeidxs leftover between modules

> **Citing**: D-166 fix `e5042b3e`, D-163 close `<this commit>`.
> Predecessor lessons:
> [`2026-05-23-d163-static-jit-layout-verified.md`](2026-05-23-d163-static-jit-layout-verified.md),
> [`2026-05-23-d163-entry-helper-exonerated.md`](2026-05-23-d163-entry-helper-exonerated.md).

## The connection

D-163 (Win64 silent process death on
`wasm-2.0/call/assert_trap as-call_indirect-last`, cycles 10-14
narrowing) and D-166 (ubuntu memory_grow.4 5 off-by-one fails,
cycle 16 discovery) **had the same root cause**: the spec runner
did not reset `scratch_typeidxs[]` to the `maxInt(u32)` sentinel
between modules, leaving stale typeidx values from prior modules.

The runner's bounds check uses `rt.table_size = scratch_funcptrs.len`
(= 1024 scratch capacity, per `base.zig:668` comment) and relies
on the sig-mismatch trap stub via `scratch_typeidxs[k] = maxInt(u32)`
sentinel to trap OOB call_indirect indices. When leftover stale
typeidx happens to match the expected typeidx, the sig check
passes, the stale funcptr (= dangling JIT body pointer from a
freed prior module) is executed, and the resulting wild jump
corrupts host state.

## Per-host symptom

- **Mac aarch64** — the wild call from the stale funcptr happens
  to either trap cleanly or return without breaking subsequent
  state. The bug is INVISIBLE on Mac. D-166 (memory_grow.4
  off-by-one) does NOT fail on Mac.
- **Ubuntu x86_64 SysV** — the wild call's bytes happen to mutate
  `current_mem_bytes` (the runner's host-side global var that
  `memory.grow` callouts also touch). Symptom: memory_grow.4's
  later assertions see memory at 2 pages when expected 1, causing
  off-by-one in 5 assert_returns that call `memory.grow(0)`.
- **Win64 (windowsmini)** — the wild call lands on Win64-incompatible
  bytes (likely a memory access through an invalid pointer); the
  Win64 exception handler chain converts this to silent process
  death (exit 1, no SEGV handler text, no Error.Trap return,
  stdout-buffer flush never reached).

## Diagnostic path that revealed the root cause

D-163 narrowing (cycles 10-14):
1. Cycle 10: corrected misattribution (wasm-1.0/call/ doesn't exist).
2. Cycle 11: re-enabled `[d-163-jit]` per-function JIT hex dump.
3. Cycle 12: decoded `func56` (call_indirect with bounds-check) —
   static layout (SUB/ADD match, R15 preserved, alignment) all
   correct. **H1/H3/H4 hypotheses rejected.**
4. Cycle 13: bypass SKIP arm, captured silent process death
   with no SEGV handler text. Hypothesis pivoted to runtime side.
5. Cycle 14: instrumented `invokeAndCheck` POST print — confirmed
   `@call(f, ...)` never returns. **Entry helper exonerated.**

D-166 discovery (cycle 16):
6. cycle 16: ubuntu test-all surfaced memory_grow.4 off-by-one
   (5 fails). Bisect identified `func_ptrs` corpus leaks state
   into `memory_grow`. Trace via `growableMemoryGrowFn` print
   showed `current_mem_bytes` mutated WITHOUT going through the
   grow callout — implicating wild memory write.
7. cycle 19: traced `rt.table_size` and discovered `funcptrs.len`
   (= scratch capacity 1024) being passed → bounds check effectively
   disabled → fallback to sig-mismatch sentinel. **`scratch_typeidxs`
   not reset between modules** identified as the structural gap.

## The fix

`test/spec/spec_assert_runner_non_simd.zig:251` (post-D-166):

```zig
const table0_min = base.effectiveTable0Min(gpa, wasm_bytes, base.current_registered);
const table0_cap = @min(@as(usize, table0_min), scratch_funcptrs.len);
// D-166 fix — reset scratch_funcptrs / scratch_typeidxs to sentinel
// FOR THE FULL CAPACITY before applyTableInit writes table0_cap entries.
@memset(scratch_funcptrs[0..], 0);
@memset(scratch_typeidxs[0..], std.math.maxInt(u32));
runner_mod.applyTableInitCtx(..., scratch_funcptrs[0..table0_cap],
                                  scratch_typeidxs[0..table0_cap], ...);
```

## Verification

- Mac aarch64 `zig build test`: unchanged (test was always green).
- ubuntu x86_64 SysV full `wasm-2.0-assert` corpus:
  5 fails → **0** (25457 passed, 0 failed, 469 skipped).
- Win64 (windowsmini) isolated `wasm-2.0/call/` corpus with
  SKIP arm bypassed: D-163's `assert_trap as-call_indirect-last`
  **PASSes**. Companion 2 fails remain
  (`type-all-i32-i32`, `as-call-all-operands` — multi-result
  i32 garbage, distinct from D-163 / D-166; D-094/D-164 territory).
- `scripts/check_phase9_close_invariants.sh --gate`: **18/18 pass**
  (was 17/18 with I1 D-163 SKIP arm blocking).

## Takeaway for future debug

When investigating Win64 process-death-without-SEGV symptoms,
suspect **stale data from prior modules / corpora that the
JIT-emitted code may dispatch through** (function pointers,
typeidx, table base/size). The "silent process death" pattern
is asymmetric across hosts (visible as wrong value on
ubuntu/SysV, invisible/PASS on Mac aarch64, silent death on
Win64) — running test-all on ALL THREE hosts is what catches it.

## Refs

- D-163 row (removed at close commit).
- D-166 row (removed at fix commit `e5042b3e`).
- Phase 9 close invariants script:
  `scripts/check_phase9_close_invariants.sh`.
- Spike: `private/spikes/d-163-win64-call-indirect-trap/`
  (cycle 14 hypothesis table — H1/H3/H4 marked rejected;
  H2 superseded by this finding; spike can be archived).
- `test/spec/spec_assert_runner_base.zig:264` (`makeJitRuntime`
  with the documented `table_size = funcptrs.len` design).
- `test/spec/spec_assert_runner_non_simd.zig:251` (the fix
  site).
