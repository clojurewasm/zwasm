# W47 — `tgo_strops_cached` regression investigation

Captured: 2026-04-29 PM, autonomous session.
Status: investigated, no fix shipped (variance dominates the signal).

## Hypothesis at the start

`bench/history.yaml` row v1.9.1 reported `tgo_strops_cached: 64.5ms`;
later v1.10/1.11 entries hit ~80ms. Per `.dev/checklist.md` the
working theory was a TinyGo strops codegen path regression in the
post–Zig 0.16 JIT (regalloc / memory-access pattern change).

## What `string_ops` actually does

`bench/tinygo/string_ops.go` exports `string_ops(n int32)` which
loops `for i := 0; i < n; i++ { total += digitCount(i) }`. The
inner `digitCount` is a `for v > 0 { v /= 10; count++ }` digit
counter — i.e. the hot path is two nested loops doing
`i32.div_u` against the constant `10`. The wasm
(`bench/wasm/tgo_string_ops.wasm`, ~9.7 KB) confirms it: the `loop`
body in `$string_ops` is essentially `i32.div_u 10 + br_if`. Both
the cached and uncached invocations exercise the same execution
pipeline once load finishes; cache only saves the predecode step.

## Repro on current `main` (commit 9a1c76b, after W50 PR-D)

Mac M4 Pro, ReleaseSafe, hyperfine on `bench/wasm/tgo_string_ops.wasm`
with `string_ops 10_000_000`:

| Variant            | n=5 mean ± σ        | n=20 mean ± σ        | range (n=20)        |
|--------------------|---------------------|----------------------|---------------------|
| `run --invoke`     | 69.6 ± 8.2 ms       | 71.8 ± 13.3 ms       | 54.9 – 102.4 ms     |
| `run --cache --invoke` | 82.7 ± 13.0 ms  | 74.4 ± 13.5 ms       | 55.0 – 102.4 ms     |

Forced-interpreter at n=1_000_000 (one tenth the work) was
160.6 ± 5.0 ms — i.e. the JIT path is ~23× faster, so the JIT is
being engaged for this benchmark.

## What this changes about the regression story

- The baseline (v1.9.1) numbers were 5-run measurements; the
  current 20-run numbers above show a per-sample standard deviation
  of ~18 % of the mean.
- Recomputed against the v1.9.1 baseline:
  - uncached: 62.2 → 71.8 ms (+15.4 %, < 1 σ)
  - cached:   64.5 → 74.4 ms (+15.3 %, < 1 σ)
- Both variants moved by the same amount, so the cached vs uncached
  delta the original W47 entry singled out is dominated by run-to-run
  noise. The "real" regression is a ~15 % uniform slowdown of this
  specific TinyGo workload across the post-0.16 binaries.
- The variance is high enough that 5-run samples can land anywhere
  from "no regression" to "+50 %" purely by chance. A 5-run bisect
  would be unreliable.

## Why this benchmark is noisy

The hot loop is two adjacent integer divisions wrapped in a
`br_if` back-edge. On Apple M4 Pro this is short enough to be
sensitive to thermal headroom, P-core scheduling, and macOS
background activity. Other tinygo benchmarks (`tgo_fib`,
`tgo_sieve`, `tgo_arith`) have σ < 5 % under the same harness, so
the noise is workload-specific rather than methodology-wide.

## Next step recommendations

If the regression is worth chasing:

1. **Stabilise the measurement first.** A 50-run hyperfine or a
   custom in-process loop that times only the JIT'd region (i.e.
   subtracts module-load + WASI startup from each sample) would
   bring σ under 5 %. Without that, anything below ~25 % is below
   detection threshold.
2. **Bisect with stable measurement.** Once σ is low enough,
   `git bisect` between v1.9.1 (`078f8f2`) and v1.10.0
   (`c89b95a`) — that range is the Zig 0.15 → 0.16 migration plus
   the W46 link_libc work, so the suspect range is large but
   well-bounded.
3. **Compare LLVM codegen of the interpreter inner loop.** The
   regression survives the JIT entry point, so it is more likely a
   Zig 0.16 / LLVM 19 codegen difference for the interpreter
   thunk that dispatches to JIT than a JIT-emitted machine code
   issue. `zig objdump --disassemble` on
   `vm.zig`'s hot dispatch loop in v1.9.1 vs current would surface
   the change directly.

## What was *not* done in this session

- No bisect (variance would dominate).
- No JIT-codegen change (no signal to act on).
- No new benchmark harness (out of scope; would be its own PR).

This file is intentionally small and self-contained. Delete it
after W47 closes (with a real fix or a "won't fix — within noise"
verdict).
