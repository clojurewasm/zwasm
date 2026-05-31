# Spec-corpus JIT "fails" were unwired shapes, not stale cross-directive state

2026-05-31. §1 (ADR-0128) JIT mode reported `assert_return pass=43 fail=96
skip=1156`. The handover bundle's planned next chunk was "shared-runtime
JIT-execute" — share the interp run's accumulated state into the JIT path so
state-dependent no-arg-i32 funcs stop being false-RED. A `--fail-detail`
sweep (Mac aarch64) **falsified that premise before any bridge was built**.

## The 96 fails, by stage

| err | n | stage |
|---|---|---|
| `MultipleMemories` | 66 | compile (`compile.zig:105`) |
| `UnsupportedOp` | 11 | compile (br_on_null, return_call_indirect, …) |
| `Trap` | 8 | **execution** (6 memory.grow64-reject, 1 EH, 1 GC) |
| `InvalidFuncIndex`/`InvalidGlobalInitExpr`/`StackTypeMismatch`/`ElemSegmentTypeMismatch` | 10 | setup/validate |
| value mismatch (`JITval`) | 1 | execution (ref.func is_null) |

**87 of 96 never executed** (compile/setup reject). State can only matter if
a func executes and reads a prior directive's mutation; 87 can't, and the 9
that ran don't depend on prior directives. A shared-runtime bridge flips
**0 of 96**. (It's also not cheap: `JitRuntime` is extern with contiguous
`globals_base: [*]Value`, layout-incompatible with interp `Runtime`'s
`globals: []*Value` pointer-per-entry — but moot, since it buys nothing.)

## Shipped instead

`jitErrorIsUnwiredShape`: compile/setup rejections → `jit_return_skip`
(enumerated under `--fail-detail`, same class as args/i64/fp eligibility
skips); `error.Trap` + any unanticipated error stay `fail`. Result: **fail
96 → 9**, where 9 = "JIT executed and got the wrong observable result" — the
clean both-backends RED signal the bundle wanted, via classification not
state-sharing.

## Takeaways

- A 5-min `--fail-detail` sweep beat a multi-cycle architectural bridge.
  Measure the failure *taxonomy* before building the mechanism a handover
  narrative assumed.
- "fail" in a backend-comparison runner must mean *executed-and-wrong*;
  bucket "could-not-attempt" as enumerated skip, or the RED signal lies.
- Live §1 lever now = widen the JIT-runnable *shape* set (general
  arg/result dispatcher = 1243 skips; multi-memory setup = 66), not
  state-sharing. Unemitted ops (11) tracked by D-198 / tail-call /
  ADR-0127 PHASE C. See the handover `## Active bundle`.
