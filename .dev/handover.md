# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8 (ARCHIVED-IN-PLACE 2026-05-25; cite-only).
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)。
- **Last commit**: `7fb6593d` — 10.Z cycle-2 SUCCESS: `ZirInstr.payload
  u32 → u64` widened across 30 files via subagent-driven mechanical
  migration per the cycle-2 plan。memory64 offset spec-full carry が
  IR level で landing。
- **Phase 9 close invariants gate (mac-host)**: **18/18 PASS** 維持。
- **Mac `zig build test`**: 1827/1841 passed (substrate baseline);
  **`zig build test-all`**: 1773/1787 passed (logic gate; 14 skipped,
  42/42 build steps); lint clean。
- **emit_test_*.zig byte-identical** 維持確認済。

## Active task — 10.D NEXT (Phase 10 design ADR round)

10.Z 完了。Phase 10 内の次の `[ ]` 行は **10.D** (大きな設計ラウンド)。

| Row | Scope | Status |
|---|---|---|
| 10.0 / 10.C9 / 10.J / 10.F / 10.Z | done | `[x]` |
| **10.D NEXT** | 設計ラウンド (ADR-0111-0117 + ROADMAP §12 amend) — 全 7 ADR を実装着手前に Accepted: memory64 (0111) / Tail Call (0112) / callsite_metadata + regalloc 3-axis (0113) / EH (0114) / GC heap+collector (0115) / GC roots+RTT+i31 (0116) / GC×EH×TC integration invariants (0117) + ROADMAP §12 (AOT) に "stack-map emission compatible with GC root walker" exit criterion 追加 | `[ ]` |
| 10.T / 10.M / 10.R / 10.TC / 10.E / 10.G / 10.P | pending | `[ ]` |

**10.D exit criterion** (per ROADMAP §10 row 10.D):
(a) ADR-0111 (memory64) Accepted;
(b) ADR-0112 (Tail Call) Accepted;
(c) ADR-0113 (callsite_metadata + regalloc 3-axis: stack-map / EH-edges / TC-terminator) Accepted;
(d) ADR-0114 (EH) Accepted;
(e) ADR-0115 (GC heap + collector) Accepted;
(f) ADR-0116 (GC roots + RTT + i31) Accepted;
(g) ADR-0117 (GC × EH × TC integration invariants) Accepted;
(h) ROADMAP §12 (AOT) に "stack-map emission compatible with GC root walker" exit criterion 追加。

これは USER COLLAB GATE — 7 ADR の Accept は user-input-gated。
自律 loop は autonomous prep paths (per `/continue` SKILL.md
"Autonomous prep paths for user-gated ADRs") を walk して
ADR draft + reference-repo enrichment を準備可能。

## Phase 10 progress

ROADMAP §10 = 13-row task table。10.0/10.C9/10.J/10.F/10.Z done (5/13);
**10.D active (user collab gate)**;
10.T/10.M/10.R/10.TC/10.E/10.G/10.P pending。

## Key refs

- **ROADMAP §10**: [`ROADMAP.md`](./ROADMAP.md) lines 1338+
- **Phase 10 design plan**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md) (10.D の 7 ADR シナリオ整理)
- **Architectural-chunk discipline**: `.claude/rules/architectural_spike.md` (3-cycle cap; 10.Z used 2/3)
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
