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

- `<this>` chore(p7): mark §9.7 / 7.8-x86-zero-init-locals close (+10 PASS x86_64)
- `bb8ccb5` feat(p7): §9.7 / 7.8-x86-zero-init-locals — Wasm spec §4.5.3.1 (chunk 14a)
- `9f59ec5` chore(p7): mark §9.7 / 7.8-spill-aware-regalloc chunk 13b close (+62 PASS)
- `aaa2268` feat(p7): §9.7 / 7.8-x86-spill-aware-regalloc — migration (D-045 chunk 13b)

**Phase status**: §9.7 / 7.5 → **[x]** 完了。Phase 7 残 row = 7.8 /
7.9 / 7.10 / 7.11 🔒 / 7.12 / 7.13 🔒。**§9.7 / 7.8** = x86_64 spec
gate — D-045 active。chunks 1-13b 完了。3-host baseline post-chunk-13b:

- Mac aarch64       : **212 / 0 / 20**     (gate green — `test-all` wired)
- OrbStack Linux    : **147 / 66 / 20**    (was 141/72 → +6 via zero-init 14a)
- windowsmini Win   : **139 / 74 / 20**    (was 135/78 → +4 via zero-init 14a)

Cumulative **+72 PASS** since chunk 12 close。次は chunk 14b で
unreachable.0.wasm UnsupportedOp 解明 (~30 fail cascade close 見込み)。
test-all 配線は Mac aarch64 のみ維持。

**Active priority — §9.7 / 7.8 D-045 chunk chain**:

1. ☑ 7.8-x86-ctrl-stack — nop + drop + return
2. ☑ 7.8-x86-unreachable — JMP rel32 + unreach_fixups
3. ☑ 7.8-x86-i64-const — MOVABS r64, imm64
4. ☑ 7.8-x86-i64-alu — i64 ALU + cmp + bitcount + shift + rot (22 ops)
5. ☑ 7.8-x86-i64-mem — i64 load/store family (8 ops)
6. ☑ 7.8-x86-params-i32 — lift params=0 reject; i32-only marshal
7. ☑ 7.8-x86-params-i64fp — i64 / f32 / f64 params + type-aware locals
8. ☑ 7.8-x86-select — select / select_typed (CMOV)
9. ☑ 7.8-x86-mem-grow-size — memory.size + memory.grow + dead_code
10. ☑ 7.8-jit-mem-linux — Linux x86_64 mmap-RWX (+60 PASS)
11. ☑ 7.8-x86-spec-gate — three-host baseline measurement + comment refresh
12. ☑ **7.8-x86-jit-mem-windows** — Windows NtAllocateVirtualMemory RWX (Win +56 PASS)
13. ☑ **7.8-x86-spill-aware-regalloc** — landed across 13a foundation (`e811441`) + 13b migration (`aaa2268`)。Pool shrink R10/R11 → spill_stage_gprs、XMM14/15 → fp_spill_stage_xmms。110 site migration、prologue spill-area allocation、~50 fixture update。+62 PASS across Linux + Windows。
14. **7.8-x86-misc-cleanup** — split:
    - ☑ **14a zero-init-locals** (`bb8ccb5`): Wasm spec §4.5.3.1 — XOR EAX, EAX + MOV [RBP+disp], RAX per local beyond params。+10 PASS (Linux +6、Win +4)。
    - **14b unreachable.0 + FP globals** (NEXT — needs deeper investigation): unreachable.wast 内 `(global $a (mut f32))` を使う `as-global.set-value` 等が含まれる; x86_64 `op_globals.zig` は i32 globals only。dead_code tracking はあるが、unreachable.wast の dead-code パターンと相互作用。エラー出力 (probe) が orb run で suppressed されたため特定難航 → 直接 binary 起動 + 単一 fixture 実行で原因特定すべき。Possibly +30 cascade fails close 見込み。
    - 14c handcrafted_trap "did NOT trap" (2 fails) + func[29] UnsupportedOp。
    - 14d D-029 dst==rhs (now reachable with stage collisions); RBX callee-save in prologue。

> **🔒 Phase 7 → 8 hard gate** が §9.7 / 7.13 に登録済。
> Autonomous /continue loop は 7.13 row を発見した時点で
> ScheduleWakeup を skip して user に surface する規律
> ([`phase8_transition_gate.md`](phase8_transition_gate.md) +
> `.claude/skills/continue/SKILL.md` §"Exception — hard
> human-in-loop transition gates")。Detection は 2 checkpoint
> (Resume Procedure Step 2 + Step 7 re-target) で発火。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`。

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
- **D-045** §9.7 / 7.8 close blocker — x86_64 backend gap (chunks 1-13b closed; chunk 14 misc-cleanup 残)。
- 詳細・staleness check は `.dev/debt.md`。

## Recently closed (full history via `git log --oneline`)

- §9.7 / 7.8-x86-spill-aware-regalloc chunk 13b migration (`aaa2268`):
  abi.zig pool shrink (R10/R11 → spill_stage_gprs; XMM14/15 →
  fp_spill_stage_xmms; SysV pool 6→4、Win64 8→6、XMM 8→6)。emit.zig
  + op_*.zig 110 site migration: `abi.slotToReg(alloc.slots[v])` →
  `gpr.gprLoadSpilled / gprDefSpilled / gprStoreSpilled` (and xmm*
  counterparts)。`spill_base_off: u32` を全 handler signature に
  thread。prologue extend frame for spill area (`spill_base_off =
  locals_bytes + (uses_runtime_ptr ? 8 : 0) + 8`)。shared/compile.zig
  で x86_64 host 専用に `max_reg_slots_gpr = 4 / max_reg_slots_fp = 6`
  を override。~50 stale byte-sequence emit test fixture を更新
  (slot 0: R10 → RBX、REX.B prefix 削除で 1-2 byte 短縮)。
  3-host gate green: Mac 212/0/20 unchanged + 1061/1066 unit pass、
  Linux 109/106/20 → 141/72/20 (+32 PASS)、Win 105/110/20 → 135/78/20
  (+30 PASS)。Total **+62 PASS** x86_64。残 ~75 fail/host: chunk 14
  misc-cleanup (UnsupportedOp + handcrafted_trap "did NOT trap")。
- §9.7 / 7.8-spill-aware-regalloc chunk 13a foundation (`e811441`):
  abi.zig に `spill_stage_gprs = [.r10, .r11]` と `fp_spill_stage_
  xmms = [.xmm14, .xmm15]` 定数を追加。x86_64/gpr.zig (NEW、
  arm64/gpr.zig mirror) で `resolveGpr` / `resolveXmm` (bare
  resolution) + `gprLoadSpilled` / `gprDefSpilled` / `gprStore
  Spilled` + `xmmLoadSpilled` 等の spill-staging trio を提供。
  RBP-disp8 frame addressing (16-slot frame まで)。12 unit test。
  R10/R11 + XMM14/XMM15 は allocatable に残ったまま (chunk 13b で
  除去予定; dual-listing は意図的に inert — caller がまだいない)。
  3-host gate green (Mac 212/0/20、OrbStack + Windows test-all
  unchanged from chunk-12 baseline、additive only)。
- §9.7 / 7.8-x86-jit-mem-windows (`2748971` + `6db570c`): Windows
  x86_64 RWX 配線。`std.os.windows.ntdll.NtAllocateVirtualMemory`
  + `NtFreeVirtualMemory` (zig 0.16 stable は wrapper-with-error-
  union 形を未公開のため低レベル extern 直接呼び)。typed packed
  struct (MEM.ALLOCATE { COMMIT, RESERVE } / MEM.FREE { RELEASE }
  / PAGE { EXECUTE_READWRITE }) でリクエスト。setExecutable /
  setWritable は Linux と同じく no-op (RWX page; x86_64 I/D
  coherent)。Windows spec_assert 49/174/20 → 105/110/20 (+56
  PASS, -64 FAIL)。Linux ↔ Win 4 PASS gap まで詰めた。3-host
  test-all green。`2748971` の初版が 0.16 master の wrapper を
  使ってしまい windowsmini で compile error → `6db570c` で
  ntdll 直接呼びに修正。
- §9.7 / 7.8-x86-spec-gate (f5e5f5b): three-host spec_assert
  baseline triangulation。Mac 212/0/20 / OrbStack 109/106/20 /
  Win 49/174/20。build.zig コメント更新、test-all 配線は Mac
  aarch64 限定維持。
- §9.7 / 7.8-jit-mem-linux (f4eccdc): Linux x86_64 mmap-RWX
  wiring (chunk 10)。OrbStack spec_assert 49/174/20 → 109/106/20
  (+60 PASS)。
- §9.7 / 7.8-x86-mem-grow-size (d138326): memory.size (SHR) +
  memory.grow (-1 skel) + dead_code tracking。
- §9.7 / 7.8-x86-select (af40c41): select / select_typed via
  CMOV (.q form)。
- §9.7 / 7.8-x86-params-i64fp (39142bd): i64 / f32 / f64 params
  + type-aware local.{get,set,tee}。
- §9.7 / 7.8-x86-params-i32 (7f9e9fe): i32-only param marshal
  (SysV / Win64)。
- §9.7 / 7.8-x86-i64-mem (bfedfdf): i64 load/store family (8 ops)。
- §9.7 / 7.8-x86-i64-alu (1e83c41): i64 ALU/cmp/bitcount/shift/rot
  (22 ops)。
- §9.7 / 7.8-x86-i64-const (e46aa7d): MOVABS r64, imm64。
- §9.7 / 7.8-x86-unreachable (98907dd): JMP rel32 + unreach_fixups。
- §9.7 / 7.8-x86-ctrl-stack (56b563b): nop + drop + return。
- §9.7 / 7.5 → [x] (5746f2b): validator wired into compileWasm;
  spec_assert 212/0/20 (= 0 skip-impl + 20 skip-adr)。
