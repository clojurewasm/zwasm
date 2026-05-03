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
- **Last commit**: `2a66d6a` — §9.6 / 6.0 land: `test/v1_carry_over/`
  vendored (4 NAMES, 12 valid modules, all hosts green) + new
  `test-v1-carry-over` build step wired into `test-all`.
- **Next task**: §9.6 / 6.1 — realworld coverage (all 50 vendored
  samples run to completion under v2 interp on Mac + Linux; no
  `Errno.unreachable_` traps).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.1 (realworld run-to-completion coverage)

Per §9.6 exit criterion: every one of the 50 vendored realworld
.wasm fixtures must run to completion under v2 interp on Mac +
Linux; no `Errno.unreachable_` traps from missing ops.

Today's `test/realworld/runner.zig` is parse-smoke only (Phase-2
artefact) — it loads each fixture and checks parse + section
decode. 6.1 extends it (or adds a sibling) to actually
instantiate + invoke each fixture's `_start` / `main` until it
exits cleanly OR the runtime traps with a *non-unreachable*
condition (those are spec-conformant traps, not validator gaps).

Plan:

1. Survey `test/realworld/wasm/` to confirm the 50-fixture set
   (`ls test/realworld/wasm/ | wc -l`).
2. Extend `test/realworld/runner.zig` (or add a runner sibling)
   to instantiate via `wasm_module_new` / `wasm_instance_new` /
   `wasm_func_call`. Skip fixtures that need WASI host wiring
   beyond the §9.4 surface; surface those as "needs WASI
   extension" in the runner output.
3. Three-host `zig build test-realworld` (or new step) — must
   show 50/50 run-to-completion on Mac + Linux.
4. Wire any new step into `test-all`.

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
  block validator support (Phase-2 chunk-3b carry-over already
  queued; absorbed by Phase 6 per ADR-0008). Re-add to
  `regen_v1_carry_over.sh` NAMES once the gap closes.

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
