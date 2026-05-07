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

- `<this>` feat(p7): §9.7 / 7.8-x86-i64-mem — i64 load/store family 8 ops (D-045 chunk 5/9)
- `1e83c41` feat(p7): §9.7 / 7.8-x86-i64-alu — i64 ALU/cmp/shift/bitcount 22 ops (D-045 chunk 4/9)
- `e46aa7d` feat(p7): §9.7 / 7.8-x86-i64-const — MOVABS r64, imm64 (D-045 chunk 3/9)
- `98907dd` feat(p7): §9.7 / 7.8-x86-unreachable — JMP rel32 + unreach_fixups (D-045 chunk 2/9)

**Phase status**: §9.7 / 7.5 → **[x]** 完了 (Mac aarch64 spec_assert
212/0/20)。Phase 7 残 row = 7.8 / 7.9 / 7.10 / 7.11 🔒 / 7.12 /
7.13 🔒。**§9.7 / 7.8** = x86_64 spec gate — D-045 が active (9
chunk plan; chunks 1-5/9 完了)。

**Active priority — §9.7 / 7.8 D-045 chunk chain (x86_64 backend gap closure)**:

1. ☑ **7.8-x86-ctrl-stack** — nop + drop + return
2. ☑ **7.8-x86-unreachable** — JMP rel32 placeholder + unreach_fixups
3. ☑ **7.8-x86-i64-const** — MOVABS r64, imm64
4. ☑ **7.8-x86-i64-alu** — i64 ALU + cmp + bitcount + shift + rot (22 ops)
5. ☑ **7.8-x86-i64-mem** — i64.load{,8_s,8_u,16_s,16_u,32_s,32_u} + i64.store{,8,16,32} (8 ops)
6. **7.8-x86-select** — select / select_typed (CMOV encoder; spill-aware shape)
7. **7.8-x86-mem-grow-size** — memory.size + memory.grow
8. **7.8-x86-params** — lift `params.len > 0` reject (mirror arm64 7.5-multi-arg-entry)
9. **7.8-x86-spec-gate** — re-enable spec_assert in build.zig for x86_64; pass=fail=skip-impl=0

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
| 7.8-x86-ctrl-stack | x86_64 nop + drop + return (3 ops; no new encoders) | DONE (56b563b) |
| 7.8-x86-unreachable | JMP rel32 placeholder + unreach_fixups (-5 disp) | DONE (98907dd) |
| 7.8-x86-i64-const | i64.const handler (MOVABS r64, imm64) | DONE (e46aa7d) |
| 7.8-x86-i64-alu | i64 ALU + cmp + bitcount + shifts + rot (22 ops) | DONE (1e83c41) |
| 7.8-x86-i64-mem | i64 load/store family (8 ops) | DONE (`<this>`) |
| 7.8-x86-select | select / select_typed (CMOV encoder; spill-aware) | **NEXT** |
| 7.8-x86-i64-mem | i64 load/store family (8 ops) | pending |
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
- **D-045** §9.7 / 7.8 close blocker — x86_64 backend gap (9 chunk chain; chunks 1-2 closed)。
- 詳細・staleness check は `.dev/debt.md`。

## Recently closed (full history via `git log --oneline`)

- §9.7 / 7.8-x86-i64-mem (`<this>`): x86_64 op_memory.zig の
  emitMemOp に i64 family 8 ops を追加 (i64.load + load{8,16,32}_
  {s,u} + store + store{8,16,32})。inst.zig に 7 個の R64 mem
  encoder 追加 (encMovR64FromBaseIdx + encStoreR64MemBaseIdx +
  encMov{sx,zx}R64_{8,16}MemBaseIdx + encMovsxdR64_32MemBaseIdx)。
  i64.load32_u は MOV r32 が AMD64 architectural rule で r64 に
  zero-extend するため既存の encMovR32FromBaseIdx を再利用。
  store{8,16,32} は GPR の low N bits を書くため既存の
  encStoreR{8,16,32}MemBaseIdx を再利用。emit.zig の
  uses_runtime_ptr prescan と body switch dispatch も拡張。Mac
  test-all 28/28 steps、1047/1052 (5 skip)、spec_assert 212/0/20
  unchanged。
- §9.7 / 7.8-x86-i64-alu (1e83c41): x86_64 op_alu_int.zig に i64
  family 5 handler を追加 (Binary/Compare/Eqz/Shift/Bitcount —
  計 22 op)。i32 handler の copy + `.d`→`.q` 置換; シグネチャは
  i32 と同形 (positional)。inst.zig の `encF3_0F_R32R` を Width
  対応 `encF3_0F_RR` に汎化、`encLzcntR64` / `encTzcntR64` /
  `encPopcntR64` (REX.W form) を追加。i64 cmp / eqz の result は
  i32 (Wasm bool) なので SETcc + MOVZX は 8/32-bit のまま; CMP /
  TEST のみ .q。i64.shl 等は CL count + SHL/SAR/SHR/ROL/ROR の
  .q form。2 byte-level inline tests (i64.add — REX.W 検証;
  i64.clz — LZCNT R64 form 検証)。Mac unit 1047/1052 (5 skipped)。
- §9.7 / 7.8-x86-i64-const (e46aa7d): x86_64 emit に `i64.const`
  arm を追加。MOVABS r64, imm64 (10 byte) で 64-bit literal を
  直接 dst レジスタに load。ARM64 の 4×16-bit MOVZ/MOVK 連鎖と
  異なり single instruction。Inline test: `i64.const
  0x0CABBA6E0BA66A6E` で 19 byte の関数 body を検証。Mac unit
  1045/1050、test-all spec_assert 212/0/20。
- §9.7 / 7.8-x86-unreachable (98907dd): x86_64 emit に
  `unreachable` op 追加。JMP rel32 (5 byte) placeholder を emit
  + 新規 `unreach_fixups: ArrayList(u32)` に byte_offset を記
  録。end-handler の trap-stub block で bounds_fixups (Jcc 6
  byte; -6 disp) と unreach_fixups (-5 disp) の両方を patch。
  Inline test: unreachable 単独関数で JMP disp32 が trap_byte=11
  に landing することを検証。Mac unit 1044/1049、test-all
  spec_assert 212/0/20。
- §9.7 / 7.8-x86-ctrl-stack (56b563b): x86_64 emit に nop / drop
  / return 3 op を追加。ARM64 fixup-to-shared-epilogue と異なり
  return は marshal + epilogue + RET inline (multi-RET 無害)。
  3 byte-level inline tests。D-041 同時 discharge。
- §9.7 / 7.8 D-044 closed (aa8af01): linker.zig comptime arch
  dispatch (arm64 BL imm26 / x86_64 CALL rel32 per-arch patch
  loop)。x86_64 host で 49/174/20 露出 → D-045。
- §9.7 / 7.5 → [x] (5746f2b): validator wired into compileWasm;
  spec_assert 212/0/20 (= 0 skip-impl + 20 skip-adr)。
