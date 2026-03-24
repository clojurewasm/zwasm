# Deferred Work Checklist

Open items only. Resolved items in git history.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Open Items

- [ ] W41: JIT real-world correctness — remaining bugs after void-call fix
  Phase 20 fixed void-call reloadVreg (Mac 41→46, Ubuntu 48). Remaining:

  **Mac failures (4 DIFF):**
  - `tinygo_hello`: TWO bugs:
    1. func#99 (57 regs, 614 IR): type confusion `%!s(int=1)` vs `arg1`
       → high reg_count specific, 34 spill-only vregs
    2. func#154 (12 regs): crash "type assert failed" → unreachable
  - `tinygo_json`: interface type confusion (likely same root cause as func#99)
  - `tinygo_sort`: sort result `false` instead of `true`
  - `rust_file_io`: output diff (needs investigation)

  **Ubuntu failures (2 DIFF):**
  - `tinygo_hello`, `tinygo_json` (same as Mac)

  **Next steps:**
  1. Investigate func#99 (57 regs): largest impact, likely shared with tinygo_json
     - Dump JIT disassembly, compare store values JIT vs interpreter
     - Focus on spill-only vreg handling (>= 23) and scratch register management
  2. Then func#154 (12 regs): separate crash
  3. rust_file_io and tinygo_sort: lower priority

- [ ] W42: wasmtime 互換性差異 (JIT 無関係)
  go_math_big — different output from wasmtime (same in interp and JIT).
  Likely Go runtime behavior differences (env, args, or WASI capability gaps).

## Resolved (summary)

W37: Contiguous v128 storage. W39: Multi-value return JIT (guard removed).
W40: Epoch-based JIT timeout (D131).
W38: SIMD JIT C-compiled perf — Lazy AOT (HOT_THRESHOLD 10→3, back_edge_bailed,
     extract_lane fix, memory_grow64 fix, cross-module instance fix).
W41 (partial): void-call reloadVreg fix — emitCall/emitCallIndirect skips
     reloadVreg(rd) when n_results=0. Fixes rust_compression, rust_serde_json,
     rust_enum_match (+3 Mac, stable Ubuntu). n_results encoded in rs2_field.

W2-W36: See git history. All resolved through Stages 0-47 and Phases 1-19.
