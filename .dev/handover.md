# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8 (ARCHIVED-IN-PLACE 2026-05-25; cite-only).
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)。
- **Last commit**: `3889661b` — 10.F-c `wasm_table_grow` (deferred
  from D-172) + 10.F close。ROADMAP §10 / 10.F `[x]` flipped。
  D-171 + D-172 + D-173 全 discharged; D-178 新規 (v0.2 host-side
  `wasm_global_new` 用)。
- **Phase 9 close invariants gate (mac-host)**: **18/18 PASS** 維持。
- **Mac `zig build test`**: 1827/1841 passed (14 skipped); lint clean。
- **File size**: src/api/instance.zig 2908 lines (cap 3000)。

## Active task — 10.Z NEXT (ZirInstr 128-bit 拡張)

10.F 完了。Phase 10 内の次の `[ ]` 行は **10.Z**。

| Row | Scope | Status |
|---|---|---|
| 10.0 | Phase 9→10 transition | `[x]` |
| 10.C9 | Phase 9 close 後始末 | `[x]` |
| 10.J | Native Zig API (ADR-0109) | `[x]` |
| 10.F | c_api scalar accessors (D-171/172/173) | **CLOSED `3889661b`** |
| **10.Z NEXT** | ZirInstr 128-bit 拡張 (`payload: u32 → u64`) per design plan §3.1 / Z.1 chunk。業界全社 (wasmtime/wasmer-LLVM/WAMR/spec ref) full u64 実態に追従; memory64 offset を spec full に carry。Phase 9 corpus 全 host 再 green + 既存 `emit_test_*.zig` byte-identical 確認。Spike なし; 失敗時 chunk revert | `[ ]` |
| 10.D / 10.T / 10.M / 10.R / 10.TC / 10.E / 10.G / 10.P | Phase 10 残行 (design + memory64 + function-references + Tail Call + EH + GC + close) | `[ ]` |

**10.Z exit criterion** (per ROADMAP §10 row):
(a) `ZirInstr.payload: u32 → u64` widen per design plan §3.1 / Z.1 chunk;
(b) wasmtime / wasmer-LLVM / WAMR / spec-ref が full u64 を使う実態に追従;
(c) memory64 offset を spec full に carry;
(d) Phase 9 corpus 全 host (Mac + ubuntu + windowsmini phase boundary) 再 green;
(e) 既存 `emit_test_*.zig` の byte-identical 維持を確認。
Spike なし; 失敗時は chunk revert per ROADMAP §10 row text。

## Phase 10 progress

ROADMAP §10 = 13-row task table。10.0/10.C9/10.J/10.F done (4/13); **10.Z active**;
10.D/10.T/10.M/10.R/10.TC/10.E/10.G/10.P pending。

## Key refs

- **ROADMAP §10**: [`ROADMAP.md`](./ROADMAP.md) lines 1338+
- **Phase 10 design plan**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md) §3.1 (Z.1 ZirInstr 128-bit 拡張)
- **c_api audit (closed)**: [`c_api_instance_audit_2026-05-24.md`](./c_api_instance_audit_2026-05-24.md) §3 A1/B1/B2 (all unblocked at 10.F close)
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
