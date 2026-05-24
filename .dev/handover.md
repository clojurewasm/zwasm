# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: 9 IN-PROGRESS. Phase B.3 (D-139) in flight.
- **Last commit**: `64c2378c` — D-139 audit doc + gap C2
  (multi-store isolation) test landed.
- **Phase 9 close gate (mac-host)**: **18/18 PASS**.
- **Test state at `64c2378c`**: Mac `zig build test` GREEN; lint
  GREEN. ubuntu kick for `fe666b0f` (D-167 close) verified
  GREEN at Step 0.7. windowsmini at `7680cbd2`: 0 FAIL.
- **D-028 heisenbug streak**: 1/5 silent.

## Active task — Phase B.3 D-139 cont. (gap C3 store_delete order)

Per [`c_api_instance_audit_2026-05-24.md`](./c_api_instance_audit_2026-05-24.md) §4 discharge plan.
Audit + gaps C2 (`64c2378c`) + A2 (`38e31003`) + B3 (`034878b6`)
closed. Remaining:

- **NEXT** — Gap C3: `wasm_store_delete` while live instance
  exists (cleanup order safety).
- **THEN** — Gap C4 (engine reuse across stores) + Gap A3
  (partial-init trap zombie).
- **THEN** — D-139 close commit (`chore(debt): close D-139 ...`).

Note: Gap A2's audit wording referenced a 3-instance "diamond";
the chunk landed the simpler multi-consumer-of-A pattern (two
B-instances both holding funcrefs into A). Full transitive
C→A→B chain deferred to D-075 v0.1.0 RC if needed.

3 new debts filed at C2 (blocked on ADR-0025 v0.1.0 RC c_api
accessor exports): D-171 (A1 global zombie), D-172 (B1 table
alias), D-173 (B2 memory alias). Documented in audit §3 / §4.

After Phase B.3 fully closes → §9.13-0 row exit predicate
evaluation, then Phase C/D/E/F per
[`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2.

## Cold-start procedure

Per `/continue` SKILL.md Resume Steps 0.5 / 0.7 / 0.8.
Authoritative remaining-work source:
[`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2.

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`
(currently 18/18 PASS).

## See

- ADR-0104 (Phase 9 真スコープ)
- ADR-0110 — Value widen 8→16, Closed (implemented) at `9204847a`
- D-167 discharged 2026-05-24 at `4339eb02` (windowsmini-verified at `7680cbd2`)
- D-079 (ii) / D-170 — c_api wasm_instance_new v128 globals JIT
  wiring; blocked-by Phase 10+ alongside ADR-0109
- [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2
  Phase B/C/D/E/F sequence
- §9.13-V closed-cohort cycles 38-56: `git log --grep="§9.13-V"`
