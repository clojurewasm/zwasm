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

## Current state — Phase 7 / §9.7 / 7.10 IN-PROGRESS

直近 commit (HEAD = `43e8336`):

- `43e8336` feat(p7): §9.7 / 7.10 chunk k — x86_64 gpr.zig spill-region disp32 widening (D-048 close)
- `6b4bd2b` chore(p7): mark §9.7 / 7.10 chunk j close
- `6bab26e` feat(p7): §9.7 / 7.10 chunk j — x86_64 SysV callee param-arg-overflow READ
- `9cfd3aa` chore(p7): mark §9.7 / 7.10 chunk i close

**Phase status**: §9.7 / 7.5 + 7.8 + **7.9 [x]**。Phase 7 残 row = 7.10 /
7.11 🔒 / 7.12 / 7.13 🔒。

**§9.7 / 7.10 progress** (Linux x86_64 realworld_run_jit
**45/55 compile-pass** post-k, **0/55 run-pass** still):
- chunks a..k closed: D-029 ALU/FP、op_call 全 valtype、caller+
  callee stack-args、localDisp + RBP/RSP/spill disp32、br/br_if
  function-depth、op_memory u32 offset。D-048 (spill disp32)
  が大ジャンプ — compile-pass 0 → 45/55 (well past 40+ threshold)。
- post-k JIT compile remainder: 7 compile-op + 3 compile-val
  (= 10/55 still failing pre-runtime)。
- **run-stage SEGV blocker** (NEW): `ZWASM_JIT_RUN=1` で全 fixture
  segfault at 0x0 + recursive panic。compile 成功 → execution 失敗。
  原因候補: trap stub setup, host import wiring, WASI host,
  entry shim runtime data structure。debug 必要。

**§9.7 / 7.10 chain plan** (NEXT 群):
- **7.10-l (NEXT)**: JIT run-stage segfault investigation。
  smallest-first: 1 fixture (e.g. `c_simple_add` if available) を
  isolated で動かして MAP/JIT entry を debug。Possible causes:
  - JitRuntime initialization gap (vm_base / mem_limit not set)
  - Host import dispatch unwired (D-026)
  - trap stub address calculation error
  - prologue clobber of caller-saved regs the entry shim assumed
- 7.10-br_table-fdepth (deferred): return-trampoline pattern。
- 7.10-regalloc-port (deferred to Phase 8): D-029。

**Pre-existing infra observation (out-of-scope)**:
`.githooks/pre_commit` (snake_case) は Git の `pre-commit`
(kebab-case) hook 規約に合わないため fire しない。よって
gate_commit.sh の `zig fmt --check src/` (38 files drift
中、主に `@"opname"` → bare name の Zig 0.16 fmt rule 由来)
+ `file_size_check --gate` (3 files が hard-cap 2000 超過、
全 pre-existing) + `zig build lint` (4 warnings: 2 exhaustive-
switch on x86_64/emit.zig param-marshal + 2 unused `abi` import
in op_convert/op_control) も実行されていない。直近 10+ commit
すべてこの状態で land 済 → 既存 infra bug。修復は専用 chore
commit で別途 (gate を有効化するなら大規模 fmt 適用 + ファイル
分割 ADR + lint warn 修正が必要)。

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
- **D-029** x86_64 emitI32Binary `dst==rhs` reject — chunks b/d で
  parallel-move 経路は完備、underlying reject 自体は regalloc port
  後に最終 discharge。
- 詳細・staleness check は `.dev/debt.md`。

## Recently closed (canonical history via `git log --oneline --grep="§9.7"`)

- §9.7 / 7.10 chunks a..k closed (commits `a8777ac` `4fb4fcb`
  `68dd2dc` `da5db53` `6c523fa` `f47db77` `093906f` `6ff23a0`
  `6bab26e` `43e8336`)。compile-pass 0 → 45/55 (D-048 spill-
  disp32 が大寄与)。run-stage segfault が次の壁。
- §9.7 / 7.9 [x] — arm64 realworld JIT 52/55 compile-pass。
