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

1. **A1. D-157 CLOSED** (cycle 15-16; SKIP 56→0 wasm-2.0).
2. **A2. D-139 CLOSED** (cycle 17; c_api Instance audit tests).
3. **D-166 + A4 D-163 CLOSED** (cycle 19-20, `e5042b3e`).
   Shared root cause: `scratch_typeidxs` not reset between
   modules. Phase 9 close gate: 17/18 → **18/18 PASS**.
4. **Win64 2-i32-result fix** (`a40bc6d6`). wasm-2.0/call/
   Win64 isolated = 90 passed 0 failed 0 SKIPs.
5. **ADR-0107 Proposed** (`6b3c6705`). Byte-buffer
   `Runtime.globals` migration for D-079 (ii). User-gated.
6. **Cycle 21-24 wrapper_thunk extension attempt REVERTED**
   (`9a11b8d0`+) — extension to 1-3-arg multi-result wrappers
   compiled OK on Mac + ubuntu but regressed simd_assert on
   windowsmini (process death after compile of simd_bitwise.17
   func10). Filed as D-167 for safer re-attempt.

**Verified test state**:
- Mac aarch64 `zig build test` / `test-all`: green.
- ubuntu test-all: green (25457 passed wasm-2.0-assert).
- windowsmini test-all: simd_assert green (13351/0 fail);
  spec_assert_non_simd has D-167 1+arg multi-result fails
  (~10-11 directives across `break-br_if-num-num` /
  `break-br_table-num-num` / `break-br_table-nested-num-num` /
  `add64_u_with_carry`).

**Remaining work**:
- **D-167** — Win64 1+arg multi-result wrapper extension. Cycle
  21-24 attempt revealed wrapper extension needs spike-first
  discipline. Recommend `private/spikes/d167-*` before
  re-attempting.
- **A3 D-079 ii** — blocked-by: ADR-0107 Accept (user-gated).
- **§9.13 hard gate** — ADR-0105 + ADR-0106 Accepted flip
  (user touchpoint; Track D collab).
2. **A2. D-139** — c_api Instance audit + coverage tests in
   `src/api/instance.zig`.
3. **A3. D-079 (ii)** — c_api v128 cross-module: extend
   `Runtime.globals` to v128-aware + plumb into instantiate.zig.
4. **A4. D-163 wasm-2.0 (in flight, cycle 14 → 15)** —
   investigate wasm-2.0/call/ caller-side bounds-check trap
   crash on Win64. Cycle 12: static JIT layout verified
   (H1/H3/H4 REJECTED). Cycle 13: silent process death
   captured. Cycle 14 (`8f59b8bb`): POST-print probe in
   `invokeAndCheck` confirmed `@call(f, ...)` does NOT
   return for `as-call_indirect-last` → **entry helper
   exonerated**; death is in JIT body or bounds-check
   trap-stub RET path. Notable asymmetry: stack-overflow
   trap stub (kind=4, no `ADD RSP`) returns cleanly on
   Win64; bounds-check stub (with `ADD RSP, 0x58`) does
   NOT. The `ADD RSP` is the prime suspect (interaction
   with Win64 SEH unwinder / CET shadow stack).
   See lessons `2026-05-23-d163-static-jit-layout-verified.md`,
   `2026-05-23-d163-entry-helper-exonerated.md`.
   Cycle 15 next: codegen-side sentinel write at the START
   of the bounds-check trap stub
   (`op_control.zig::emitEndInter`). If after crash sentinel
   visible in JitRuntime state → stub IS entered, death is
   post-stub-entry (RET path / RSP corruption / SEH). If
   absent → JAE took wrong target. Companion: 2 NEW Win64
   FAILs (`type-all-i32-i32`, `as-call-all-operands`) still
   queued. Order: can interleave with A1-A3.

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
