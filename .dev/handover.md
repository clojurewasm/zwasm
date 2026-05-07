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

## Current state — Phase 7 / §9.7 / 7.9 IN-PROGRESS

直近 commit (HEAD = `<this>`):

- `<this>` chore(p7): §9.7 / 7.9 chunk d-7 close (arm64 callee stack-arg lowering)
- `57e2ef2` feat(p7): §9.7 / 7.9 chunk d-7 — arm64 callee-side AAPCS64 stack-arg lowering
- `e7f4a36` feat(p7): §9.7 / 7.9 chunk d-6 — arm64 large memory offset + control stack 1024
- `e03015a` feat(p7): §9.7 / 7.9 chunk d-5 — widen regalloc slot id u8→u16 (1023 cap)

**Phase status**: §9.7 / 7.5 + 7.8 → **[x]**。Phase 7 残 row = 7.9 /
7.10 / 7.11 🔒 / 7.12 / 7.13 🔒。

**§9.7 / 7.9 progress**: chunks a..d-7 closed across 17 commits。
realworld JIT compile-pass: 5/55 → 27/55 (chunk d-6 大躍進)。
3-host gate green。

**Chunk 7.9-d-7 完了** (`57e2ef2`): arm64 callee-side AAPCS64
stack-arg lowering. Prologue lifts `params.len > 7` cap; overflow
args (per-class NGRN/NSRN counter) load from `[X29, #(16+8K)]`
into local slot at `[SP, p_idx*8]`. Caller-side stack-arg
marshal **NOT** lifted (would need FP-relative spill addressing
redesign — chunk d-8 scope). Compile-pass count unchanged at
27/55 — the 18 fixtures hit a different post-prologue barrier
(bare `gpr.resolveGpr` on spilled vregs, D-034 spill-aware
migration tail).

**Chunk 7.9-d-8 plan** (NEXT、最大 leverage): D-034 spill-aware
migration tail completion で arm64 `op_alu_float.zig` /
`op_memory.zig` / `emit.zig` の bare `resolveGpr`/`resolveFp`
を `gprLoadSpilled`/`fpLoadSpilled` 経由に移行 (~10 sites)。
これで spilled-vreg fixtures がコンパイル可能 — 18 Rust/TinyGo/
CPP fixtures が解放される見込み。

**Chunk 7.9-d-9 plan** (後続): caller-side stack-arg marshal
(SUB SP / ADD SP + FP-relative spill addressing redesign) +
per-fixture timeout (subprocess + alarm) で run-pass 計測 →
§9.7 / 7.9 exit criterion (40+ run-pass) 到達検証。

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
- **D-031** discharged (chunk d-3, `71f3896`) — runI32Export now
  allocates real memory + populates data segments; `at_limit_load_i32`
  境界 fixture 再追加は post-d-4 (FP/i64 拡張で arg marshaling 追加後)。
- **D-045** §9.7 / 7.8 close blocker — discharged (chunks 1-14e)。
- **D-046** memory.copy/fill — discharged (chunk c2, `ca01778`)。
- **D-047** div_s INT_MIN/-1 overflow trap — discharged (chunk c3, `ceb5b1e`)。
- 詳細・staleness check は `.dev/debt.md`。

## Recently closed (full history via `git log --oneline`)

- §9.7 / 7.8 [x] (`9a48b3a`): x86_64 JIT spec gate exit met on
  all 3 hosts (Mac/Linux/Win 212/0/20)。test-spec-assert を
  test-all 全 host 配線。D-045 closed across chunks 1-14e
  (+163 PASS each on Linux + Win)。
- §9.7 / 7.8-win64-stack-args (`d7236d0`): Win64 ABI args 4+
  on stack at [RBP+16+8*slot]; fixed 5-arg case regression。
- §9.7 / 7.8-win64-fp-params (`95a64bb`): Cc-aware FP arg slot
  tracking; Win64 shares int/FP slots, SysV independent。
- §9.7 / 7.8-unreachable-trap-flag (`50a6f47`): unreachable op を
  uses_runtime_ptr prescan に追加; trap stub の R15 参照が
  正しく初期化される (closes 25 "did NOT trap" fails)。
- §9.7 / 7.8-deadcode-labels (`fb64e3e` + `ea3ef20`): dead_code
  内 if/block/loop で placeholder label push、emitElse の
  if_skip_byte null-guard。中央化 `types.rejectUnsupported`
  helper で diag 整備。+56 PASS。
- §9.7 / 7.8-zero-init-locals (`bb8ccb5`): Wasm spec §4.5.3.1
  zero-init in prologue。+10 PASS。
- §9.7 / 7.8-spill-aware-regalloc (13a `e811441` + 13b
  `aaa2268`): R10/R11 + XMM14/15 を spill stage に reserve、
  110 op handler を gpr.gpr*Spilled / xmm*Spilled 経由に
  migrate。+62 PASS。
- §9.7 / 7.8-jit-mem-windows (`2748971` + `6db570c`):
  NtAllocateVirtualMemory による Windows RWX。+56 PASS。
