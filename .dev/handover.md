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

**Gate state (mac-host)**: 17/18 passed (I1 = D-163 reopened
cycle 9 — wasm-2.0 corpus scope; SKIP arm restored).
**Win64 surface**: D-162 / D-164 / D-165 closed (cycle 8-9).
D-163 **caller-side bounds-check trap path** crashes on Win64
(5-sec exit 1 on windowsmini); cycle 8 PASS was callee-side
`unreachable` trap in wasm-1.0/unreachable/ — distinct path
(cycle 10 honest-accounting correction, commit `7de1119d`).
Caller-side bounds-check trap has never been verified on Win64.

## Remaining work — Phase 9 真スコープ (host-side library code)

Per ADR-0104 Revision 2026-05-23 + cycle 9 amendment. The 3
debts originally Track-D / v0.1.0 RC-scoped were promoted to
Phase 9 真スコープ ("Wasm 2.0 complete + Zig/C API complete at
Phase 9 release"). The remaining surface touches host-side
library code (`runtime/instance/instantiate.zig` + `Runtime.
globals` shape + `src/api/instance.zig`) — no new JIT codegen.

### Phase A — Mac + ubuntunote implementation (per-chunk gate)

Iterate FAST: per-chunk gate is Mac + ubuntu only. ADR-0049
windowsmini deferral applies; per-chunk windowsmini reconcile
costs 8-15 min/iter and is NOT required for host-side library
code. Phase B (below) bundles the Win64 verification once.

Tackle in this order (autonomous-eligible, ROI-descending):

1. **A1. D-157** — `instantiate.zig` non-func import-type check.
   Exit: 56 `SKIP-NO-LINK-TYPECHECK` → 0 on Mac+ubuntu.
2. **A2. D-139** — c_api Instance audit + coverage tests in
   `src/api/instance.zig`.
3. **A3. D-079 (ii)** — c_api v128 cross-module: extend
   `Runtime.globals` to v128-aware + plumb into instantiate.zig.
4. **A4. D-163 wasm-2.0 (in flight, cycle 11 → 12)** —
   investigate wasm-2.0/call/ caller-side bounds-check trap
   crash on Win64. Cycles 10-11 progress: Mac cross-build path
   verified (cycle 10, `7de1119d`); cycle 11 re-enabled
   `[d-163-jit]` per-function hex dump (`9ceb9d0d`; identical
   shape to D-165 cycle 9 `abf04319`, removed at D-165 close);
   windowsmini isolation dir created (`test/private/d-163/iso/call/`
   copy of wasm-2.0-assert/call/); native build + initial run
   verified runner reaches the SKIP arm (87 passed, 2 NEW
   FAILs surfaced — `type-all-i32-i32` and `as-call-all-operands`
   return garbage 32-bit values, possible D-094/D-164 territory
   regression to triage). Cycle 12 next: rebuild on windowsmini
   with diag commit, capture `[d-163-jit]` lines, identify the
   function containing `as-call_indirect-last` (table-0 OOB
   index 306), decode trap-stub bytes, compare ADD-RSP vs
   prologue SUB-RSP (H1) and check R15 state (H3). Spike:
   `private/spikes/d-163-win64-call-indirect-trap/`. Order:
   can interleave with A1-A3.

### Phase B — windowsmini reconcile (single shot after A1+A2+A3)

After ALL of A1+A2+A3 land [x] with Mac + ubuntu green:

1. **B1**: `bash scripts/run_remote_windows.sh test-all` ONCE.
   Expected: identical PASS counts (+ newly-passing
   assert_unlinkable fixtures); 0 `SKIP-NO-LINK-TYPECHECK`
   emission; new c_api tests PASS on Win64. If a Win64-specific
   issue surfaces, fix in same Phase B window (no need to roll
   back; structural redesign risk is low for host-side library
   code).
2. **B2**: Once B1 green: §9.13-0 / §9.12-F / §9.12-I [x]
   re-flip with cited SHAs + SHA-backfill pass for the
   §9.x rows with bare Status column.

### §9.13 (hard gate) — user touchpoint

ADR-0105 + ADR-0106 `Proposed → Accepted` flip via collab
review per Track D. **User-gated** — sole remaining non-
autonomous step after Phase A + B complete.

## Closed this session (2026-05-23)

- ✅ R3 / D-162, R2, R1, D-094, D-164, D-165.
- ⚠️ D-163 caller-side bounds-check trap — open work (cycle 12
  next). Cycle 11 surfaced 2 NEW Win64 FAILs in wasm-2.0/call/
  (`type-all-i32-i32`, `as-call-all-operands` returning garbage
  i32 — pattern matches D-094/D-164 territory; triage queued).

windowsmini SSH-reachable per ADR-0049. Debug infra:
`debug_jit_auto/SKILL.md` Recipes 15-17.

## See

- [`phase9_close_master.md`](./phase9_close_master.md) §5.3a + §6.
- ADR-0104 Revision 2026-05-23 (scope expansion + 2-phase).
- `.dev/debt.md` D-157 / D-079 / D-139 (`now`, Phase 9 scope).
