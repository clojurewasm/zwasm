# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.8 task table — Phase 8 active.
3. `.dev/debt.md` — D-054 + D-055 `blocked-by:` chain; 9 other rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain.
5. `.dev/decisions/0034_jit_execution_sentinel.md` (8a.2 design + Revision history).
6. `.dev/decisions/0033_pass_trace_extension.md` (8a.1 design).
7. `.dev/decisions/0028_diagnostic_m3_trace_ringbuffer.md` (M3 ringbuffer parent ADR).

## Current state — Phase 8 / §9.8a / 8a.4 (ZWASM_DIAG env var)

§9.8a / 8a.1 + 8a.2 + 8a.3 closed. The three observability /
infra rails are in place:
- 8a.1: per-pass diagnostic (ringbuffer + ZirFunc slot)
- 8a.2: JIT-execution sentinel (ARM64 native; x86_64 deferred D-055)
- 8a.3: bench-delta-per-commit (scripts/run_bench.sh --diff +
  scripts/record_bench_delta.sh)

Step 5b's trigger condition `8a.1 + 8a.2 + 8a.3 all [x]` is now
satisfied — Phase 8b chunks will be bench-delta-gated.

直近 commits (latest at top):

- (this commit) chore(p8): mark §9.8a / 8a.3 [x]; retarget at
  8a.4 ZWASM_DIAG env var.
- `d0a364b` feat(p8): §9.8a / 8a.3 — bench-delta-per-commit infra.
- `308ca97` feat(p8): §9.8a / 8a.2-d — realworld_run_jit cross-
  process sentinel surface (closes 8a.2 minus D-055).
- `c5aaa50` feat(p8): §9.8a / 8a.2-c-i — x86_64 sentinel encoder.

3-host gate at `d1fdedc`: pending dispatch (this commit's diff
is pure scripts/, no Zig source change; gate validates baseline
preservation + script-side smoke).

**Phase 8 status**: §9.8 / 8.0-8.4 [x]; 8a.1 [x]; 8a.2 [x]; 8a.3
[x]; **§9.8a / 8a.4 NEXT**. Phase 8 残 rows = 8a.4-8a.6
(foundation) + 8b.1-8b.6 (optimisation).

## Active task — §9.8a / 8a.4: ZWASM_DIAG env var **NEXT**

Per ROADMAP §9.8a row text:
> Opt-in surfacing of the 8a.1/8a.2/8a.3 outputs without
> recompile, single binary across release + diagnostic modes.
> Diagnostic threadlocal infra (per ADR-0016) carries the flag
> set; affected components (passes, JIT prologue, bench runners)
> check the bit before emitting.

Wait — re-reading the row: `passes` (8a.1) + `jit_exec` (8a.2)
+ `bench` (8a.3) tokens map to compile-time-gated channels. The
build flag `-Dtrace-ringbuffer` already gates 8a.1/8a.2; 8a.3
is host-side bash. The runtime opt-in for the 8a.1 ringbuffer
drain (currently always-quiet because no surface yet) is the
8a.4 surface to actually read.

Suggested chunk plan:

| #     | Description                                              | Status   |
|-------|----------------------------------------------------------|----------|
| 8a.4-a | Survey: where does ZWASM_DIAG check fit (cli/main? src/diagnostic/?); existing `ZWASM_DEBUG` precedent (dbg.zig) | **NEXT** |
| 8a.4-b | Add `ZWASM_DIAG` env var parser + threadlocal flag set in `src/diagnostic/`; tokens: `passes`, `jit_exec`, `bench` | [ ]      |
| 8a.4-c | Wire trace ringbuffer drain on process exit when `ZWASM_DIAG=passes` is set | [ ]      |
| 8a.4-d | 3-host gate; close 8a.4 [x]                              | [ ]      |

After 8a.4 closes: 8a.5 (D-053 + D-054 cap-removal investigation),
8a.6 (8a boundary audit). 8a.5 IS the discharge path for D-054
+ D-055's chained blockers.

Then §9.8b begins: 8b.1 (Coalescer, bench-delta required) →
8b.2 (Regalloc upgrade) → 8b.3 (AOT skeleton) → 8b.4 (≥10%
aggregate) → 8b.5 (boundary audit) → 8b.6 (open §9.9).

## Open structural debt (pointers — current; full list in `.dev/debt.md`)

- **D-055** (`blocked-by: D-052 + emit_test_*.zig migration`) —
  x86_64 prologue inject deferred.
- **D-054** (`blocked-by: 8a.5 + D-055`) — OrbStack-only as-
  loop-broke regression.
- 9 `blocked-by:` rows — D-007 / D-010 / D-016 / D-018 / D-020
  / D-021 / D-022 / D-026 / D-028 / D-052; barriers all hold
  this resume.

D-053 promoted to ROADMAP row §9.8a / 8a.5 per ADR-0032.

**Phase**: Phase 8 (JIT optimisation foundation 🔒、ADR-0019)。
**Branch**: `zwasm-from-scratch`。
