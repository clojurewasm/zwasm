# 0084 — Extract FP encoders from `arm64/inst.zig` into `inst_fp.zig`

- **Status**: Closed (2026-05-21, impl landed; amended scope per Revision history)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, post-ADR-0083)
- **Tags**: file-layout, refactor, zone-2, codegen-arm64, file-size-cap

## Context

`src/engine/codegen/arm64/inst.zig` is **1807 LOC** — 81% over
the 1000-LOC soft cap (ROADMAP §A2). D-141 lists it among per-file
ADR candidates. Measurement-focused Step 0 survey (per lesson
[`2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed`](../lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md))
identified the structure as **pure utility module**:

- No structs, no methods, no state (cross-file method-syntax
  constraint from lesson
  [`2026-05-21-cross-file-struct-method-syntax-zig-0-16`](../lessons/2026-05-21-cross-file-struct-method-syntax-zig-0-16.md)
  does NOT apply).
- 125 top-level `pub fn encXxx(...) u32` encoder functions
  (mechanical bit-pattern emission, 1–14 LOC each).
- 645 LOC of in-source `test "..."` blocks (77 test cases,
  lines 1171–1752) — **35% of file** is tests.

LOC breakdown by semantic category:

| Category | LOC | % | Notes |
|---|---|---|---|
| Docstring + zone isolation | 20 | 1.1% | scope + Arm IHI 0055 ref |
| Type aliases + constants | 14 | 0.8% | `Xn`, `Vn`, `xzr`, `sp_reg` |
| Immediate-operand ALU encoders | 83 | 4.6% | MOV/ADD/SUB/CMP imm |
| Register-register ALU encoders | 262 | 14.5% | 44 encoders |
| Memory load/store encoders | 194 | 10.7% | 32 encoders |
| Branch + control encoders | 92 | 5.1% | 13 encoders |
| Sign-extend sub-word encoders | 34 | 1.9% | 6 encoders |
| **FP machinery (extraction target)** | **227** | **12.6%** | 35 encoders: 16 int↔FP convert + 16 FP binary + 12 FP unary + 7 FP move/select |
| Cond enum + invertCond helper | 21 | 1.2% | shared |
| SIMD sub-byte encoders | 26 | 1.4% | 5 V-register encoders |
| Conditional select encoders | 22 | 1.2% | CSET/CSETm |
| **Test block** | **645** | **35.7%** | 77 in-source tests |
| Whitespace + section headers | 167 | 9.2% | |

The **FP machinery** is the most cohesive extractable block:

- 35 encoders sharing FP register conventions (S/D-form, V-type
  registers).
- Zero coupling to GPR encoders (different register class).
- Callers cluster in `op_alu_float.zig` + `op_convert.zig`
  (the per-op FP modules from ADR-0074).
- FP-specific tests (~125 of the 645 test LOC) move alongside.

Other candidates surveyed:

- **SIMD sub-byte (26 LOC)**: too small to justify a separate
  file. Could merge into existing `inst_neon.zig` if that's
  cleaner; out of scope for ADR-0084.
- **Register ALU (262 LOC)**: too interwoven with the file's
  central encoder surface; extracted module would still depend
  on `invertCond` + Cond enum from inst.zig — net cost of one
  more cross-file dependency for no semantic gain.
- **Memory ops (194 LOC)**: fragmented into sub-byte / FP /
  immediate scales; no clean boundary.
- **Branch + control (92 LOC)**: smaller than FP, callers
  scattered across emit.zig + op_control.zig.

Aggressive multi-file split (Alternative A below) is rejected
because it inverts the encoder-discovery cost: 23 caller files
would each need 6–8 imports where previously they import one
`inst.zig`.

## Decision

Extract the **FP machinery** from `src/engine/codegen/arm64/inst.zig`
into a new sibling `src/engine/codegen/arm64/inst_fp.zig`.
FP-specific in-source tests move alongside the encoders. The
GPR-side encoders, branch encoders, memory encoders, sign-extend,
conditional, immediate-form encoders, and the SIMD sub-byte
helpers stay in inst.zig.

| File | Contents | Approx LOC |
|---|---|---|
| `src/engine/codegen/arm64/inst.zig` (revised) | Module docstring, type aliases (Xn/Vn/xzr/sp_reg), Cond enum + invertCond, immediate ALU (12), register ALU (44), memory ops (32), branch + control (13), sign-extend (6), conditional select (2), SIMD sub-byte (5), GPR-side tests | ~1455 |
| `src/engine/codegen/arm64/inst_fp.zig` (new) | Int↔FP conversions (16), FP binary ALU (16), FP unary + rounding (12), FP register move + select (7) = 35 encoders + FP-specific in-source tests | ~355 |

`inst_fp.zig` imports the shared utilities (`Cond` enum) via
`const inst = @import("inst.zig"); const Cond = inst.Cond;` so
encoders that use condition codes (FCSEL forms) reach the shared
enum.

Caller-side migration: 8 of 23 arm64 caller files need a
secondary import. Specifically:

- `op_alu_float.zig`: currently uses `inst.encFAddS` / `encFCmpD` /
  `encFAbsS` / etc.; will add `const inst_fp = @import("inst_fp.zig");`
  and use `inst_fp.encFAddS` / etc.
- `op_convert.zig`: uses `inst.encScvtfSFromW` / `encFcvtzsXFromD` /
  etc.; same treatment.
- `op_alu_int.zig`, `op_memory.zig`, `op_call.zig`,
  `op_control.zig`, `emit.zig`, `thunk.zig`: keep `inst.zig`
  only (their encoders all stay in inst.zig).
- Tests in inst_fp.zig reference FP encoders directly; no
  external test-side changes.

### Why FP and not another semantic axis

Per the survey's "Extractable Mass Estimate":

- FP machinery is the **only contiguous semantic group with
  > 200 LOC of cohesive code + > 100 LOC of cohesive tests**
  that callers cluster naturally around (op_alu_float +
  op_convert).
- The structural reality: GPR encoders are scattered across ALU,
  memory, branch, sign-extend — splitting any one of those
  leaves the others coupled to inst.zig's shared helpers. FP is
  the only sub-tree that's already self-contained.
- The remaining ~1455 LOC of inst.zig is still over soft cap
  (1455 > 1000) but bunches into smaller semantic clusters; a
  follow-up ADR may extract memory or branch encoders if Phase
  9+ pressure demands it.

### Implementation order (single carve cycle)

1. **This ADR**: Proposed land.
2. **Carve cycle** (next):
   - Create `src/engine/codegen/arm64/inst_fp.zig` with module
     docstring + the 35 FP encoder functions + the
     FP-specific in-source tests. Add `const inst =
     @import("inst.zig"); const Cond = inst.Cond;` for shared
     condition-code enum.
   - Update inst.zig: delete the 35 FP encoders and the
     FP-specific test blocks (estimated ~352 LOC removed —
     227 code + ~125 tests).
   - Update 2 caller files (`op_alu_float.zig`,
     `op_convert.zig`) to add `const inst_fp = @import("inst_fp.zig");`
     and rewrite the `inst.encF...` references to `inst_fp.encF...`.
   - Run cohort gate (test-all) and lint.
3. **Status flip** (post-impl): ADR-0084 Status Proposed →
   Accepted with Revision history SHA backfill.

## Alternatives considered

### Alternative A — Aggressive per-family split (7+ new files)

- **Sketch**: extract every encoder family as a separate file
  (`inst_alu_reg.zig`, `inst_alu_imm.zig`, `inst_mem.zig`,
  `inst_branch.zig`, `inst_cond.zig`, `inst_convert.zig`,
  `inst_fp.zig`, etc.).
- **Why rejected**: 23 caller files would each need 6–8 imports
  (currently one). Discoverability collapses — a reader walking
  `op_memory.zig` would need to follow `inst_mem` AND
  `inst_alu_reg` (for ADD-based offset calc) AND `inst_cond`
  (for bounds-check branch). The encoder discovery cost moves
  from "read one file" to "follow chain of 5+ imports". This is
  the same anti-pattern ADR-0080 hit at a smaller scale.

### Alternative B — Extract memory or branch encoders instead

- **Sketch**: extract `inst_mem.zig` (194 LOC of memory ops) or
  `inst_branch.zig` (92 LOC).
- **Why rejected**:
  - **Memory (194 LOC)**: fragmented into sub-byte / 32-bit /
    64-bit / FP-scalar S/D-form scales. The "FP scalar" memory
    encoders (encLdrSReg, encLdrDImm, etc.) are arguably
    FP-side, but they share the load/store dispatch shape
    with int memory. Extraction creates a third-party between
    inst.zig and inst_fp.zig. No clean axis.
  - **Branch (92 LOC)**: too small relative to inst.zig's
    bloat. Extraction drops inst.zig 1807 → 1715, still 71%
    over soft cap.
- The FP machinery's 227 LOC + 125 test LOC = ~352 LOC drop is
  the largest single-axis extraction available without
  fragmentation.

### Alternative C — Keep monolith + raise soft cap

- **Sketch**: leave inst.zig at 1807; raise §A2 soft cap.
- **Why rejected**: precedent collapse (rejected in ADR-0079,
  -0080, -0081, -0082, -0083). The FP machinery's
  self-containment + Phase 14+ SIMD-extraction trajectory
  (ADR-0041 Rev 2) makes "this file is monolithic by design"
  defensible only for `op_simd_int_cmp_lane.zig` (which has
  the FILE-SIZE-EXEMPT marker per ADR-0075 §9.12-B). inst.zig
  has no such exemption and no design rationale to be
  monolithic — its bloat is incidental, not architectural.

## Consequences

- **Positive**:
  - inst.zig drops 1807 → ~1455 LOC. Still over soft cap but
    no longer at hard-cap risk (200+ LOC of headroom).
  - inst_fp.zig becomes the natural landing slot for future
    FP-related encoders (e.g., Wasm-FP-128 if v3.0 adds it;
    half-precision FP via fp16 extension).
  - D-141 row's `arm64/inst.zig` slot closes.
  - Pattern matches ADR-0081 / 0082 (pure top-level extraction,
    no struct-method handling).
- **Negative**:
  - 8 caller files need secondary `inst_fp` import. Mitigated
    by clear naming + clustered callers (most FP usage is in
    op_alu_float.zig + op_convert.zig — two files do most of
    the work).
  - inst.zig still over soft cap (1455 > 1000). Honest about
    that — further extraction requires accepting Alternative
    A's fragmentation OR waiting for natural extraction axes
    to surface (e.g., if memory encoders grow with new Wasm
    extensions).
- **Neutral / follow-ups**:
  - SIMD sub-byte encoders (26 LOC) stay in inst.zig for now;
    a follow-up ADR may move them into `inst_neon.zig` if
    that consolidation makes sense at NEON expansion time.
  - x86_64/inst.zig (1328 LOC) is the parallel candidate for
    a future ADR-0085+ when its pressure surfaces; the same
    extraction pattern (FP machinery first) likely applies.

## References

- ADR-0079 — `runner.zig` 3-way split (per-file ADR shape
  precedent).
- ADR-0081 — `emit_setup.zig` pure top-level helper
  extraction (this ADR's primary pattern precedent).
- ADR-0082 — `dispatch_collector_ops.zig` pure data
  extraction.
- ADR-0083 — `validator_simd.zig` struct-method extraction
  (NOT this ADR's pattern — inst.zig has no struct methods).
- ADR-0041 Rev 2 — SIMD validator Phase 14 deferral.
- ADR-0075 §9.12-B — FILE-SIZE-EXEMPT marker (op_simd_int_cmp_lane.zig
  uses this; inst.zig does not).
- D-141 — file-size soft-cap proliferation; this ADR's
  Acceptance closes the `arm64/inst.zig` slot.
- Lesson
  [`2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed`](../lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md)
  — measurement-focused survey discipline.
- Lesson
  [`2026-05-21-cross-file-struct-method-syntax-zig-0-16`](../lessons/2026-05-21-cross-file-struct-method-syntax-zig-0-16.md)
  — does NOT apply here (inst.zig has no methods).
- Source: `src/engine/codegen/arm64/inst.zig` (1807 LOC; FP
  encoders cluster across lines ~285–334 + ~980–1094 +
  ~1100–1129).
- ROADMAP §A2 — file size soft (1000) / hard (2000) caps.

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `8fb73dabf`   | Initial Proposed version.               |
| 2026-05-21 | `3ecc4570`   | **Mid-impl discovery — scope amendment**. First impl attempt (Python extraction script ran successfully — moved 274 LOC across 52 FP encoder blocks; inst.zig dropped 1807 → 1579) revealed broader caller fanout than the ADR's "8 of 23 callers" estimate. Actual usage of FP encoders (`encScvtfX/encUcvtfX/encFcvtX/encF<Cap>/encFmovX/encFsqrtX` pattern): 13 caller files with ~120 call sites total. `bounds_check.zig` uses `encFCmpS`/`encFmovStoFromW` for v128 zero-comparison (18 sites); `emit_test_alu_float.zig` (38 sites); `op_alu_float.zig` (33), `op_convert.zig` (22), plus scattered uses in op_call/op_alu_int/op_control/emit/emit_test_call/emit_test_alu_int/emit_test_local. Carve remains valid (the extracted FP block is structurally cohesive) but caller-side migration is mechanical-but-large: `sed` rewrite of `inst\.encF` → `inst_fp.encF` across 13 files + verification each remains green. Also FP-specific in-source tests (~125 LOC) must move alongside the encoders. **Re-classify implementation as 2-cycle architectural chunk** (per LOOP.md architectural-chunk 3-cycle cap): cycle A executes the file extraction + caller sed-migration; cycle B addresses any test/build fallout. Mid-impl reverted (`git checkout`) until next cycle picks up with full context.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 2026-05-21 | `a117677c`   | **Status: Accepted — impl landed**. Carve completed in single cycle (not 2 as predicted in mid-impl amendment): Python extraction script + caller migration ran cleanly in one pass; only 1 fix-up needed (broader regex `Fcvt\w*` vs literal `Fcvt` to catch suffixed names like `encFcvtzsWFromS`) + dedupe of double `inst_fp` import insertion. inst.zig: 1807 → 1405 LOC (-402); inst_fp.zig: 510 LOC. 127 caller substitutions across 11 files; `const inst_fp = @import("inst_fp.zig");` added beside the existing `const inst` line. Test gate cohort (test-all) + lint green. D-141 arm64/inst.zig slot closes. |
