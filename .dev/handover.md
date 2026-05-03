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
3. `.dev/ROADMAP.md` §9.6 task table — see the §9.6 reopened
   scope table (6.A〜6.J) for the active row.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (v1 conformance baseline,
  reopened per ADR-0011 + ADR-0012).
- **Last source commit**: `af411f0` — feat(p6) §9.6 / 6.A
  runtime-asserting WAST runner + per-instr trace landed
  (test/runners/wast_runtime_runner.zig + interp trace
  plumbing); three-host green.
- **Branch**: `zwasm-from-scratch`, pushed to
  `origin/zwasm-from-scratch`. `main` is forbidden; `--force`
  is forbidden.

## Active task — 6.B: test/ restructure + 4 fixtures migration

Per ADR-0012 §6 row 6.B. Sequenced after 6.A (now done).

Restructure `test/` per ADR-0012 §3 layout. Per-fixture migration
of the 4 existing `test/v1_carry_over/` fixtures:
- `add` and `f64-copysign` → verify content overlap with spec
  testsuite. If overlapping → `test/spec/legacy/`. Else →
  `test/wasmtime_misc/wast/basic/`.
- `div-rem` and `empty` → `test/wasmtime_misc/wast/basic/`.

Add `test/spec/legacy/` to layout. Update:
- `scripts/gate_merge.sh` — replace `test-v1-carry-over` step
  reference with the new step names.
- ROADMAP §A13 reference to `test/v1_carry_over/` — reword to
  the new origin-based directory names (load-bearing edit citing
  ADR-0012).
- `build.zig` — add `test-spec-legacy` step, update
  `test-v1-carry-over` to point at new paths or remove if no
  longer meaningful.

Sub-tasks:
1. Inspect each of the 4 fixtures' content; compare with spec
   testsuite to determine spec-overlap vs wasmtime-misc-only.
2. Create new directory tree: `test/spec/legacy/`,
   `test/wasmtime_misc/wast/basic/`, plus README placeholders.
3. Move fixtures + their `manifest.txt` entries.
4. Update `build.zig` step paths.
5. Update `scripts/gate_merge.sh` + ROADMAP §A13.
6. Three-host `zig build test-all` green.
7. Commit (chore(p6): land §9.6 / 6.B per ADR-0012).

## Phase 6 reopen DAG (ADR-0012 §6)

```
6.A ✅ (af411f0)
 │
 ├─→ 6.B ← ACTIVE
 │    └─→ 6.C → 6.D → 6.E → {6.F, 6.G, 6.H} → 6.J
 │
 └─→ 6.I (parallel to 6.E〜6.H)  ─→ 6.J
```

## Outstanding spec gaps (Phase 6 absorbs as v1 conformance)

- multivalue blocks (multi-param) — Phase 2 chunk 3b carry-over
- element-section forms 2 / 4-7 — Phase 2 chunk 5d-3
- ref.func declaration-scope — Phase 2 chunk 5e
- Wasm-2.0 corpus expansion (47 of 97 .wast files) — validator
  gaps surface per .wast file
- 39 trap-mid-execution realworld fixtures — 6.E target
- 10 SKIP-VALIDATOR realworld fixtures — per-function validator
  typing-rule gaps

## Open questions / blockers

(none — `/continue` autonomous loop drives 6.B → 6.J per ADR-0012
DAG; push to `origin/zwasm-from-scratch` is autonomous per the
`continue` skill's Push policy.)
