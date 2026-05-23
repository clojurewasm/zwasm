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

## Active chunk — D-165 cycle 5 (windowsmini reconcile + observe)

Phase 9 close gate: I1 = SKIP-WIN64-CALL-INDIRECT-TRAP.
Blocking sequence: **D-165 → D-163 → §9.13-0 → Phase 9 DONE**.

Spike: `private/spikes/d-165-win64-fac-rec-hang/`.

### Hypotheses (per `hypothesis_enumeration.md`)

1. ~~Probe doesn't fire (frame_bytes=0)~~ — REJECTED cycle 1.
2. ~~`stack_limit = 0` globally~~ — REJECTED cycle 1.
3. ~~Byte-shape regression in i64-result emit~~ — REJECTED
   cycle 2 + 3 via emit unit tests.
4. ~~Trap-flag propagation stall (host-side)~~ — REJECTED
   cycle 3 via `entry.zig:162-175` `invokeAndCheck` read.
5. (active, **leading**) Probe-fire interaction with Win64
   commit-region geometry. Permanent diagnostic landed cycle 4
   (`cea1cb92`): `JitRuntime.trap_stub_entry_count` (u32 at
   offset 232) increments at the start of every x86_64
   stack-overflow trap stub firing. Discrimination:
   - count > 0, flag = 1 → probe fires + flag OK → unwind /
     commit-region.
   - count > 0, flag = 0 → stub fires but flag write lost.
   - count = 0 after hang → probe never fires (revisit H1).

### Cycle 5 plan (runtime evidence)

The cycle-4 diagnostic is now in the JIT. Cycle 5 reconciles on
windowsmini and surfaces the counter:

1. `bash scripts/run_remote_windows.sh test-all > /tmp/win.log
   2>&1` against current origin HEAD (`cea1cb92` + handover).
2. After test-all completes (or aborts on hang), inspect:
   - For each `assert_exhaustion ... passed/failed` directive,
     correlate with the post-call counter snapshot (need a
     small runner-side probe to surface `rt.trap_stub_entry_count`
     after Error.Trap — add as cycle-5 sub-step if not yet
     present).
3. If reconcile times out on fac-rec exhaustion → SSH into
   windowsmini and attach lldb to surface counter state at
   the hang point. windowsmini SSH per ADR-0049.

Mac-host build classifies as `substrate` (cycle 4 already
verified PASS + Win64 cross-build clean). Cycle 5 is reconcile-
driven; if the runner needs a code change to surface the counter
on Trap, that lands as a small runner edit in the same cycle.

### After D-165 resolved

Remove `SKIP-WIN64-CALL-INDIRECT-TRAP` arm in
`spec_assert_runner_base.zig:3088`, re-run windowsmini; if PASS
→ D-163 closed; flip I1; gate exits 0; flip §9.13-0 → Phase 9
DONE.

## Closed this session (2026-05-23)

- ✅ **R3 / D-162**, **R2**, **R1**, **D-094**, **D-164**.
- ✅ **D-165 cycle 2** byte-shape test (`0fe14a5f`).
- ✅ **D-165 cycle 3** arg-marshal extension (`a5f7236b`) +
  H4 ruled out.
- ✅ **D-165 cycle 4** `trap_stub_entry_count` diagnostic
  (`cea1cb92`); JitRuntime size 232 → 240.

windowsmini SSH-reachable, autonomous-eligible per ADR-0049.

## See

- `/tmp/win.log` (windowsmini test-all; 17703 lines).
- `private/spikes/d-165-win64-fac-rec-hang/ANALYSIS_REFINED.md`.
- [`phase9_close_master.md`](./phase9_close_master.md) §5.1.
- ADR-0104 / 0105 / 0106 / 0078.
