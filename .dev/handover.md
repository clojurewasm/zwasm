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

- `<this>` chore(p7): §9.7 / 7.8-x86-spec-gate — three-host spec_assert baseline (Mac 212/0/20, Linux 109/106/20, Win 49/174/20)
- `5a5a423` docs(p7): correct D-045 residual fail diagnosis (SlotOverflow not StackTypeMismatch)
- `f4eccdc` feat(p7): §9.7 / 7.8-jit-mem-linux — Linux x86_64 mmap-RWX (D-045 chunk 10; +60 PASS)
- `d138326` feat(p7): §9.7 / 7.8-x86-mem-grow-size — memory.size + memory.grow + dead_code (D-045 chunk 9)

**Phase status**: §9.7 / 7.5 → **[x]** 完了 (Mac aarch64 spec_assert
212/0/20)。Phase 7 残 row = 7.8 / 7.9 / 7.10 / 7.11 🔒 / 7.12 /
7.13 🔒。**§9.7 / 7.8** = x86_64 spec gate — D-045 が active。
chunks 1-10 完了 + 7.8-x86-spec-gate (chunk 11 — measurement) 完了。
3-host baseline triangulated:

- Mac aarch64       : **212 / 0 / 20**     (gate green — `test-all` wired)
- OrbStack Linux    : **109 / 106 / 20**   (chunks 1-10 反映済)
- windowsmini Win   :  **49 / 174 / 20**   (Linux mmap-RWX 効果未到達)

Linux ↔ Windows 60 PASS の差は chunk 10 (Linux mmap-RWX) そのもの。
**残 106 fail (Linux) の主因 = SlotOverflow** (regalloc pool 6 reg を
5+ params で枯渇 — mirror of arm64 D-036/D-037)。次の主軸 =
(a) **Windows jit_mem** (VirtualAlloc; Win 49→~109 を見込む) +
(b) **x86_64 spill-aware regalloc port** (Linux/Win 共通の 106 fail
を大量 close)。test-all 配線は Mac aarch64 のみ維持 (§9.7 / 7.8 row
close = fail==0 達成時に flip)。

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
11. ☑ **7.8-x86-spec-gate** — three-host baseline measurement + comment refresh
12. **7.8-x86-jit-mem-windows** — Windows VirtualAlloc RWX-region (chunk 12; close Win 49→~109) **NEXT**
13. 7.8-x86-spill-aware-regalloc — mirror arm64 D-036/D-037 (close 106 SlotOverflow)
14. 7.8-x86-misc-cleanup — residual UnsupportedOp + handcrafted_trap "did NOT trap"

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
- **D-045** §9.7 / 7.8 close blocker — x86_64 backend gap (chunks 1-11 closed; chunks 12-14 残)。
- 詳細・staleness check は `.dev/debt.md`。

## Recently closed (full history via `git log --oneline`)

- §9.7 / 7.8-x86-spec-gate (`<this>`): three-host spec_assert
  baseline triangulation。Mac aarch64 212/0/20 (test-all wired)、
  OrbStack Linux 109/106/20 (chunks 1-10 反映)、windowsmini Win
  49/174/20 (Linux mmap 効果未到達)。Linux ↔ Win 60 PASS = chunk
  10 そのもの。残 106 fail (Linux) の主因 SlotOverflow → 次の
  axes = Windows jit_mem + x86_64 spill-aware regalloc。
  build.zig コメントブロックを 3-host 数値で更新、`test-spec-assert`
  step description も "all hosts; test-all Mac-aarch64-only" に
  refine。test-all 配線 Mac 限定維持 (fail==0 達成までは gate を
  赤くしない)。Mac test-all 28/28 + spec_assert 212/0/20 unchanged。
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
