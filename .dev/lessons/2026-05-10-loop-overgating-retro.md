---
name: Autonomous loop over-gating retrospective (chunk granularity + windowsmini cadence)
description: §9.7 / §9.9 cycle landed ~25 chunks where ~6 would have served; windowsmini per-chunk gate added ~30-45 min wall-clock with 0 unique findings. Rebalance via SKILL.md / LOOP.md / CLAUDE.md edits.
date: 2026-05-10
keywords: chunk granularity, over-split, windowsmini, three-host gate, loop discipline, wall-clock, fixed overhead
citing: <backfill at next chunk>
---

# Autonomous loop over-gating retrospective

## Symptom

The §9.7 / §9.9 autonomous loop run (2026-05-10 single-day session)
landed ~25 chunks of x86_64 SIMD emit work in ~3 hours. User
observed that **wall-clock was dominated by per-chunk overhead**
(test gate + push + windowsmini + handover edit + chore commit +
re-arm) rather than by implementation time.

Two specific symptoms:

1. **Chunk over-splitting**. Sub-chunks 9.7-au through 9.7-bb
   averaged ~3-6 ops each. The v128 memory family alone
   (load + load_splat ×4 + load_zero ×2 + load_lane ×4 +
   store_lane ×4 + load_extend ×6 = 22 ops) was split into 5
   chunks (ax/ay/az/ba/bb) despite all sharing the same
   `v128MemPrologue` helper. A single chunk would have served.
2. **Windowsmini per-chunk gating empirically over-strict**.
   Across the 15+ chunks of the run, windowsmini surfaced **zero
   unique findings** (= bugs not already caught by Mac + OrbStack)
   while adding ~2-3 min wall-clock per chunk = ~30-45 min
   cumulative cost. The D-028 IPC flake fired once (also caught
   by retry, not by exposing a real bug).

## Root cause

Both root causes traced to the loop scaffolding:

### Cause A: `SKILL.md` "Bundle when ALL hold" was too narrow

The criterion list was AND-conjunction. The binding constraint
was "**Same encoder family**" — interpreted strictly, this
forced load + load_splat + load_zero + load_lane + load_extend
into separate chunks because each variant calls a different
encoder family (MOVUPS vs PSHUFB vs MOVSS+PSHUFD vs PINSR/PEXTR
vs PMOVSX/ZX) — even though they all *consume* the same
`v128MemPrologue` shared helper.

The example table in the rules even called out earlier instances
of over-split (trunc-sat-u32 + u64 = 1 chunk, was 2; fp-convert
families = 1 chunk, was 2) — but the rule text wasn't updated
to make these new defaults.

### Cause B: `CLAUDE.md` + `LOOP.md` mandated per-chunk 3-host gate

Mandatory pre-commit checks #6 said "OrbStack + windowsmini SSH
must also pass before push" — interpreted as "every push" =
"every chunk" given the autonomous loop's 1-chunk-1-push cadence.

The justification (cross-arch divergence catching) is real but
empirically weighted toward ABI-touching diffs. For chunks that
add encoder + handler + dispatch arm following an established
pattern, Win64 vs SysV bug surface is essentially zero (Mac NEON
gives algorithmic ground truth; OrbStack catches encoding + SysV
ABI; Win64 only adds shadow-space + callee-saved-XMM divergence
which only matters for ABI-touching code).

## Decision

Rebalance the autonomous loop via four scaffolding edits
(2026-05-10):

1. **`scripts/should_gate_windows.sh` (new)** — heuristic that
   returns 0 (gate) when ABI/calling-convention/frame-layout
   paths are touched in the diff OR 4+ commits accumulate since
   last windowsmini run. Otherwise defers.

2. **`.claude/skills/continue/LOOP.md`** — Step 5 amended:
   OrbStack always runs per-chunk; windowsmini conditional on
   `should_gate_windows.sh`. Records HEAD via `--record` after
   successful windowsmini run.

3. **`.claude/skills/continue/SKILL.md`** — Chunk granularity:
   - **Default chunk size for established-pattern emit/handler
     chunks: 5–15 ops** (was implicit 1–4).
   - "Bundle when ALL hold" criterion changed: "Same encoder
     family" → "**Same dispatch helper consumer**" (broader,
     captures the v128MemPrologue case).
   - LOC caps raised: source 400→800, test 250→400, mid-cycle
     ratchet 600→1200.
   - Anti-pattern callout: "1 op = 1 chunk" for established
     patterns is forbidden.

4. **`CLAUDE.md`** Mandatory pre-commit checks #6 — windowsmini
   phrasing softened from "must also pass before push" to
   "checkpoint cadence per `should_gate_windows.sh`". Phase
   boundaries + ABI-touching diffs still force full 3-host.

## Consequences

- Per-chunk wall-clock should drop ~50% on encoder/handler
  cycles (no windowsmini wait + larger op-per-chunk amortising
  fixed overhead).
- Win64 regression detection latency increases up to 4 chunks
  (was 1). Acceptable trade-off given the empirical 0-unique-
  findings rate; bisect cost is bounded by the 4-commit window.
- Chunk-table rows in handover/ROADMAP become more substantial
  (10-20 ops per row instead of 1-4) — easier to read in
  hindsight.
- The strict 3-host gate retains its load-bearing role at:
  (i) phase boundaries (audit_scaffolding mandatory trigger),
  (ii) `git push` to `main` (release prep),
  (iii) any ABI / calling-convention / frame-layout diff
  (caught by `should_gate_windows.sh`'s ABI_PATHS list).

## Citing

This lesson is cited from:
- `.claude/skills/continue/LOOP.md` (Parallel test gate)
- `.claude/skills/continue/SKILL.md` (Chunk granularity)
- `CLAUDE.md` (Mandatory pre-commit checks #6)
- `scripts/should_gate_windows.sh` (header comment)

Citing commit SHA: backfill at next chunk close.
