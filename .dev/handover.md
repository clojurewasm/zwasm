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

- `<this>` chore(p7): §9.7 / 7.9 chunk d-8 close (D-034 spill-aware migration tail)
- `03d9875` feat(p7): §9.7 / 7.9 chunk d-8 — D-034 spill-aware migration tail (35 sites)
- `57e2ef2` feat(p7): §9.7 / 7.9 chunk d-7 — arm64 callee-side AAPCS64 stack-arg lowering
- `e7f4a36` feat(p7): §9.7 / 7.9 chunk d-6 — arm64 large memory offset + control stack 1024

**Phase status**: §9.7 / 7.5 + 7.8 → **[x]**。Phase 7 残 row = 7.9 /
7.10 / 7.11 🔒 / 7.12 / 7.13 🔒。

**§9.7 / 7.9 progress**: chunks a..d-8 closed across 19 commits。
realworld JIT compile-pass: 5/55 → 27/55 (chunk d-6 大躍進)。
3-host gate green。

**Chunk 7.9-d-8 完了** (`03d9875`): D-034 spill-aware migration
tail completion. 35 bare `gpr.resolveGpr`/`resolveFp` sites
across `arm64/{emit,op_alu_float,op_memory,op_convert,op_call,
op_control}.zig` migrated to `gprLoadSpilled`/`fpLoadSpilled`/
`gprDefSpilled`/`fpDefSpilled`/`gprStoreSpilled`/`fpStoreSpilled`
helpers. spill_aware_check 0 violations (BASELINE=0 held).
Compile-pass 27/55 不変 — silent-reject path was contingent
failure mode; remaining 25 COMPILE-OP gaps are genuine op-level
UnsupportedOp / SlotOverflow (>1023 cap on long Go functions
for SlotOverflow; specific op handler gaps for UnsupportedOp).

**Chunk 7.9-d-9 plan** (NEXT、potentially): SlotOverflow root-
cause investigation — 7 Go fixtures hit >1023 simultaneously-
live vregs. 解決策候補:
- liveness analysis range tightening (control-flow-sensitive
  last-use computation で peak live set 縮小)。
- Slot id u32 化 (1023 → 65535) — まだ余地は残る大改造。
- Function-level vreg renumbering / SSA-style 縮約。

**Chunk 7.9-d-10 plan** (alt path): 未対応の specific UnsupportedOp
の調査 + closure。多くは `param=4 results=0` 系の小さな
function — おそらく特定の op (table.*, exception handling, etc.)
が未実装で hit している。

**§9.7 / 7.9 exit criterion** (40+ realworld run-pass) 到達には
caller-side stack-arg marshal + per-fixture timeout + 上記の
SlotOverflow / UnsupportedOp closure の組み合わせが必要。
現実的には Phase 7→8 boundary review (7.13) で「7.9 は infra
完備、本番計測は 7.10/7.11 で実施」と判断する形が妥当。

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
