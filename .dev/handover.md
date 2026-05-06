# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/phase8_transition_gate.md` — 🔒 Phase 7→8 hard gate (load-bearing).
3. `.dev/decisions/0019_x86_64_in_phase7.md` / 0021 / 0023 / 0025 / 0026 / 0027 / 0028 — recent ADRs.
4. `.dev/debt.md` — discharge `Status: now` rows; review `blocked-by` triggers.
5. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain.
6. `.dev/optimisation_log.md` — F-NNN / R-NNN / O-NNN ledger.

## Current state — Phase 7 / §9.7 / 7.8 IN-PROGRESS

直近 commit (HEAD = `<this>`):

- `<this>` feat(p7): §9.7 / 7.8-x86-ctrl-stack — x86_64 nop/drop/return + D-041 cleanup
- `6496d90` fix(p7): §9.7 / 7.8 — revert spec_assert x86_64 wiring; file D-045 (174 FAILs)
- `aa8af01` feat(p7): §9.7 / 7.8 — port linker.zig to comptime arch dispatch (D-044 closed)
- `5746f2b` feat(p7): §9.7 / 7.5-close-d042 — validator wired into compileWasm (**§9.7 / 7.5 → [x]**)

**Phase status**: §9.7 / 7.5 → **[x]** 完了 (Mac aarch64 spec_assert
212/0/20)。Phase 7 残 row = 7.8 / 7.9 / 7.10 / 7.11 🔒 / 7.12 /
7.13 🔒。**§9.7 / 7.8** = x86_64 spec gate — D-045 が active (8
chunk plan; nop/drop/return = chunk 1 完了)。

**Active priority — §9.7 / 7.8 D-045 chunk chain (x86_64 backend gap closure)**:

1. ☑ **7.8-x86-ctrl-stack** — nop + drop + return (3 ops, no new encoders)
2. **7.8-x86-select-unreach** — select / select_typed / unreachable (CMOV + UD2-style trap fixup)
3. **7.8-x86-i64-const** — i64.const handler (encMovR64Imm64)
4. **7.8-x86-i64-alu** — i64 add/sub/mul/and/or/xor/shifts/cmp/eqz/clz/ctz/popcnt/rotl/rotr (~22 ops)
5. **7.8-x86-i64-mem** — i64.load{,8_s,8_u,16_s,16_u,32_s,32_u} + i64.store{,8,16,32} (8 ops)
6. **7.8-x86-mem-grow-size** — memory.size + memory.grow
7. **7.8-x86-params** — lift `params.len > 0` reject (mirror arm64 7.5-multi-arg-entry)
8. **7.8-x86-spec-gate** — re-enable spec_assert in build.zig for x86_64; pass=fail=skip-impl=0

> **🔒 Phase 7 → 8 hard gate** が §9.7 / 7.13 に登録済。
> Autonomous /continue loop は 7.13 row を発見した時点で
> ScheduleWakeup を skip して user に surface する規律
> ([`phase8_transition_gate.md`](phase8_transition_gate.md) +
> `.claude/skills/continue/SKILL.md` §"Exception — hard
> human-in-loop transition gates")。Detection は 2 checkpoint
> (Resume Procedure Step 2 + Step 7 re-target) で発火。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`。

## §9.7 / 7.8 D-045 chunk progress

| # | Chunk | Status |
|---|---|---|
| 7.8-arch-compile | comptime arch dispatch in `compile.zig` (arm64 / x86_64) | DONE (0925134) |
| 7.8-arch-linker | linker.zig comptime arch dispatch + per-arch CALL-patch (D-044 closed) | DONE (aa8af01) |
| 7.8-x86-ctrl-stack | x86_64 nop + drop + return (3 ops; no new encoders) | DONE (`<this>`) |
| 7.8-x86-select-unreach | select / select_typed / unreachable (CMOV + UD2-style trap fixup) | **NEXT** |
| 7.8-x86-i64-const | i64.const handler (encMovR64Imm64 encoder) | pending |
| 7.8-x86-i64-alu | i64 add/sub/mul/and/or/xor/shifts/cmp/eqz/clz/ctz/popcnt/rotl/rotr (~22 ops) | pending |
| 7.8-x86-i64-mem | i64 load/store family (8 ops; .q-width emitMemOp) | pending |
| 7.8-x86-mem-grow-size | memory.size + memory.grow | pending |
| 7.8-x86-params | lift `params.len > 0` reject; SysV/Win64 param marshalling | pending |
| 7.8-x86-spec-gate | re-enable spec_assert wiring; pass=fail=skip-impl=0 on Linux + Windows | pending |

## ADR-0025 (Zig host API) implementation chain

Phase A (design + ROADMAP §10 sync) DONE。Phase B-1〜B-5 (thin
facade + TypedFunc + WasiConfig + ImportEntry + examples) +
Phase D (migration doc) は post-7.8 着手予定。詳細は
`.dev/decisions/0025_zig_library_surface.md` Revision history。

## Open structural debt (pointers)

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後再評価。
- **D-026** env-stub host-func wiring (cross-module dispatch)。
- **D-029** x86_64 emitI32Binary `dst==rhs` reject — regalloc port 後に discharge。
- **D-031** runner runI32Export FP/i64 拡張 — JitRuntime memory init 後に at_limit 境界 fixture を再追加。
- **D-045** §9.7 / 7.8 close blocker — x86_64 backend gap (8 chunk chain; chunk 1 closed)。
- 詳細・staleness check は `.dev/debt.md`。

## Recently closed (full history via `git log --oneline`)

- §9.7 / 7.8-x86-ctrl-stack (`<this>`): x86_64 emit に nop / drop /
  return 3 op を追加。nop は無 body byte (Wasm spec §4.4.6.2)、drop
  は vreg pop のみ無 byte (§4.4.4)、return は MOV EAX/RAX/MOVAPS
  marshal + epilogue + RET inline (ARM64 と異なり fixup 機構不要; 複
  数 RET は無害)。3 byte-level inline tests。Mac test-all spec_assert
  212/0/20 unchanged。D-041 row も discharge (4 buckets 全完了)。
- §9.7 / 7.8 D-044 closed (aa8af01): linker.zig が `comptime switch
  (cpu.arch)` で arm64.{emit,inst} / x86_64.{emit,inst} を import;
  ARM64 BL imm26 と x86_64 CALL rel32 の patch loop も per-arch。
  Mac aarch64 spec_assert 212/0/20。x86_64 host で 49/174/20 が露
  出 → D-045 として記録。
- §9.7 / 7.8 D-045 filed (6496d90): build.zig の x86_64 spec_assert
  wiring を revert (`is_mac_aarch64` guard 復元); D-045 を active
  debt として登録。手動 OrbStack 走行で per-fixture 失敗を triage 可
  能 (chunk plan は debt entry 参照)。
- §9.7 / 7.5 → [x] (5746f2b): validator が compileWasm 内で発火
  (decode optional global/table/data/element sections + per-func
  validateFunction)。spec_assert 185/0/47 → 212/0/20 (= 0 skip-
  impl + 20 skip-adr-text-format)。D-042 / D-043 closed。
