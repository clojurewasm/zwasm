# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: 9 IN-PROGRESS. §9.12-F `[x]`, §9.12-I `[x]`. Remaining
  `[ ]` in §9: §9.13-0 (one blocker: D-170) + §9.13 (hard gate).
- **Phase 9 close gate (mac-host)**: **18/18 PASS**.
- **Last code commit**: `153e31d1` (§9.12-F close); subsequent
  cycles = docs (this commit: debt-row + audit-doc reframe per
  industry audit lesson `2026-05-24-c_api-v128-spec-boundary.md`).

## §9.13-0 close path — corrected per industry audit

**Industry audit findings** (lesson `c_api-v128-spec-boundary`):

- wasm-c-api **spec excludes v128 from `wasm_val_t`** (no
  128-bit slot in union; `include/wasm.h:329-338`).
- wasmtime + wasmer **conform** — v128 globals work internally
  via pointer aliasing but are NEVER exposed via c_api.
- zwasm v2 post-Phase A.4g matches industry pattern (`Runtime.
  globals: []*Value` pointer aliasing, uniform 16-byte cells).

**Reframed scope**:

- **D-170** (now-current, NOT Phase 10+): residual init-order
  bug in `instantiateRuntime` cross-module v128 globals wiring;
  industry confirms the shape is right, just a small fix
  (~50 LOC). c_api `wasm_func_call` uses **interp dispatch**
  (not JIT) so the original "JIT-execute" framing was wrong.
- **D-079 (ii)**: structural side discharged at Phase A.4g;
  retires when D-170 closes.
- **D-171/D-172/D-173**: now-current spec-standard accessor
  completion (scalar globals/tables/memories) — these ARE in
  wasm-c-api spec, NOT v0.1.0 RC blocked. v128 paths permanently
  excluded from c_api (industry-aligned).

## Active task — D-170 implementation (§9.13-0 close)

Per `2026-05-24-c_api-v128-spec-boundary.md` discharge plan:

1. **Step 0 already done** (industry + codebase audits this
   session).
2. **Step 2 Red** — create `test/edge_cases/p9/v128_cross_instance/`:
   - `exporter.wat`: defines v128 global, exports it.
   - `importer.wat`: imports v128 global + exports func that
     reads it via `global.get` and returns the v128.
   - `.expect`: declares the imported lane value.
   - Compile WAT → wasm.
   - Run via `zig build test-edge` — expect trap `Unreachable`.
3. **Step 3 Green** — audit + fix `src/runtime/instance/
   instantiate.zig:681-717` cross-module globals init order;
   ensure source `globals_storage` is populated with v128 bits
   before importer's `Runtime.globals[]` pointer-aliases.
4. **Steps 4-7** — lint + Mac test-all + commit + push +
   ubuntu kick.

After D-170 closes → §9.13-0 [x] → §9.13 hard gate (user
collab) → Phase F (Phase 10 open).

## Cold-start procedure

Per `/continue` SKILL.md Resume Steps 0.5 / 0.7 / 0.8.
Authoritative remaining-work source:
[`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2.

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`
(currently 18/18 PASS).

## See

- [`lessons/2026-05-24-c_api-v128-spec-boundary.md`](./lessons/2026-05-24-c_api-v128-spec-boundary.md)
  — **industry audit, load-bearing for D-079/D-170/D-171-173**
- [`c_api_instance_audit_2026-05-24.md`](./c_api_instance_audit_2026-05-24.md)
  — D-139 audit (reframed per industry lesson)
- ADR-0104 (Phase 9 真スコープ); ADR-0110 Closed (Value=16 widen);
  ADR-0109 Proposed (native Zig API, v128 access path)
- [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2
- `private/spikes/d170-c_api-v128-cross-module/REPORT.md`
  — pre-audit notes (superseded by lesson; kept for lineage)
