# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.7 row — Phase 9 active.
3. `.dev/debt.md` — D-055 / D-057 + 10 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: simd ops, x86_64 SSE/SSE4.1/SSE4.2, ADR-0041 §5,
   v1-monolith-file-survey-miss).
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline post-9.7-m
   amendment; §5 + Alternative E hold the rationale).

## Current state — Phase 9 / §9.7 in-flight (9.7-a..at landed); **§9.7 row scope-review NEXT**

9.7-at: `i32x4.trunc_sat_f32x4_u` (commit `2c318bfb`). Closed
the last of 4 deferred 9.7-ae u-variants. 14-instr cranelift
recipe (`lower.isle:3919-3962`) — XORPS+MAXPS clamp, magic
synthesis (PCMPEQD+PSRLD+CVTDQ2PS = 0x4f000000), two-path
CVTTPS2DQ + CMPPS-LE mask + PMAXSD-zero clamp + PADDD merge.
New encoder encPmaxsd (SSE4.1). Prior session's "3-scratch
budget exceeded" reading was wrong: dst (regalloc'd from
XMM8..XMM13) + XMM14 + XMM15 already gives 3 distinct physical
xmms within existing fp_spill_stage_xmms reservation; no ABI
change needed. Same dual-scratch pattern as 9.7-q/w/ac. 188
SIMD ops handled total.

**Next — §9.7 row scope review**. 9.7-at was the last
known-deferred sub-chunk. Step 0 should grep
`src/engine/codegen/x86_64/emit.zig` switch arms vs Wasm SIMD
op total (~415 spec ops, 188 currently handled per the row's
running tally) to determine: (a) are remaining unhandled ops
genuinely scope of §9.8 (ROADMAP description: "x86_64 emit
SSE4.1 — comparison + shuffle + float arith + conversion")?
Note that 9.7's prose has expanded inline to cover
comparison/shuffle/FP arith/conversion across 9.7-k..ad — so
9.8's nominal scope already overlaps. Decide whether (i) flip
9.7 [x] + 9.8 [x] (both substantively done by 9.7's prose
expansion), (ii) carve remaining ops into 9.7-au... or 9.8
sub-chunks, or (iii) fold 9.8 scope into 9.7 prose explicitly
via §18 ADR. The answer is **not pre-decided**; it requires a
concrete unhandled-op grep to scope.

Subsequent: §9.7 close-out → Phase-9-internal §9.8/9.9
(simd.wast spec test wired, fail=skip=0 across both backends)
→ §9.10 (smoke benches, gap analysis) → §9.11 (audit + SHA
backfill) → §9.12 (open §9.10 ie Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-055** (x86_64 prologue inject) — blocked-by D-052 prologue
  extract (still holds).
- **D-057** (op_simd.zig hard-cap) — blocked-by ADR for source-
  split landing. file_size_check.sh continues to report breach
  (3819 LOC after 9.7-at). Discharge requires ADR mirror of
  ADR-0030; deferred until §9.7 row close.
- 10 `blocked-by:` rows: D-007/D-010/D-016/D-018/D-020/D-021/
  D-022/D-026/D-028/D-052 — barriers all hold this resume.

Closed Phase 8b artefacts (preserved for Phase 12 + Phase 15
reference) live in git: ADRs 0035-0040, lessons indexed in
`.dev/lessons/INDEX.md`, code in `src/ir/coalesce/`,
`src/engine/codegen/shared/regalloc.zig` (LIFO free-pool),
`src/engine/codegen/aot/`. `git log` is authoritative.

**Phase**: Phase 9 (SIMD-128, ADR-0041 — SSE4.2 baseline).
§9.5 [x] (ARM64 NEON pt 1), §9.6 [x] (ARM64 NEON pt 2),
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..at landed; row
close pending scope review).
**Branch**: `zwasm-from-scratch`。
