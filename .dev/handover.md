# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Fresh-session start here

**Authoritative remaining-work source**:
[`phase9_close_master.md`](./phase9_close_master.md).

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`.

**Gate state (mac-host)**: 17/18 passed.
**windowsmini state (2026-05-23 `/tmp/win.log`)**:
`assert_exhaustion fac-rec i64:1073741824` hangs after
`fac : assert_return fac-ssa` (line ~28527).

## Active chunk — D-165 cycle 3 (Win64 fac-rec hang spike)

Phase 9 close gate: I1 = SKIP-WIN64-CALL-INDIRECT-TRAP.
Blocking sequence: **D-165 → D-163 → §9.13-0 → Phase 9 DONE**.

Spike: `private/spikes/d-165-win64-fac-rec-hang/`
(SURVEY.md = cycle-1 subagent; ANALYSIS_REFINED.md =
cycle-1 static-analysis corrections).

### Hypotheses (per `hypothesis_enumeration.md`)

1. ~~Probe doesn't fire (frame_bytes=0)~~ — REJECTED cycle 1
   via `emit_setup.zig:104-111` read; on Win64 `frame_bytes
   ≥ 56` (shadow space).
2. ~~`stack_limit = 0` globally~~ — REJECTED cycle 1 by
   analogy: runaway PASSes on cycle 8 with the same runner.
3. ~~Byte-shape regression in i64-result emit~~ — REJECTED
   cycle 2 (`03715de1`). New unit test `compile: self-
   recursive (i64)->i64 — probe + i64-result marshal (D-165
   cycle 2)` asserts JBE-patched + SUB RSP > 0 + REX.W MOV
   r64,RAX post-CALL marshal. PASS on Mac SysV + Win64 cross-
   build clean. The minimal `local.get 0; call 0; end` shape
   emits the structurally-correct prologue + marshal.
4. (active, **leading**) Trap-flag propagation stall for
   single-i64-result Win64. Signature: `rt.trap_flag = 1`
   set but runner's post-call check reads i64 result before
   checking the flag, OR the wasm/jit entry shim's
   trap-detection branch for single-i64-result on Win64 is
   broken. Probe (cycle 3): read the wasm/jit entry shim for
   single-i64-result Win64 path —
   `src/engine/codegen/shared/entry.zig` +
   `entry_buffer_write.zig`; grep for trap_flag usage on the
   i64 return path.
5. (active) Cumulative unwind cost ≥ runner timeout.
   Signature: 13K-frame unwind crosses commit regions
   per-frame; external wall-clock timeout fires, not a true
   infinite loop. Probe: instrument unwind frame count OR
   bisect fac-rec input on windowsmini.

### Cycle 3 plan

1. Read entry-shim layer to map the i64-result return path
   on Win64. Identify where `rt.trap_flag` is checked after
   a Wasm call returns.
2. Compare with the `()->()` path that works for runaway.
3. If a missing trap_flag check is found → fix it; add a
   unit test asserting the entry shim observes trap_flag for
   single-i64-result on both Cc.
4. If the check is present → pivot to H5 (instrument runner
   to surface frame-unwind cost OR bisect fac-rec input on
   windowsmini).

### After D-165 resolved

Remove `SKIP-WIN64-CALL-INDIRECT-TRAP` arm in
`spec_assert_runner_base.zig:3088`, re-run windowsmini,
observe `call: assert_trap as-call_indirect-last ()`. If
PASS → D-163 closed by broader trap-path repair; flip I1
to OK; gate exits 0; flip §9.13-0 [x] → Phase 9 DONE.

## Closed this session (2026-05-23)

- ✅ **R3 / D-162** Win64 stack-probe headroom
  (`1e2d716d`). Lesson:
  `.dev/lessons/2026-05-23-win64-stack-probe-headroom.md`.
- ✅ **R2** Win64 `marshalReturnRegs` cap=1→2 (`aac986d9`).
- ✅ **R1** Win64 wrapper 2-XMM + `callF64f64NoArgs`
  (`73bcf80f`).
- ✅ **D-165 cycle 2** byte-shape unit test (`03715de1`).

windowsmini SSH-reachable, autonomous-eligible per ADR-0049.

## See

- `/tmp/win.log` (windowsmini test-all; 17703 lines).
- `private/spikes/d-165-win64-fac-rec-hang/ANALYSIS_REFINED.md`.
- [`phase9_close_master.md`](./phase9_close_master.md) §5.1.
- ADR-0104 / 0105 / 0106 / 0078.
