# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   defines Phase 6 reopen scope (work items 6.A〜6.J, DAG, deferred
   items).
3. `.dev/ROADMAP.md` §9.6 task table — see "§9.6 reopened scope"
   sub-table (6.A〜6.J) for the active row.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (v1 conformance baseline,
  reopened per ADR-0011 + ADR-0012).
- **Last commit**: `e7ba78e` — chore(p6) §9.6 / 6.B migration
  test/v1_carry_over → test/wasmtime_misc/wast/basic; three-host
  green.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — 6.C: vendor wasmtime_misc BATCH1-3 (~55 fixtures)

Per ADR-0012 §6 row 6.C. Sequenced after 6.B (now done).

Vendor wasmtime_misc BATCH1-3 (~55 fixtures: basic + reftypes +
embenchen + issues) into:
- `test/wasmtime_misc/wast/basic/` (BATCH1, partially populated
  in 6.B with 4 fixtures; expand to full BATCH1 ≈ 26 from
  v1's classification)
- `test/wasmtime_misc/wast/reftypes/` (BATCH2, ≈ 15 fixtures)
- `test/wasmtime_misc/wast/embenchen/` (BATCH3 embenchen subset,
  ≈ 4-5 fixtures)
- `test/wasmtime_misc/wast/issues/` (BATCH3 issue regression
  subset, ≈ 9-10 fixtures)

BATCH4 (SIMD, 14 fixtures) and BATCH5 (proposals, 52 fixtures)
defer to feature-specific phases per ADR-0012 §6.2.

Introduce `scripts/setup_corpora.sh` (per ADR-0012 §2.3) that
wraps `git sparse-checkout` of `bytecodealliance/wasmtime` /
`tests/misc_testsuite/` into `.cache/wasmtime_misc/`, supports
`--offline` for restricted-network CI.

Sub-tasks:
1. Implement `scripts/setup_corpora.sh` with sparse-checkout.
2. Run it once to populate `.cache/wasmtime_misc/`.
3. Identify which v1 BATCH1-3 fixtures map to which upstream
   `tests/misc_testsuite/` source files (cross-reference v1
   `test/e2e/convert.py`'s flatten_name() to see the mapping).
4. Convert each .wast → .wasm via `wabt`'s `wast2json` (or
   `wat2wasm` for the assert-extracted bodies); land per
   wast file as a sub-corpus in the appropriate
   `test/wasmtime_misc/wast/<category>/` dir with manifest.
5. Three-host `zig build test-wasmtime-misc-basic` +
   `test-all` green.
6. Commit (chore(p6): land §9.6 / 6.C — vendor wasmtime_misc
   BATCH1-3).

Note: 6.D wires the runtime-asserting runner to drive these
through assert_return / assert_trap directives (currently the
new corpus stays parse+validate-only via `wast_runner.zig`).

## Phase 6 reopen DAG (ADR-0012 §6)

```
6.A ✅ (af411f0)
6.B ✅ (e7ba78e)
 │
 ├─→ 6.C ← ACTIVE
 │    └─→ 6.D → 6.E → {6.F, 6.G, 6.H} → 6.J
 │
 └─→ 6.I (parallel)  ─→ 6.J
```

## Outstanding spec gaps (Phase 6 absorbs)

- multivalue blocks (multi-param) — Phase 2 chunk 3b carry-over
- element-section forms 2 / 4-7 — Phase 2 chunk 5d-3
- ref.func declaration-scope — Phase 2 chunk 5e
- 39 trap-mid-execution realworld fixtures — 6.E target
- 10 SKIP-VALIDATOR realworld fixtures — per-function validator
  typing-rule gaps

## Open questions / blockers

(none — autonomous loop continues 6.C → 6.J per ADR-0012 DAG.)
