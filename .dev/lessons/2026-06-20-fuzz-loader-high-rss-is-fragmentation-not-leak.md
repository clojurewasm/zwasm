# fuzz-loader high RSS on complex-module campaigns = allocator fragmentation, NOT a compileWasm leak

**Observation (2026-06-20):** running `zwasm-fuzz-loader` over a varied-config
campaign (smith_v2: gc + EH + SIMD + multi-table + 3000-instr funcs) grew the
process to ~7 GiB RSS by ~module 3350/3776. Alarming — looked like a per-module
leak in `compileWasm` / `CompiledWasm.deinit` (which would hurt embedders calling
compileWasm repeatedly).

**Verdict: NOT a leak.** Verified by temporarily wrapping the loader's `init.gpa`
with `std.heap.DebugAllocator(.{})` and running on 300 diverse v3 modules (121
JIT-compiled): `dbg.deinit()` reported **`.ok` (zero leaks)**. So compileWasm +
deinit fully frees on diverse complex modules. The high RSS is **allocator
fragmentation / transient high-watermark** — the page allocator does not return
freed pages to the OS, and a few large-transient v2 modules pushed the watermark
up. It is harness-only and graceful (under a memory ulimit the loader OOM-skips
the offending compile and continues).

**Rules:**
- A growing-RSS fuzz harness is NOT evidence of a product leak. Confirm with a
  `DebugAllocator` (testing.allocator) leak check BEFORE filing a leak bug — the
  loader's success path returns from `main`, so a `defer dbg.deinit()` reports.
- No single module blows up: an individual `zwasm run --engine jit <mod>` peaks
  < 500 MB even when the all-in-one-process loader hits GiB. Distinguish per-
  process accumulation (fragmentation) from per-module cost (CLI scan).
- The loader runs under a memory ulimit safely; don't chase the watermark.

(Investigation cost: ~2 cycles. Closed debt D-474 disproven.)
