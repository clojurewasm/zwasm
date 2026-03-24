# Deferred Work Checklist

Open items only. Resolved items in git history.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Open Items

- [ ] W41: JIT real-world correctness — 1 remaining bug (Mac 48/50)
  Phase 20 fixed: void-call reloadVreg, written_vregs pre-scan, void self-call result,
  **ARM64 fuel check x0 clobber** (tinygo_sort fixed).

  **Mac remaining (1 JIT DIFF):**
  - `rust_enum_match`: garbage f64 in Triangle coords
    - FP-related JIT bug, needs separate investigation

  **Ubuntu:** TBD (re-test after merge)

- [ ] W42: wasmtime 互換性差異 (JIT 無関係)
  go_math_big — crashes with `environ_sizes_get failed` (same in interp and JIT).
  環境依存: PASS/DIFF が実行環境で変わる。低優先。

## Resolved (summary)

W37: Contiguous v128 storage. W39: Multi-value return JIT (guard removed).
W40: Epoch-based JIT timeout (D131).
W38: SIMD JIT C-compiled perf — Lazy AOT (HOT_THRESHOLD 10→3, back_edge_bailed,
     extract_lane fix, memory_grow64 fix, cross-module instance fix).
W41 (partial): void-call reloadVreg fix — emitCall/emitCallIndirect skips
     reloadVreg(rd) when n_results=0. Fixes rust_compression, rust_serde_json,
     rust_enum_match (+3 Mac, stable Ubuntu). n_results encoded in rs2_field.

W2-W36: See git history. All resolved through Stages 0-47 and Phases 1-19.
