# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Fresh-session start here

**Authoritative remaining-work source**:
[`phase9_close_master.md`](./phase9_close_master.md)
§5.3a (Phase A + Phase B 2-stage iteration discipline).

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`.

**Phase 9 close gate (mac-host)**: **18/18 PASS** (was 17/18
pre-cycle-20). I1 satisfied — no SKIP-WIN64-* emission.

**Test state**: Mac+ubuntu test-all green at last code
commit (9f0517cd); windowsmini has D-167 ~11 directive fails
unrelated to Phase 9 close gate.

Closed cycles 10-25: `git log --grep="cycle 2[0-5]\|A1\|A2\|A4"`.

## Cycles 26-34 progress (see `git log --oneline`)

- 26-28: D-167 spike step 1 COMPLETE.
- 29-30: D-167 wire-up blocked by entry.zig cap →
  D-168 + ADR-0108 drafted.
- 31: stale-comment cleanup.
- 32-34: ADR-0107 + ADR-0108 enrichment passes
  (Alt. D + 9 catalog precedents + 4 hazards).
- 35: user opted per-file cap override → ADR-0099
  amended (Revision 2026-05-24) + ADR-0108 Withdrawn
  + D-168 discharged + entry.zig marker cap=3000.

## Remaining work

### Autonomous-eligible (next session pick from here)

- **D-167 wire-up (single cycle)** — user decision cycle 35
  unblocked entry.zig cap via ADR-0099 per-file `(cap=N)`
  override. Discharge: add `invokeBufWin64Args` helper to
  `entry_buffer_write.zig` + Win64 if-arms in `entry.zig`
  for `callI32i32_i32` / `callI32i64_i32` /
  `callI64i32_i64i64i32` (+ `callI32i32i64_i32` shape 3/3)
  + windowsmini integration verify.

### Still user-gated

- **ADR-0107** Accept → D-079 (ii) c_api byte-buffer globals
  migration (~2-3 cycles, 4 hazards documented in ADR
  Consequences).
- **§9.13 hard gate** — ADR-0105 + ADR-0106 Track D collab
  review + Phase B `[x]` re-flip per
  `phase9_close_master.md` §5.3a Phase B.


## Cold-start procedure

Per `/continue` SKILL.md Resume Steps 0.5 / 0.7 / 0.8.
Current state = bucket-3 stop pending ADR-0107 / ADR-0108
Accept (above).

## See

- ADR-0104 (Phase 9 真スコープ), ADR-0107 (byte-buffer
  globals), ADR-0108 (CATALOG-EXEMPT tier).
- `private/spikes/d167-win64-multi-arg-wrapper/README.md`.
