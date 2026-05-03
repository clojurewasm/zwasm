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

- **Phase**: **Phase 5 IN-PROGRESS.** Phases 0–4 are `DONE` (all
  SHAs backfilled in §9.<N> task tables; `git log --grep="§9.<N>
  / N.M"` is the canonical lookup).
- **Last commit**: `8546d52` — zig_tips.md self-review compression
  + handover Active-task refresh (mid-Phase 5 lint-tooling work
  per ADR-0009).
- **Next task**: §9.5 / 5.0 chunk c — `src/c_api/vec.zig` carve-out
  (see Active task table below).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.5 / 5.0 (split src/c_api/wasm_c_api.zig per ADR-0007)

`wasm_c_api.zig` is at **1742 lines** (already inside §A2's 2000-
line hard cap; ADR-0007 carve-out continues for the soft-cap and
discoverability target). Carve-out progress:

| Chunk | Target file                  | Status                                                                                                                                                                                          |
|-------|------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| a     | `src/c_api/wasi.zig`         | DONE `2dd29cc` (16 WASI thunks + `lookupWasiThunk` + `zwasm_wasi_config_*`)                                                                                                                     |
| b     | `src/c_api/trap_surface.zig` | DONE `d894787` (`Trap` / `TrapKind` / `mapInterpTrap` / `wasm_trap_*`)                                                                                                                          |
| **c** | `src/c_api/vec.zig`          | **NEXT** (~350 lines: `ByteVec` / `ValVec` / `ExternVec` shapes + `WASM_DECLARE_VEC` family `_new_empty` / `_new_uninit` / `_new` / `_copy` / `_delete`; `wasm_byte_vec_delete` moves here too) |
| d     | `src/c_api/instance.zig`     | TODO (~650 lines: Engine / Store / Module / Instance / Func / Extern, `instantiateRuntime`, `*_new` / `*_delete`, `wasm_func_call`, `wasm_instance_exports`)                                    |
| e     | `wasm_c_api.zig`             | shrinks to ~600 lines: re-exports + module docs; keeps name-points stable                                                                                                                       |

Plan (per remaining chunk):

1. Move the chunk's block out; tests follow the code under test.
2. After each move: `zig build test` (Mac) + `zig build lint
   -- --max-warnings 0` (Mac, ADR-0009 gate). Retain three-host
   `test-all` at the end of the full carve-out.
3. `pub export fn` declarations stay (just relocated); C linker
   symbols are unchanged.
4. Per-chunk push is the established pattern (see `2dd29cc`,
   `d894787`).

Watch: cross-file imports may cycle if e.g. `instance.zig` imports
`trap_surface` (for `allocTrap`) and `trap_surface` imports
`instance` (for the Store back-pointer in Trap). Resolve by
threading the dependency one-way.

After 5.0 lands, also: re-evaluate `no_hidden_allocations` zlinter
rule for the carved files (deferred per ADR-0009 — the rule was
not adopted in Phase B because all 13 hits were in the monolithic
`wasm_c_api.zig`; per-zone exclusion becomes clean once split).

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
