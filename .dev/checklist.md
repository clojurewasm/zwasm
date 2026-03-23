# Deferred Work Checklist

Open items only. Resolved items in git history.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Open Items

- [x] W37: SIMD JIT — contiguous v128 storage (DONE)
  Replaced split storage with contiguous simd_v128[512][2]u64. JIT uses LDR Q/STR Q
  (ARM64) and MOVDQU (x86) for single-instruction 128-bit access.

- [ ] W38: SIMD JIT — compiler-generated code performance
  C compiler patterns (wasm_i16x8_make → 8x i16x8.replace_lane) are much slower
  than hand-written WAT. Scalar gap vs wasmtime on real-world C code is 13-131x
  (vs 1.2-3.8x on microbenchmarks). Investigate: JIT for WASI C runtime overhead,
  replace_lane fusion, and SIMD pattern recognition.

- [ ] W39: Multi-value return JIT support
  Functions with results.len > 1 skip RegIR/JIT entirely (vm.zig line 553).
  wide-arithmetic ops (i64.add128 etc.) and other multi-value functions fall back
  to predecoded IR interpreter. Extend RegIR to handle multi-value returns.

## Resolved (summary)

W40: Resolved — epoch-based JIT timeout (D131). JIT fuel check helper replaces jitSuppressed.

W2-W36: See git history. All resolved through Stages 0-47 and Phases 1-19.
