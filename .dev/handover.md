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
**windowsmini state (2026-05-23, cycle 6 partial reconcile
HEAD=b23b8678)**: `runaway`/`mutual-runaway` probe PASS
(4× `[d-165] kind=4 count=1`); fac-rec exhaustion hangs at
i64:1073741824 (line 30149 of `/tmp/win.log`).

## Active chunk — D-165 follow-up paths

Phase 9 close gate: I1 = SKIP-WIN64-CALL-INDIRECT-TRAP (D-163
dep on D-165). D-165 now formally registered in
`.dev/debt.md` (Status: blocked-by Win64 i64-shape probe-fire
runtime divergence; two discrimination paths named).
Lesson: `.dev/lessons/2026-05-23-win64-i64-shape-probe-divergence.md`.

### Next-cycle candidates (names + refs only, no predictions)

- **Path A — custom small-input fixture (autonomous,
  medium-effort)**:
  Add `test/spec/wasm-2.0-assert/fac_small/manifest.txt`
  with `assert_exhaustion fac-rec i64:10000` plus the
  generated `.wasm`. Wire the new dir into the spec runner
  manifest discovery (if needed) — refs:
  `test/spec/spec_assert_runner_base.zig` + the
  `test-spec-*` build steps. PASS on windowsmini → input-
  dependence; FAIL → input-independent i64-shape probe
  divergence.
- **Path B — windowsmini lldb-attach (interactive)**:
  SSH into windowsmini, run the runner under lldb (or
  WinDbg), break inside fac-rec exhaustion, dump RSP +
  R15 + `[R15+stack_limit_off]` + `[R15+232]`. Not
  autonomous-friendly; defer to user.
- **D-163 close attempt without D-165 close**: remove
  `SKIP-WIN64-CALL-INDIRECT-TRAP` arm in
  `spec_assert_runner_base.zig:3088`; the call_indirect
  trap directive (`assert_trap as-call_indirect-last` in
  wasm-2.0-assert/call/) precedes fac-rec in the corpus —
  may complete + surface PASS or different failure before
  fac-rec hang. If PASS → D-163 closes independently.
  windowsmini reconcile is the verifier; reuse cycle-6
  /tmp/win.log progression.

### Cycle 7 plan

Path A (small-input fixture) is the highest-value autonomous
move. Write the WAT, hand-assemble or convert to .wasm,
extend the runner's manifest discovery if needed.
Three-host gate via Mac (substrate) + ubuntu (background) +
phase-boundary windowsmini reconcile (verifies the actual
exhaustion behavior).

### After D-165 resolved

Remove `SKIP-WIN64-CALL-INDIRECT-TRAP` arm in
`spec_assert_runner_base.zig:3088`; re-run windowsmini.
PASS → D-163 closed; flip I1; gate exits 0; §9.13-0 →
Phase 9 DONE.

## Closed this session (2026-05-23)

- ✅ **R3 / D-162**, **R2**, **R1**, **D-094**, **D-164**.
- ✅ **D-165 cycles 2-3** byte-shape tests; H3, H4 ruled
  out via unit tests + entry.zig read.
- ✅ **D-165 cycle 4** trap_stub_entry_count diagnostic
  (`8c7f3d48`); JitRuntime size 232 → 240.
- ✅ **D-165 cycle 5** kind=4 stderr surface (`7624019f`).
- ✅ **D-165 cycle 6** windowsmini partial reconcile
  (`1bc4baff`) — probe wiring proven correct for void
  shape; i64 shape diverges.
- ✅ **D-165 cycle 7** — investigation pause; lesson +
  debt row filed (this commit).

windowsmini SSH-reachable, autonomous-eligible per ADR-0049.

## See

- `.dev/debt.md` D-165 (filed this cycle).
- `.dev/lessons/2026-05-23-win64-i64-shape-probe-divergence.md`.
- `/tmp/win.log` line 17590-17764 (`[d-165]` evidence).
- `private/spikes/d-165-win64-fac-rec-hang/ANALYSIS_REFINED.md`.
- ADR-0104 / 0105 / 0106 / 0078.
