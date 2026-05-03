# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` — read the **Phase Status** widget at the top
   of §9 to find the IN-PROGRESS phase, then its expanded `§9.<N>`
   task list; pick up the first `[ ]` task.
3. The most recent `.dev/decisions/NNNN_*.md` ADR (if any) — to
   recover load-bearing deviations in flight.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (v1 conformance baseline per
  ADR-0008 🔒).
- **Last commit**: `b03b853` — §9.6 / 6.1 chunk a (partial): all 50
  realworld fixtures vendored + parser `data_count` ordering bug
  fixed; parse + section decode 50/50 on three hosts.
- **Next task**: §9.6 / 6.1 chunk b — extend
  `test/realworld/runner.zig` to instantiate + invoke each
  fixture via `cli/run.zig:runWasm`, satisfying the
  "run-to-completion under v2 interp" exit criterion.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.1 (realworld run-to-completion coverage)

Two-chunk delivery per the exit criterion's two halves:

| Chunk | Scope                                                                                    | Status                |
|-------|------------------------------------------------------------------------------------------|-----------------------|
| a     | Vendor missing 43 fixtures (7 → 50); fix any parse-time gaps surfaced by the new corpus. | DONE `b03b853` (parser `data_count` bug fix included — bulk-memory §3.4 says 12 sits between element(9) and code(10), not between import(2) and function(3); TinyGo emits per spec). |
| **b** | Extend `test/realworld/runner.zig` (or add `realworld_run_runner.zig`) to call `cli/run.zig:runWasm` over each fixture. PASS = `runWasm` returns any u8 exit code without surfacing a `Trap.Unreachable` from a missing op. INFO/SKIP for fixtures requiring WASI host state beyond §9.4 (proc / fd / clocks / random surface that is wired) — they instantiate but their entry point may legitimately exit early. | **NEXT** |

Plan for chunk b:

1. Decide the runner shape — extend `runner.zig` with a
   `--run` flag, OR add a sibling `realworld_run_runner.zig`
   wired to a separate `test-realworld-run` build step. Sibling
   is cleaner since the parse-smoke gate stays useful as a
   cheaper subset.
2. Categorise each fixture's outcome: PASS (any u8 exit), INFO
   (instantiate ok, runtime returned non-zero exit), SKIP-WASI
   (instantiation surface gap), FAIL (Trap.Unreachable from a
   missing op — the gate condition).
3. Three-host gate: 50/50 must avoid the FAIL bucket. Bumps to
   `test-all`.

Phase-6 follow-ups in order: 6.2 differential gate (30+ samples
match `wasmtime run` byte-for-byte) / 6.3 ClojureWasm guest
end-to-end / 6.4 bench baseline / 6.5 A13 merge gate / 6.6
verifier CI hook / 6.7 boundary audit / 6.8 phase tracker.

Carry-overs from §9.5 still queued (no consumer yet):
- `no_hidden_allocations` zlinter re-evaluation (ADR-0009).
- Per-feature handler split for validator.zig (with §9.1 / 1.7).
- Liveness control-flow + memory-op coverage (Phase-7 regalloc).
- Const-prop per-block analysis (Phase-15 hoisting).
- `src/frontend/sections.zig` (1073 lines) soft-cap split.

Carry-over surfaced by §9.6 / 6.0:
- `br-table-fuzzbug` v1 regression — needs multi-param `loop`
  block validator support. Re-add to `regen_v1_carry_over.sh`
  NAMES once the gap closes.

## Outstanding spec gaps (queued for Phase 6 — v1 conformance)

These were surfaced during Phases 2–4 and deferred from their own
phase. Phase 6 (ADR-0008) absorbs them as part of the v1
conformance baseline; do NOT re-pick during Phase 5.

- **multivalue blocks (multi-param)**: `BlockType` needs to carry
  both params + results; `pushFrame` must consume params (Phase 2
  chunk 3b carry-over).
- **element-section forms 2 / 4-7**: explicit-tableidx and
  expression-list variants (Phase 2 chunk 5d-3).
- **ref.func declaration-scope**: §5.4.1.4 strict declaration-
  scope check (Phase 2 chunk 5e).
- **Wasm-2.0 corpus expansion**: 47 of 97 upstream `.wast` files
  deferred (block / loop / if 1-5, global 24, data 20, ref_*,
  return_call*) — each surfaces a specific validator gap.

## Open questions / blockers

(none — push to `origin/zwasm-from-scratch` is autonomous inside
the `/continue` loop per the skill's "Push policy"; no user
approval required.)
