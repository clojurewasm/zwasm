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
**windowsmini state (2026-05-23, cycle 6 reconcile partial,
HEAD=b23b8678)**: hangs at `fac : assert_exhaustion fac-rec
i64:1073741824`. `runaway`/`mutual-runaway` PASS via probe
(both call + call_indirect paths). 4× `[d-165] kind=4
cumulative_trap_stub_entry_count=1` printed.

## Active chunk — D-165 cycle 7 (i64-shape probe gating)

Phase 9 close gate: I1 = SKIP-WIN64-CALL-INDIRECT-TRAP.
Spike: `private/spikes/d-165-win64-fac-rec-hang/`.

### Hypotheses (per `hypothesis_enumeration.md`)

1. (**RESURRECTED** by cycle 6 evidence) Probe doesn't
   fire for the (i64)→i64 self-recursive shape on Win64.
   Cycle 6 windowsmini reconcile evidence:
   - runaway (() → ()): probe FIRES, count=1, trap clean.
   - mutual-runaway (() → ()): probe FIRES, count=1.
   - call_indirect runaway/mutual-runaway: probe FIRES.
   - fac-rec ((i64) → i64): no `[d-165]` print; process hangs.
   Cycle 1 static analysis + cycle 2 emit byte-shape test
   said byte-level wiring is correct. So either (a) runtime
   conditions are subtly different for i64 shape, OR (b) the
   probe fires but trap_stub itself hangs on i64 trap path.
2. ~~stack_limit = 0~~ — REJECTED (runaway probe fires).
3. ~~Byte-shape regression~~ — REJECTED cycle 2 + 3.
4. ~~Host-side trap-flag check~~ — REJECTED cycle 3.
5. ~~Unwind cost timeout~~ — IMPLAUSIBLE (runaway unwinds
   fine; fac-rec's i64.mul × 0 per frame is fast).

### Cycle 7 plan

Two paths, both targeting H1's "why doesn't probe fire for
i64 shape but does for void shape":

**Path A — bisect input value on windowsmini.** Write a
custom `test/edge_cases/p9/fac-rec/exhaustion-small.{wat,
wasm,expect}` fixture with `assert_exhaustion fac-rec
i64:10000` (~10K depth, probe should fire well before
that on Win64 with 1 MiB headroom). If PASS → input-
dependent (something about 1073741824 specifically).
If HANG → input-independent (i64 shape just doesn't
probe-fire on Win64).

**Path B — disassemble Win64 fac-rec emit.** Cross-build
`zig build -Dtarget=x86_64-windows-gnu` + `llvm-objdump
-d` the fac-rec body bytes. Compare prologue probe
encoding against runaway's. Difference (if any) localises
the bug to a specific encoding asymmetry.

Path B is cheaper (no windowsmini round-trip; static
inspection only). Path A confirms / rejects input-
dependence.

windowsmini reconcile cycle 6 still running in
background; on completion or timeout the result is
recorded but the diagnostic evidence above (4× count=1
on runaway-family) is already conclusive for those paths.

### After D-165 resolved

Remove `SKIP-WIN64-CALL-INDIRECT-TRAP` arm in
`spec_assert_runner_base.zig:3088`; re-run windowsmini.
PASS → D-163 closed; flip I1; gate exits 0; §9.13-0 →
Phase 9 DONE.

## Closed this session (2026-05-23)

- ✅ **R3 / D-162**, **R2**, **R1**, **D-094**, **D-164**.
- ✅ **D-165 cycles 2-3** byte-shape tests; H3, H4 ruled out.
- ✅ **D-165 cycle 4** trap_stub_entry_count diagnostic
  (`8c7f3d48`); size 232 → 240.
- ✅ **D-165 cycle 5** kind=4 stderr surface (`7624019f`).
- ✅ **D-165 cycle 6** windowsmini partial reconcile:
  runaway probe fires (count=1); fac-rec hangs no print.

windowsmini SSH-reachable, autonomous-eligible per ADR-0049.

## See

- `/tmp/win.log` line 17590 (first `[d-165]` evidence).
- `private/spikes/d-165-win64-fac-rec-hang/ANALYSIS_REFINED.md`.
- [`phase9_close_master.md`](./phase9_close_master.md) §5.1.
- ADR-0104 / 0105 / 0106 / 0078.
