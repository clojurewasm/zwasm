# A 12-month Win64 heisenbug WAS the always-on debug dump — A/B-disable instrumentation before chasing deeper layers

**Date**: 2026-06-07
**Tags**: D-279, Win64 heisenbug, debug instrumentation, d-163-jit dump, std.debug.print flood, exit-3 abort, stale always-on dump, A/B isolation, VEH diagnostics missed it, instrumentation-is-the-bug, hypothesis-layer-error, D-163 closed but dump left on

## Observation

D-279 — an intermittent Win64-only `test-all` crash (process exit-3, abort-class) — was
chased for 12+ months across SIX hypotheses (H1 SIMD-spill alignment, H2 FP-walk/X29,
H3 1 MB stack overflow, H4 not-SIMD, H5 non-exception abort, H6 unarmed-fault path). A
VEH diagnostic was added for each; **none ever fired**. The actual cause: the
`spec_assert_runner_base.zig` per-defined-function JIT hex dump (`[d-163-jit]`,
`if (true)` always-on, `std.debug.print` of every compiled function's full byte stream).
Its origin debt D-163 had long CLOSED, but the dump was never reverted (its own comment
said "revert when D-163 closes"). On Win64 the enormous stdout volume aborts the process
(exit-3) under load — **the crash was never in wasm codegen/execution at all**, which is
exactly why every execution-path VEH instrument was blind to it.

Decisive A/B (same source, one commit apart): dump ON @`fac174b5` → threads-assert AND
wasm-2-0-assert BOTH exit-3; dump env-gated OFF @`d9d525a4` → the SAME two exes run GREEN,
`[run_remote_windows] OK`, exit-3 count 0. Fix = env-gate the dump (`ZWASM_DUMP_JIT`,
off by default), which also removed the noise it injected into every test-all log.

## Rules

1. **Suspect your own instrumentation.** A debug dump / log / counter that is ALWAYS-ON
   is part of the system under test — it can BE the heisenbug (volume, timing, buffer,
   re-entrancy), especially on the platform with the smallest stdio/stack budget (Win64).
2. **A/B-disable instrumentation EARLY**, before enumerating deep hypotheses. One
   dump-off run would have settled this in cycle 1, not cycle N. If "the only lead" is a
   debug print, the debug print is a suspect, not just a witness.
3. **Zero diagnostics firing is itself a signal** — it means the fault is OUTSIDE every
   layer you instrumented (here: not in execution at all). Don't add a 7th
   execution-path probe; question the layer.
4. **Revert stale instrumentation when its debt closes.** An `if (true)` "temporary"
   dump tied to a now-closed `D-NNN` is a latent footgun; grep closed-debt markers in
   test/diagnostic scaffolding periodically. Cf. `fixture-self-verify-false-lead` (the
   other D-279 false lead) — both were instrumentation/expectation artifacts, not zwasm.
