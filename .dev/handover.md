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

- `<this>` chore(p7): §9.7 / 7.9 chunk d-1 close (host-import dispatch infra)
- `95d5ec8` feat(p7): §9.7 / 7.9 chunk d-1 — host-import dispatch infrastructure
- `ceb5b1e` feat(p7): §9.7 / 7.9 chunk c3 — i{32,64}.div_s INT_MIN/-1 overflow trap
- `ca01778` feat(p7): §9.7 / 7.9 chunk c2 — memory.copy + memory.fill

**Phase status**: §9.7 / 7.5 + 7.8 → **[x]**。Phase 7 残 row = 7.9 /
7.10 / 7.11 🔒 / 7.12 / 7.13 🔒。

**§9.7 / 7.9 progress**: chunks a..d-1 closed (a baseline runner;
b import-reject lift; c sign-ext + div/rem; c2 memory.copy/fill =
D-046; c3 div_s INT_MIN/-1 overflow = D-047; d-1 host-dispatch
infrastructure)。3-host gate green: spec_assert 212/0/20 +
realworld 55/0 + wast 1158+72/0 + edge_cases 31/0 across Mac /
OrbStack Linux / windowsmini Win。

**Chunk 7.9-d-1 完了** (`95d5ec8`): JitRuntime tail-extended with
`host_dispatch_base: [*]const usize` + `host_dispatch_count: u32`
(layout 64→80 bytes); per-arch `op_call.zig` import path now
emits `LDR X16, [X19+host_dispatch_off]; LDR X16, [X16, #idx*8];
restore X0; BLR X16` (arm64) / `MOV RAX, [R15+off]; MOV RAX,
[RAX+idx*8]; MOV arg0, R15; CALL RAX` (x86_64); runner.zig
populates dispatch table with `hostDispatchTrap` (sets trap_flag
+ returns 0) preserving the prior trap-on-import-call observable
behaviour。Calling convention: host fn signatures are `fn(rt:
*JitRuntime, ...wasm_args) callconv(.c)` — arg0 is the JitRuntime
ptr (matching JIT-body internal CC).

**Chunk 7.9-d-2 plan** (NEXT, the user-visible payoff): real WASI
handlers replace `hostDispatchTrap` for the realworld corpus:
- proc_exit(rt, code) — `std.process.exit(code)` after setting a
  PROC_EXIT trap variant on rt.trap_flag (M3 / D-022 will widen
  the trap_flag to a typed code; for d-2 use `2` as the
  proc-exit sentinel).
- fd_write(rt, fd, iovs_ptr, iovs_len, nwritten_ptr) —
  iterate iovs (read u32 offset + u32 len from rt.vm_base
  + iovs_ptr), write each chunk to stdout/stderr per fd, store
  total bytes-written to `[rt.vm_base + nwritten_ptr]`.
- clock_time_get(rt, clock_id, precision, time_ptr) — POSIX
  CLOCK_REALTIME / CLOCK_MONOTONIC via std.time.Instant; write
  u64 nanos to `[rt.vm_base + time_ptr]`.
- args_get / args_sizes_get / environ_get / environ_sizes_get
  — read from a process-global WasiContext (set by run_runner_jit
  before invoking the JIT entry).
- random_get — POSIX getentropy.
- After d-2: realworld_run_runner_jit will start showing run-pass
  counts > 0 (at least proc_exit-only fixtures).

**Chunk 7.9-d-3 plan**: linker / runner wires real handlers into
host_dispatch_base by name-matching the import's
`(module, field)` tuple against a registered WASI dispatch
manifest; run_runner_jit invokes the entry function via
entry.callI32NoArgs / callVoidNoArgs and reports run-pass.

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
