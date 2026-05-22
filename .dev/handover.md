# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing discipline:
> [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Fresh-session start here

**Authoritative remaining-work source**:
[`.dev/phase9_close_master.md`](./phase9_close_master.md).

**Mandatory before any §9.x [x] flip**: run

```sh
bash scripts/check_phase9_close_invariants.sh --gate
```

(per `.claude/skills/continue/SKILL.md` Resume Step 5d + ADR-0104
+ `.claude/rules/phase9_close_invariants.md` §"Forbidden edits").

Current gate state: **FAIL 16/18** — Tier 1 work not yet
implemented. `[x]` flips on §9.13-0 / §9.12-F / §9.12-I / §9.13
are §18.3 violations until the gate exits 0.

## Phase 9 = DONE predicate

Per master plan §6 + ADR-0104 D1:

1. `check_phase9_close_invariants.sh --gate` exit 0
2. windowsmini `test-all` green with ZERO `SKIP-WIN64-*` token
3. c_api Wasm-2.0 utilisation tests landed (4 fixtures)
4. Zig facade subset in `src/zwasm.zig` (Runtime / Module /
   Instance / Value) + facade test
5. `wast_runtime_runner` in `test-all`
6. ADR-0105 + ADR-0106 `Status: Accepted` (user collab flip at
   §9.13 hard gate review)
7. §9.13-0 / §9.12-F / §9.12-I re-flipped `[x]` with cited SHAs
8. §9.13 collab gate cleared

## User Tier-0 decision (2026-05-22, sticky)

- D-162 fix: **JIT-prologue stack-probe** (ADR-0105; v1 +
  wasmtime precedent). Supersedes ADR-0103 path-(a)
  `_resetstkoflw` quick fix → REJECTED.
- D-164 fix: **buffer-write entry ABI** OR **uniform implicit-
  SRet** (ADR-0106; user picks at §9.13 gate). Per-shape Win64
  inline-asm thunks REJECTED (band-aid).
- §9.13-0 / §9.12-F / §9.12-I premature `[x]` REVERTED per
  ADR-0104 D2 (audit found drift-amended criteria).

## Tier 1 outstanding work (per master plan §5)

### §5.1 — Win64 codegen redesign (ADR-0105 + ADR-0106)

- [ ] D-162 close — JIT-prologue stack-probe (ADR-0105)
- [ ] D-164 close — multi-result ABI (ADR-0106 path a or b)
- [ ] D-163 close — Win64 call_indirect trap codegen spike
- D-094 closes alongside D-164 (uniform multi-result ABI)
- D-062 mechanical — closes alongside ADR-0105/0106 land

### §5.2 — c_api / Zig API Wasm-2.0 tests + facade

- [ ] `test/api/c_api_wasm2_reftype.zig`
- [ ] `test/api/c_api_wasm2_bulk_traps.zig`
- [ ] `test/api/c_api_mixed_exports.zig`
- [ ] `test/runners/fixtures/cross_module_funcref/`
- [ ] `src/zwasm.zig` facade subset + `test/api/zig_facade_wasm2.zig`
- [ ] `wast_runtime_runner` → `test-all` (`build.zig`)

### §5.4 — Stale ADR / debt cleanup (in-progress)

- [ ] D-007 / D-010 — add explicit Phase target
- [x] skip_cross_module_action / skip_embenchen_emcc_env_imports
      Status: Superseded (Phase A `fca7fe1c`)
- [ ] D-149 SHA backfill — 5 ADR `<backfill>` rows landed at
      `006f0d6d`; remaining placeholders are template + ADR-0104
      self-ref (legitimate)
- [ ] 17 §9.x rows SHA backfill — batch commit at Phase 9 close

## How a fresh /continue cycle handles this state

1. SessionStart hook prints CLAUDE.md + this handover.
2. `/continue` Resume Step 2 finds §9.12-F as the first `[ ]` row.
3. Resume Step 5d runs `check_phase9_close_invariants.sh --gate` →
   FAIL with per-invariant detail.
4. Loop reads master plan §5 for Tier-1 picklist.
5. Picks next work (e.g. §5.1 D-162 stack-probe, §5.2 c_api
   fixture, §5.4 D-007 Phase-target add).
6. Implements + commits + gate re-runs.
7. When gate exits 0, user reviews + flips ADR-0105 + ADR-0106
   to Accepted, then re-flips §9.13-0 / §9.12-F / §9.12-I [x]
   + clears §9.13 hard gate → Phase 9 = DONE.

## Active `now` debts

- D-062: arm64 v128 9th+ stack-arg overflow (mechanical;
  precedent in §9.9 / 9.9-i-1 x86_64 sibling discharge per
  ADR-0104 D3 reframe).

## See

- [`phase9_close_master.md`](./phase9_close_master.md) (§5
  Tier 1; §6 exit predicate; §8 fresh-session entry).
- [ADR-0104](./decisions/0104_phase9_honest_accounting_reframe.md)
  (META reframe; Accepted).
- [ADR-0105](./decisions/0105_jit_prologue_stack_probe.md)
  (D-162 fix; Proposed).
- [ADR-0106](./decisions/0106_multi_result_return_convention.md)
  (D-164 / D-094 fix; Proposed).
- [`.claude/rules/phase9_close_invariants.md`](../.claude/rules/phase9_close_invariants.md)
  (I1-I7 invariants + Forbidden edits).
- [`debt.md`](./debt.md): D-094 / D-062 / D-164 (ADR-0104 reframed).
