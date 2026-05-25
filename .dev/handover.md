# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8 (ARCHIVED-IN-PLACE 2026-05-25; cite-only).
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)。
- **Last commit**: `9748e805` — 10.T-2b spec_assert_runner_wasm_3_0.zig
  skeleton + build.zig wire (enumerates 4 manifests / 353 directives
  across 4/5 sub-corpora; gc empty per D-179)。10.D 7/7 ADRs drafted
  (Accept pending)。
- **Phase 9 close invariants gate (mac-host)**: **18/18 PASS** 維持。
- **Mac `zig build test`**: 1827/1841 passed (substrate baseline);
  ubuntu test-all 10.Z verified GREEN at `b6e07451`。

## Active task — 10.T test infra setup (10.D 7/7 ADR drafts COMPLETE)

**10.D status**: all 7 ADRs drafted as `Status: Proposed`. User
collab gate now ACTIVE — Accept flip needed to unlock impl rows
10.M / 10.R / 10.TC / 10.E / 10.G. Autonomous prep paths fully
exhausted for 10.D.

| ADR | Topic | Status |
|---|---|---|
| 0111 | memory64 design | Proposed `c3895cd1` |
| 0112 | Tail Call design | Proposed `8d535ec1` |
| 0113 | callsite_metadata + regalloc 3-axis | Proposed `e527b52b` |
| 0114 | Exception Handling design | Proposed `027ae91a` |
| 0115 | GC heap + collector design | Proposed `f37f3e56` |
| 0116 | GC roots + RTT + i31 | Proposed `698a8b8f` |
| 0117 | GC × EH × TC integration invariants | Proposed `4561dfe1` |

**Active pivot to 10.T** (autonomous-eligible per ROADMAP §10
row text "テスト infra 整備 (実装陣前)"; NOT blocked by 10.D
Accept gate — only impl rows are). Sub-chunks in order:

- 10.T-1 ✓ `ad16c2cc`: `scripts/import_proposal_corpus.sh` +
  424 raw .wast committed.
- 10.T-2a ✓ `433967fb`: `scripts/regen_spec_3_0_assert.sh` +
  smoke bake (4/5).
- 10.T-2b ✓ `9748e805`: skeleton runner enumerates manifests +
  wired to `test-spec-wasm-3.0-assert` + `test-all`.
- **10.T-3 NEXT**: `test/runners/gc_stress_runner.zig` +
  `test/runners/eh_frequency_runner.zig` skeletons (impl-body
  pending 10.G / 10.E; skeletons can be SKIP-routed wired
  into build.zig as no-op steps until impl rows fire).
- 10.T-3: `gc_stress_runner.zig` + `eh_frequency_runner.zig`
  skeletons (impl after 10.G / 10.E land).
- 10.T-4: Phase 9 `emit_test_*.zig` baseline 採取 +
  `ZWASM_TEST_BLESS=1` bless workflow.
- 10.T-5: `test/realworld/p10/` 9 fixture / 5 toolchain
  skeleton (Dart / wasm_of_ocaml / Hoot / emscripten_eh /
  clang_musttail / clang_wasm64).

## Phase 10 progress

ROADMAP §10 = 13-row task table。10.0/10.C9/10.J/10.F/10.Z done
(5/13); **10.D ADR drafts 7/7 COMPLETE (Accept flip pending)**;
**10.T pivot active** (autonomous; ADR-Accept-independent);
10.M/10.R/10.TC/10.E/10.G/10.P pending impl。

## Open questions / blockers (per handover_framing.md)

- ADR-0111..0117 all require `Status: Proposed → Accepted` user
  flip to close 10.D. Autonomous prep fully walked (7/7 drafts
  landed). Loop has no further autonomous lever for 10.D
  itself — but 10.T is independent and autonomous-eligible.
- 10.D close also requires ROADMAP §12 (AOT) amendment: add
  "stack-map emission compatible with GC root walker" exit
  criterion. This is a load-bearing §18.2 edit; user reviews
  at ADR Accept time.

## Key refs

- **ROADMAP §10**: [`ROADMAP.md`](./ROADMAP.md) lines 1338+
- **Phase 10 design plan**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md) §3.1-§3.5 (ADR-0111..0117 source-of-truth)
- **ADR-0111**: [`decisions/0111_memory64_design.md`](./decisions/0111_memory64_design.md) (Proposed)
- **`/continue` autonomous prep paths**: `.claude/skills/continue/SKILL.md`
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
