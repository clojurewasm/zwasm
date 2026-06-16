# `runI32Export` tests run on the HOST arch — arm64-only emit + arch-agnostic test = x86_64 gate red

**Date**: 2026-06-16
**Context**: D-460 JIT v128-GC bundle (ADR-0192).

`engine/runner_gc_test.zig`'s `runI32Export(alloc, &bytes, "f")` compiles a
module with the **host arch's** JIT backend and runs it. When a new JIT emit
path lands on arm64 first (the Mac dev host) and the test is written
arch-agnostically, it passes locally (`zig build test` on Mac = arm64) but
**fails on the x86_64 ubuntu gate** with `UnsupportedOp` — the x86_64 emit
mirror doesn't exist yet. Same Mac-gate-gap class as
`src-signature-change-misses-test-all-only-runner-callers` and the spill-stage
spec-gate-gap: the local host can't see the other arch's gap.

Concretely: arm64 struct/array v128 GC emit (`f79a3ced`/`41015a9b`) +
arch-agnostic `runI32Export` tests → ubuntu red @e8e69788 (`UnsupportedOp` at
`x86_64/op_simd_int_cmp_lane.zig resolveXmm`, because the shared `vreg_class`
0x7B→v128 makes the SIMD result XMM-class but the x86_64 GC op emit still loads
GPR). The gc spec suite (365/0) stayed green — no spec test exercises a v128 GC
field on JIT — so only the new tests regressed.

## Rule

A `runI32Export` (host-arch JIT) test for an emit path that landed on ONE arch
must be **gated to that arch** until the mirror lands:
`if (builtin.cpu.arch != .aarch64) return skip.blocker(.@"D-NNN");` (ADR-0122:
raw `error.SkipZigTest` is baseline-0 forbidden; the `Blocker` enum variant must
pair with a `.dev/debt.yaml` row, enforced by `check_skip_helpers --gate`).
Better still: do both arches in the same bundle cycle, or cross-compile-check
(`zig build -Dtarget=x86_64-linux-gnu`) before relying on the Mac gate — but the
host-arch runner genuinely RUNS the code, so cross-compile only catches build
breaks, not `UnsupportedOp`. The arch gate is the discipline; ungate when the
mirror emit is committed.
