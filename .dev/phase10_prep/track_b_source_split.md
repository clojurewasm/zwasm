# Phase 10 prep — Track B: D-057 / D-065 source-split partition

> **Doc-state**: ARCHIVED-IN-PLACE

> Status: **DECIDED — 5 design choices confirmed**
> (Q1=4-way, Q2=single ADR, Q3=4-way mirror + `_test.zig` suffix,
> Q4=`_int`/`_float`, Q5=tiered pub). See §8 for resolved
> questions and §9 for the decision record table.
> Decision date: 2026-05-12 (user-confirmed in prep mode session)
> Date: 2026-05-12
> Author: autonomous `/continue` loop, Phase 10 prep mode
> Path note: relocated from `private/notes/p10-prep-track-b-…`
> (gitignored, can't commit) to `.dev/phase10_prep/` per Track A
> precedent.

## §1. Question

What is the concrete file partition for the **5 files** currently
exceeding the §A2 / §14 2000-LOC hard cap?

| Current file                              | LOC  | Functions | Cap-breach % |
|-------------------------------------------|------|-----------|--------------|
| `src/engine/codegen/x86_64/op_simd.zig`   | 4694 | 260       | +135%        |
| `src/engine/codegen/x86_64/op_simd_test.zig` | 2700 | 91 tests | +35%         |
| `src/engine/codegen/x86_64/inst_sse.zig`  | 2464 | 165       | +23%         |
| `src/engine/codegen/arm64/inst_neon.zig`  | 2323 | 176       | +16%         |
| `src/engine/codegen/arm64/op_simd.zig`    | 2307 | 231       | +15%         |
| **Total**                                  | 14488 | 923       |              |

D-057 (x86_64 op_simd.zig + sibling test/inst_sse) and D-065
(arm64 op_simd.zig + inst_neon) jointly track this surface. Both
debts say "single ADR can govern both source-splits OR two ADRs
in a cohort". This Track decides which **and** lands the
partition.

## §2. Precedent — ADR-0030 (D-051 close)

ADR-0030 split `x86_64/emit.zig` (4305 LOC) by **extracting
inline tests** to a sibling `emit_test.zig` as primary path,
deferring the multi-vector structural split. Key lessons that
apply here:

1. **"Test files are discovery surfaces, not authored modules"**
   — accepting test-file LOC overage when test discovery is
   mechanically aggregated is in-line precedent. This bounds
   the test-file scope of Track B.
2. **Defer fine-grained family split** to opportunistic cleanup
   — landing the primary structural split first lets each step's
   correctness be verified independently. ADR-0030 deferred the
   per-op-class family split (`emit_test_alu_int.zig` /
   `emit_test_memory.zig` / …) to Phase 8 opportunistic work.
3. **One private helper goes pub** is acceptable cost
   (`localDisp` precedent).

## §3. Op-family inventory

### §3.1 `x86_64/op_simd.zig` (4694 LOC, 260 fns)

Function class breakdown (from `grep -c "^pub fn emit*"`):

| Class            | Count | Examples                                   | LOC est. |
|------------------|-------|--------------------------------------------|----------|
| `emitV128*`      |    30 | Load/Store/Load*Splat/Load*Lane/Load*Zero/Load*Extend, Const, Not, And, Or, Xor, Andnot, Bitselect | ~900    |
| `emitI*`         |   152 | i8x16/i16x8/i32x4/i64x2 arith + cmp + shift + lane + extend + narrow + popcnt + bitmask | ~2500   |
| `emitF*`         |    54 | f32x4/f64x2 arith + cmp + lane + convert + round + neg/abs/sqrt | ~1100   |
| private helpers  |    24 | `emitV128IntBinop`, `v128MemPrologue`, `emitV128IntCmpSigned/Unsigned`, `emitV128FpCmp`, `emitV128FpMin/Max/Unop/Abs/Neg/Round`, `emitV128AllTrue`, `emitV128IntShift/Neg/Ne`, `emitV128ExtendLow/High`, `v128LoadExtend/Lane`, `v128StoreLane`, `emitConstLoad` | ~200    |

### §3.2 `arm64/op_simd.zig` (2307 LOC, 231 fns)

| Class       | Count | LOC est. |
|-------------|-------|----------|
| `emitV128*` |    31 | ~500    |
| `emitI*`    |   126 | ~1100   |
| `emitF*`    |    54 | ~600    |
| helpers     |    20 | ~100    |

### §3.3 `x86_64/inst_sse.zig` (2464 LOC, 165 fns)

Encoder family groups visible from `grep "^pub fn enc"`:

| Family                       | Examples                                              | LOC est. |
|------------------------------|-------------------------------------------------------|----------|
| Memory load/store (XMM mem)  | `encStoreXmm{F32,F64,V128}Mem*`, `encLoadXmm*`        | ~400    |
| MOV register-shape variants  | `encMovaps`, `encMovups*`, `encMovd*`, `encMovq*`     | ~250    |
| Scalar conversion            | `encCvttScalar2Int`, `encCvtsi2Scalar`                | ~100    |
| SSE packed binary (P*)       | `encPadd{B,W,D,Q}`, `encPsub*`, `encPmull*`, etc.     | ~800    |
| SSE scalar binary            | `encSseScalarBinary`, `encUcomi{ss,sd}`               | ~200    |
| SSE comparison + round       | `encRoundss`, `encRoundsd`, `encSsePackedBinary`      | ~200    |
| Misc + shared shape helpers  | `EncodedInsn` struct + variants                       | ~500    |

### §3.4 `arm64/inst_neon.zig` (2323 LOC, 176 fns)

| Family                       | Examples                                              | LOC est. |
|------------------------------|-------------------------------------------------------|----------|
| Memory load/store (Q-form)   | `encLdrQ*`, `encStrQ*`, `encLd1r*`                    | ~150    |
| Reg-move + foundation        | `encOrrV16B`, `encMovV16B`, `encDup*`, `encAnd/Bic/Eor/Mvn16B` | ~200    |
| Arithmetic                   | `encAdd*`, `encSub*`, `encMul*`, `encAbs*`, `encNeg*`, `encCnt16B` | ~400    |
| Comparison + min/max         | (lower section, by family)                            | ~600    |
| Lane access (UMOV/SMOV/INS)  | `encUmov*`, `encSmov*`, `encIns*`                     | ~400    |
| FP variants                  | `encFAdd*`, `encFMul*`, etc.                          | ~300    |
| Misc encoding helpers        |                                                         | ~250    |

### §3.5 `x86_64/op_simd_test.zig` (2700 LOC, 91 tests)

Test groups mirror handler families (sampled from `grep "^test \""`):

| Group                       | Tests | LOC est. |
|-----------------------------|-------|----------|
| Int arith + saturated       |   ~15 | ~400    |
| Int compare (signed + unsigned) | ~15 | ~400   |
| Int lane (splat/extract/replace/extend/narrow) | ~12 | ~350 |
| Int bitwise + popcnt + bitmask | ~10 | ~300   |
| FP compare + arith          |   ~15 | ~450    |
| FP min/max NaN-correction   |    ~6 | ~250    |
| V128 mem + bitwise + bitselect |  ~10 | ~350   |
| FP lane (splat/extract/replace) | ~8 | ~200    |

Per ADR-0030, **test files are discovery surfaces** — overage is
acceptable but bounded. With 2700 LOC across 91 tests, the file
warrants a family split to align with the source split,
otherwise the test↔handler 1:1 navigation breaks.

## §4. Proposed partition (DECIDED)

### §4.1 Strategy summary

| Decision        | Choice                                                                                                                                                            | Rationale                                                                                                            |
|-----------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| ADR shape       | **Single ADR-0054** covering both x86_64 and arm64 (5 files together)                                                                                             | D-057/D-065 are co-derived from the same gate-dormancy lesson; one ADR keeps the design rationale unified            |
| Granularity     | **4-way per heavy `op_simd.zig` file** (orchestrator + `op_simd_int_arith` + `op_simd_int_cmp_lane` + `op_simd_float`)                                            | 3-way would leave `op_simd_int.zig` at ~1900 LOC (soft-cap re-breach in Phase 10 with GC reftype / memory64 adds). 4-way matches the no-drift principle inherited from Track A |
| Encoder split   | **3-way per encoder file** (`inst_sse` → foundation + packed + scalar; `inst_neon` → foundation + arith + lane_cmp)                                                | Encoder family grouping visible in current file order; no further sub-split needed                                   |
| Test split      | **4-way mirror of source** with strict **`<source>_test.zig` suffix** naming                                                                                       | Source↔test 1:1 navigation; Zig idiomatic suffix convention                                                          |
| File naming     | **`_int_arith` / `_int_cmp_lane` / `_float`** (matches existing `emit_test_int.zig` / `emit_test_float.zig` precedent: `_int` + `_float`)                          | Codebase consistency with existing `_int` + `_float` precedent                                                       |
| Helper visibility | **Tiered pub**: cross-class primitives `pub` in `op_simd.zig`; class-internal recipes stay `fn` in their class file                                              | `pub` keyword itself signals intent (primitive vs recipe); no doc-comment ceremony                                   |
| Legacy `emit_test_int.zig` / `emit_test_float.zig` | **Left as-is** in Track B scope; rename deferred to D-052 prologue-extract or new debt row                                                       | Source `emit.zig` is monolithic; renaming `emit_test_int.zig` → `emit_int_test.zig` would imply non-existent `emit_int.zig` source |

### §4.2 Partition table — x86_64

**Source** (`op_simd.zig` 4-way + `inst_sse.zig` 3-way):

| Current file → New file               | Op group / handler list                                                                                                                                                                                  | LOC est. | Helpers `pub` (tiered) |
|---------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|------------------------|
| `op_simd.zig` (kept; orchestrator)    | `emitConstLoad`, `v128MemPrologue`, `v128LoadExtend/Lane`, `v128StoreLane`, `emitV128IntBinop`, `emitV128AllTrue`, all `emitV128*` handlers (mem + bitwise + bitselect + Not/And/Or/Xor/Andnot)         | ~1100    | `pub`: `v128MemPrologue`, `emitV128IntBinop`, `v128LoadExtend`, `v128LoadLane`, `v128StoreLane`, `emitV128AllTrue` (cross-class primitives) |
| `op_simd_int_arith.zig` (new)         | i8x16/i16x8/i32x4/i64x2 ADD/SUB/MUL + sat arith + shift (Shl/ShrS/ShrU) + Neg/Abs + min/max + avgr + popcnt; helpers: `emitV128IntShift`, `emitV128IntNeg`, related recipes                              | ~1100    | All recipe helpers `fn` |
| `op_simd_int_cmp_lane.zig` (new)      | Int cmp (Eq/Ne/GtS/LtS/LeS/GeS/GtU/LtU/LeU/GeU) + lane (splat/extract/replace) + extend/narrow + extadd-pairwise + extmul + bitmask + AllTrue; helpers: `emitV128IntCmpSigned/Unsigned`, `emitV128IntNe`, `emitV128ExtendLow/High` | ~1300    | All recipe helpers `fn` |
| `op_simd_float.zig` (new)             | All `emitF*` handlers (54 fns: arith + cmp + lane + convert + round + neg/abs/sqrt + pmin/pmax); helpers: `emitV128FpCmp`, `emitV128FpUnop`, `emitV128FpMin/Max`, `emitV128FpAbs/Neg/Round`              | ~1500    | All recipe helpers `fn` |
| `inst_sse.zig` (kept; foundation)     | `EncodedInsn` struct, mem load/store XMM (F32/F64/V128 RBP/RSP/MemBaseIdx variants), MOV register-shape (MOVAPS/MOVUPS/MOVD/MOVQ), scalar cvt helpers (Cvttss/Cvtsi2)                                     | ~1100    | (unchanged)            |
| `inst_sse_packed.zig` (new)           | All `encP*` packed binary encoders (PADD/PSUB/PMUL/PCMP/PMIN/PMAX/PAND/POR/PXOR/PANDN/PSHUFB/PSHUFD/PSLL/PSRL/PSRA/PEXTR/PINSR/PMOVMSKB/PTEST etc.)                                                       | ~900     | (unchanged)            |
| `inst_sse_scalar.zig` (new)           | `encSseScalarBinary`, `encUcomi{ss,sd}`, `encRoundss/sd`, `encSsePackedBinary`, FP packed shapes ADD/SUB/MUL/DIV/MIN/MAX/CMP/SQRT (PS/PD variants)                                                         | ~500     | (unchanged)            |

**Tests** (`op_simd_test.zig` 4-way mirror + strict `_test.zig` suffix):

| Current file → New file                       | Test groups                                                                                       | LOC est. |
|-----------------------------------------------|---------------------------------------------------------------------------------------------------|----------|
| `op_simd_test.zig` (kept; aggregator)         | V128 mem + bitwise + bitselect tests + import statements for sibling test modules                 | ~400     |
| `op_simd_int_arith_test.zig` (new)            | int arith / sat / shift / min-max / neg/abs / avgr / popcnt tests                                 | ~700     |
| `op_simd_int_cmp_lane_test.zig` (new)         | int cmp (signed + unsigned) + lane (splat/extract/replace) + extend/narrow + bitmask + AllTrue + alias-stash tests | ~900     |
| `op_simd_float_test.zig` (new)                | FP arith + cmp + min-max NaN-correction + lane + convert + round + pmin/pmax tests                | ~700     |

### §4.3 Partition table — arm64

**Source** (`op_simd.zig` 4-way + `inst_neon.zig` 3-way):

| Current file → New file                | Op group / handler list                                                                                                       | LOC est. | Helpers `pub` (tiered) |
|----------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|----------|------------------------|
| `op_simd.zig` (kept; orchestrator)     | Helpers + all `emitV128*` handlers (mem + bitwise)                                                                            | ~500     | Cross-class primitives `pub` (mirror x86_64 shape) |
| `op_simd_int_arith.zig` (new)          | Int ADD/SUB/MUL + sat + shift + min/max + neg/abs + avgr + popcnt                                                              | ~600     | recipe helpers `fn`    |
| `op_simd_int_cmp_lane.zig` (new)       | Int cmp + lane access + extend/narrow + bitmask + AllTrue                                                                      | ~600     | recipe helpers `fn`    |
| `op_simd_float.zig` (new)              | All `emitF*` handlers (54 fns)                                                                                                | ~600     | recipe helpers `fn`    |
| `inst_neon.zig` (kept; foundation)     | Memory (LDR/STR Q-form, LD1R), reg-move (ORR/MOV/DUP/AND/BIC/EOR/MVN), Q-shape helpers                                        | ~700     | (unchanged)            |
| `inst_neon_arith.zig` (new)            | ADD/SUB/MUL/MIN/MAX/ABS/NEG/CNT/AVGR/sat-arith encoders (per-shape variants)                                                  | ~900     | (unchanged)            |
| `inst_neon_lane_cmp.zig` (new)         | UMOV/SMOV/INS lane access + CMEQ/CMGT/CMHI/CMHS comparison + FP cmp variants                                                  | ~750     | (unchanged)            |

**Tests** (arm64 `op_simd_test.zig` if exists; mirror x86_64 shape):

| Current file → New file                       | Test groups                                          | LOC est. |
|-----------------------------------------------|------------------------------------------------------|----------|
| `op_simd_test.zig` (kept; aggregator)         | V128 mem + bitwise tests + sibling import statements | varies   |
| `op_simd_int_arith_test.zig` (new)            | int arith / sat / shift / min-max tests              | varies   |
| `op_simd_int_cmp_lane_test.zig` (new)         | int cmp / lane / extend / bitmask tests              | varies   |
| `op_simd_float_test.zig` (new)                | FP arith / cmp / lane / convert tests                | varies   |

### §4.4 Why 4-way granularity (chosen over 3-way)

The original draft proposed 3-way (`op_simd` + `op_simd_int` +
`op_simd_float`). User judgment (Q1=B) chose 4-way because:

- **3-way leaves `op_simd_int.zig` at ~1900 LOC** (152 emitI*
  handlers + cmp/shift/extend helpers). Soft cap is 1000;
  hard cap 2000. 1900 LOC is structural debt waiting to
  re-trip — Phase 10's GC reftype packing handlers + memory64
  lane variants are SIMD-adjacent and will land in the same
  file family.
- **No-drift principle (Track A inheritance)**: if 4-way is
  the structurally correct answer for SIMD's int subspace
  (arith recipes are distinct from cmp/lane recipes), name it
  now. Deferring to a second-pass split mid-Phase 10 would
  duplicate the migration cost.
- **Recipe boundary is meaningful**:
  - `_int_arith`: ALU operations that use binop recipe
    (`emitV128IntBinop` shape: 2-op MOVAPS preamble + encoder
    dispatch).
  - `_int_cmp_lane`: comparison (PCMPGT-based recipes with
    swap/NOT branches), lane access (PSHUFD/PSHUFB sequences),
    extend/narrow (saturating pack/unpack), bitmask
    (PMOVMSKB direct). These share **none** of the
    `emitV128IntBinop` recipe shape.

ADR-0030's "defer fine-grained split to opportunistic
cleanup" guidance was for emit.zig's ALU-dominated content
where 3-way was sufficient. SIMD's int subspace has more
distinct recipe families — the principled split is one level
finer.

### §4.5 Why kept-file naming (`op_simd.zig`) instead of renaming

ADR-0030 precedent: kept the original name for the slimmed-down
orchestrator and added sibling files. Same pattern here:

- `op_simd.zig` (kept) = orchestrator + V128 mem/bitwise; consumers
  importing `op_simd` still resolve the same set of `pub fn
  emitV128*` symbols + the now-`pub` cross-class primitives
  (per §4.6 tiered visibility).
- New siblings export `pub fn emitI*` and `pub fn emitF*`
  respectively; consumers must update import paths for those
  handlers. The dispatch site (`src/engine/codegen/x86_64/op_simd_
  dispatch.zig` if exists, or whichever file routes per opcode)
  updates to multi-import. Mechanical change.

### §4.6 Tiered helper visibility (Q5 decision)

Visibility rule (codified in ADR-0054):

- **`pub` from day 1** — cross-class primitives that have a
  foreseeable consumer outside `op_simd*` (Phase 10 GC,
  memory64, future Wasm proposals):
  - `emitV128IntBinop` (generic 2-op shape)
  - `v128MemPrologue` (memory addressing — V128 mem + future
    GC mem)
  - `v128LoadExtend`, `v128LoadLane`, `v128StoreLane` (lane
    mem primitives)
  - `emitV128AllTrue` (control-flow primitive — reusable for
    GC null check)
  - ADR-0053 spilled-V128 ABI helpers (`xmmLoadSpilledV128` /
    `xmmDefSpilledV128` / `xmmStoreSpilledV128`)
- **`fn` (file-private)** — class-internal recipes specific
  to one handler family:
  - `emitV128IntCmpSigned` / `emitV128IntCmpUnsigned` (signed-
    int PCMPGT recipe specifics) → `op_simd_int_cmp_lane.zig`
  - `emitV128FpCmp` / `emitV128FpMin` / `emitV128FpMax` /
    `emitV128FpUnop` / `emitV128FpAbs` / `emitV128FpNeg` /
    `emitV128FpRound` → `op_simd_float.zig`
  - `emitV128IntShift` / `emitV128IntNeg` / `emitV128IntNe` →
    their class file
  - `emitV128ExtendLow` / `emitV128ExtendHigh` →
    `op_simd_int_cmp_lane.zig` (int-only semantics)

**Operational rule** (codified in ADR-0054 §Consequences):
no `// internal use only` doc-comments — the `pub`/`fn`
keyword itself signals the contract. When Phase 10 surfaces
a new cross-class consumer for an `fn` helper, flip it to
`pub` in that chunk (cheap, ~1 LOC).

### §4.7 Test file naming convention (Q3/Q4 decision)

**Rule**: for files where source and tests are 1:1 mirror-
split, use `<source>_test.zig` suffix convention:

| Source                       | Test                              |
|------------------------------|-----------------------------------|
| `op_simd.zig`                | `op_simd_test.zig` (existing)     |
| `op_simd_int_arith.zig`      | `op_simd_int_arith_test.zig`      |
| `op_simd_int_cmp_lane.zig`   | `op_simd_int_cmp_lane_test.zig`   |
| `op_simd_float.zig`          | `op_simd_float_test.zig`          |

**Exception — legacy `emit_test_int.zig` / `emit_test_float.zig`**:
these were created as a tests-only family split of monolithic
`emit.zig` (no `emit_int.zig` / `emit_float.zig` source files
exist). Renaming them to `emit_int_test.zig` / `emit_float_test.zig`
would imply non-existent source files. **Leave as-is** in
Track B scope; file a new debt row that defers the cleanup
to when `emit.zig` source split happens (D-052 prologue
extract or follow-up). The new debt is filed in Track B's
final chunk (9.9-h-20).

## §5. ADR-0054 draft skeleton

```markdown
# 0054 — Split op_simd.zig + inst_{sse,neon}.zig per §A2 cap (D-057 + D-065)

- Status: Accepted
- Date: 2026-05-{XX} (lands when prep mode closes)
- Author: Phase 10 prep cycle (autonomous /continue loop)
- Tags: roadmap, phase9-close, refactor, file-shape, jit, simd, x86_64, arm64, mirror-adr-0030

## Context

5 SIMD-adjacent codegen files exceed §A2's 2000-LOC hard cap as
of 2026-05-12:

| File | LOC | Cap-breach |
|------|-----|------------|
| `src/engine/codegen/x86_64/op_simd.zig`      | 4694 | +135% |
| `src/engine/codegen/x86_64/op_simd_test.zig` | 2700 | +35%  |
| `src/engine/codegen/x86_64/inst_sse.zig`     | 2464 | +23%  |
| `src/engine/codegen/arm64/inst_neon.zig`     | 2323 | +16%  |
| `src/engine/codegen/arm64/op_simd.zig`       | 2307 | +15%  |

D-057 + D-065 jointly tracked the breach. The 2026-05-11 audit
identified the root cause: `scripts/file_size_check.sh` was
opt-in (no git pre-commit hook with hyphen-form filename;
`.githooks/pre_commit` underscore-form didn't fire). The hook
rename + warn-only-mode-pending-discharge landed
`9.9-h-14`-adjacent.

ADR-0030 (D-051 close — x86_64 emit.zig split) established the
precedent: extract inline tests as primary path, defer
fine-grained family split. The same shape applies here, plus
**source-side** splits because op_simd.zig's bloat is overwhelmingly
in handler bodies (not tests).

## Decision

**4-way `op_simd.zig` source split + 3-way encoder split + 4-way
test mirror with `<source>_test.zig` suffix**, single ADR
covering both arches, tiered helper pub visibility. See
`.dev/phase10_prep/track_b_source_split.md` §4.2 + §4.3 for the
partition tables. Summary:

- **x86_64**:
  - source: `op_simd.zig` → {`op_simd`, `op_simd_int_arith`,
    `op_simd_int_cmp_lane`, `op_simd_float`} (4-way)
  - test: `op_simd_test.zig` → {`op_simd_test`,
    `op_simd_int_arith_test`, `op_simd_int_cmp_lane_test`,
    `op_simd_float_test`} (4-way mirror, `_test.zig` suffix)
  - encoder: `inst_sse.zig` → {`inst_sse`, `inst_sse_packed`,
    `inst_sse_scalar`} (3-way)
- **arm64** (parallel shape):
  - source: `op_simd.zig` → {`op_simd`, `op_simd_int_arith`,
    `op_simd_int_cmp_lane`, `op_simd_float`} (4-way)
  - test: mirror x86_64 shape
  - encoder: `inst_neon.zig` → {`inst_neon`, `inst_neon_arith`,
    `inst_neon_lane_cmp`} (3-way)

### Naming convention (load-bearing)

When source files are partition-split with 1:1 test mirror, use
strict **`<source>_test.zig`** suffix:

- `op_simd_int_arith.zig` ↔ `op_simd_int_arith_test.zig` ✓
- NOT `op_simd_test_int_arith.zig` (legacy `_test_<family>`
  middle-form was a tests-only family split shape for monolithic
  `emit.zig`, which lacks corresponding source files).

Legacy `emit_test_int.zig` / `emit_test_float.zig` remain as-is;
renaming to `emit_int_test.zig` / `emit_float_test.zig` is
deferred to when `emit.zig` itself splits into `emit_int.zig` /
`emit_float.zig` (D-052 prologue extract or follow-up). New debt
row D-081 tracks this dependency.

### Helper visibility — tiered pub

- **`pub` from day 1** (cross-class primitives in `op_simd.zig`):
  `emitV128IntBinop`, `v128MemPrologue`, `v128LoadExtend/Lane`,
  `v128StoreLane`, `emitV128AllTrue`, ADR-0053 spilled-V128 ABI
  helpers.
- **`fn` (file-private)** in class file: cmp / min-max / shift /
  extend / round recipes.
- No `// internal use only` doc-comments — `pub`/`fn` keyword
  signals contract directly.

### Migration plan

6 chunks (9.9-h-15..-20). Each chunk lands the split +
import-fixup + test gate green on Mac + OrbStack. Post-discharge
target LOC: every file ≤ 1500 LOC (~75% of cap; 4-way grants
extra headroom for Phase 10 SIMD-adjacent growth).

After chunk 9.9-h-20, `scripts/file_size_check.sh` flips from
warn-only to hard-gate (the 2026-05-11 hook activation reverted
to warn-only pending D-057/D-065 discharge). The same chunk
files **new debt D-081** for the deferred legacy `emit_test_*`
rename.

## Alternatives considered

### A — Two ADRs (one per arch, ADR-0054 x86_64 + ADR-0055 arm64)

Rejected. D-057 + D-065 share the same root cause (gate dormancy)
and the same discharge shape (4-way structural split mirroring
ADR-0030's pattern). Two ADRs would duplicate context and risk
drift between the two arches' final shape. One ADR keeps the
design unified; the 6 migration chunks are independent enough
that they don't need separate ADRs.

### B — 3-way granularity (`op_simd` + `op_simd_int` + `op_simd_float`)

Rejected (initial draft). 3-way leaves `op_simd_int.zig` at
~1900 LOC — soft-cap re-breach guaranteed in Phase 10 once GC
reftype packing + memory64 lane variants land. The no-drift
principle (inherited from Track A's Option 3 decision lens)
demands the structurally correct granularity now, not a
second-pass split mid-Phase 10. 4-way separates the
`emitV128IntBinop` recipe family from the cmp/lane/extend
recipe families, which share no implementation shape.

### C — Keep test files monolithic; only split source

Rejected. With 2700 LOC of tests, the test↔handler navigation
breaks once source is split into 3 files. Mirroring the split
preserves the 1:1 source↔test discoverability.

### D — Wait until Phase 11+ (folded into bench infra cohort per Track A)

Rejected. D-057/D-065 are independent of Track A's §9.10 →
Phase 11 migration. The cap breach blocks file_size_check.sh's
hard-gate restoration, which in turn allows further drift; this
is structural debt unrelated to bench infra.

## Consequences

### Positive

- D-057 + D-065 close jointly.
- `file_size_check.sh` flips back to hard-gate, preventing
  recurrence.
- Phase 10 (GC + EH + tail call + memory64) opens with all
  codegen files within cap; new SIMD-adjacent handlers added in
  Phase 10 won't trip cap warnings.
- Test↔source 1:1 navigation preserved.

### Negative

- 6 chunks of migration work. Each chunk is mechanical
  (Edit-move-imports-test-commit) but cumulative wall-clock
  ~3–5h of autonomous loop time.
- Some private helpers may need to become `pub` for cross-file
  test access (ADR-0030 precedent: `localDisp` went pub).
- Brief period where dispatch site (`op_simd_dispatch.zig` or
  equivalent) imports 3 modules instead of 1; readability tradeoff.

### Neutral / follow-ups

- Family-split of test files (e.g. `op_simd_test_int_arith.zig` /
  `op_simd_test_int_cmp.zig`) deferred to Phase 12+ opportunistic
  cleanup; not a debt row unless a consumer pattern surfaces.
- `inst_sse_packed.zig` and `inst_sse_scalar.zig` are encoder-
  only; no test split needed (encoders are tested via
  `op_simd_test*` already).

## References

- ADR-0030 (D-051 close — x86_64 emit.zig split; pattern template)
- D-057 (this ADR's primary discharge target — x86_64)
- D-065 (this ADR's secondary discharge target — arm64)
- ROADMAP §A2 / §14 (file-size cap)
- `.dev/phase10_prep/track_b_source_split.md` (this Track's
  deliverable — partition tables + migration plan)
- 2026-05-11 ADR audit SUMMARY §4.2 (root-cause: gate dormancy)
- 2026-05-11 lesson: `.dev/lessons/2026-05-11-…` (gate dormancy)

## Revision history

| Date       | Commit       | Summary                                          |
|------------|--------------|--------------------------------------------------|
| 2026-05-XX | `<backfill>` | Initial Decision; 3-way split per arch (6 chunks total) |
```

## §6. Migration plan — 6 chunks (revised for 4-way granularity)

Sized for the per-task TDD loop in autonomous `/continue` mode
post-prep. Each chunk lands in a single commit with test gate
green on Mac + OrbStack (windowsmini deferred per ADR-0049).

| Chunk        | Scope                                                                                                                                                                                                                              | Estimated LOC moved | Risk          |
|--------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------|---------------|
| 9.9-h-15     | x86_64 `op_simd.zig` → {`op_simd`, `op_simd_int_arith`, `op_simd_int_cmp_lane`, `op_simd_float`} 4-way source split; tiered pub for cross-class primitives                                                                          | ~3500 (moved)       | medium-high (152 emitI* + 54 emitF* import-site updates; biggest chunk) |
| 9.9-h-16     | x86_64 `op_simd_test.zig` → {`op_simd_test`, `op_simd_int_arith_test`, `op_simd_int_cmp_lane_test`, `op_simd_float_test`} 4-way mirror with strict `_test.zig` suffix                                                              | ~2200 (moved)       | low (test-only)            |
| 9.9-h-17     | x86_64 `inst_sse.zig` → {`inst_sse`, `inst_sse_packed`, `inst_sse_scalar`} 3-way encoder split                                                                                                                                       | ~1300 (moved)       | medium (165 encoders, consumed by op_simd*) |
| 9.9-h-18     | arm64 `op_simd.zig` → {`op_simd`, `op_simd_int_arith`, `op_simd_int_cmp_lane`, `op_simd_float`} 4-way source split + `op_simd_test.zig` mirror (if exists; else extract from inline tests)                                          | ~1600 (moved)       | medium (mirror of 9.9-h-15) |
| 9.9-h-19     | arm64 `inst_neon.zig` → {`inst_neon`, `inst_neon_arith`, `inst_neon_lane_cmp`} 3-way encoder split                                                                                                                                   | ~1500 (moved)       | medium                     |
| 9.9-h-20     | Flip `scripts/file_size_check.sh` warn → gate; remove `(warn-only, see D-057)` note from `gate_commit.sh`; close D-057 + D-065; **file new debt row D-081 with load-bearing deferral spec (see §6.1)** | ~30 (config)        | low                        |

### §6.1 Deferral accountability — new debt D-081 (legacy `emit_test_*` rename)

Per the user's "先送り先で責任をもって解消" principle, the
deferred legacy-naming cleanup lands as a load-bearing debt row
filed in chunk 9.9-h-20:

**D-081 row body** (drafted; lands in chunk 9.9-h-20):

> **Legacy `emit_test_int.zig` / `emit_test_float.zig` rename to
> `<source>_test.zig` suffix convention**. Per ADR-0054 §"Naming
> convention", the strict suffix shape is `<source>_test.zig`
> (e.g. `op_simd_int_arith.zig` ↔ `op_simd_int_arith_test.zig`).
> The legacy `emit_test_int.zig` / `emit_test_float.zig` files
> are tests-only family splits of monolithic `emit.zig` (no
> corresponding `emit_int.zig` / `emit_float.zig` source exists).
> Renaming to `emit_int_test.zig` / `emit_float_test.zig`
> without source split would imply non-existent source files —
> deferred to when `emit.zig` itself splits.
>
> - **Status**: `blocked-by: emit.zig source split (D-052 prologue extract OR follow-up source-family split creating emit_int.zig / emit_float.zig)`
> - **Discharge trigger**: in the same chunk that splits
>   `emit.zig` source into `emit_int.zig` + `emit_float.zig`,
>   rename `emit_test_int.zig` → `emit_int_test.zig` and
>   `emit_test_float.zig` → `emit_float_test.zig` via git mv +
>   update root-imports in `src/zwasm.zig`. Mechanical change;
>   bundled with the source split chunk so the naming
>   transition is atomic.
> - **Cross-arch**: same applies to `arm64/emit_test_*.zig` if
>   parallel files exist; check at discharge time.
> - **Re-evaluation**: barrier dissolves when D-052's
>   "approach to 1000-LOC soft cap" trigger fires (per ADR-0030
>   §"Tier-2 deferral"). The current `emit.zig` is **1983 LOC**
>   (per ADR-0030 Revision History 2026-05-11), already past
>   the 1000 soft cap. D-052's trigger has effectively fired;
>   discharge becomes `now`-eligible whenever the loop has
>   capacity for the emit.zig source split. **Re-walk this
>   barrier on every resume per `/continue` Step 0.5** (cheap
>   grep for `emit_int.zig` existence).
> - **Refs**: D-052 (prologue extract trigger; primary
>   dependency), ADR-0030 §"Tier-2 deferral", ADR-0054
>   §"Naming convention".

Chunks 15-19 are independent at file granularity but **must
sequence after Track A/C/D implementation chunks** (those
land first per prep mode contract). Chunk 20 is the gate
restore + debt close; must be the last of the 6.

### §6.1 Per-chunk recipe (Edit-move-import-test pattern)

For each split chunk (15-19):

1. Create new sibling file(s) with the partitioned handlers.
2. Move handler bodies from current file to new file(s) (`git
   mv` semantics manually — Edit-delete from source +
   Write-create new).
3. Update imports in:
   - `src/engine/codegen/<arch>/op_simd_dispatch.zig` (or
     equivalent dispatch site)
   - Any other consumer (likely `src/engine/codegen/<arch>/
     emit.zig` directly references some `emitI*` handlers in
     Phase 9 paths)
4. Make 0–2 private helpers `pub` if cross-file calls require
   (per ADR-0030 `localDisp` precedent).
5. Run `zig build test` + parallel OrbStack gate.
6. Commit `refactor(p9-close): §9.9 / 9.9-h-{N} — split <file>
   per ADR-0054`.

## §7. Effect on Tracks C / D + Phase 10 entry

- **Track C (ADR-0029 path A vs B)** is orthogonal — skip
  vocabulary decision unaffected.
- **Track D (Phase 10 transition gate doc)**: gate doc's "code
  hygiene" §3 checklist should include "all file_size_check
  hard-cap breaches resolved (D-057 / D-065 closed)" as one
  exit checkbox. This Track's discharge IS one of Phase 10
  entry's checklist items.
- **Phase 10 chunk count budget**: 6 chunks of migration land
  before §9.10/§9.11/§9.12 close. Compared to Track A's
  Option (3) net cost (1 chunk for §9.10 migration), Track B
  is the **single largest prep-driven implementation effort**.

## §8. Resolved questions

1. **Granularity**: 4-way per heavy `op_simd.zig` file
   (`op_simd` + `op_simd_int_arith` + `op_simd_int_cmp_lane` +
   `op_simd_float`). 3-way left `op_simd_int.zig` at ~1900 LOC
   which would re-trip in Phase 10.
2. **ADR shape**: single ADR-0054 covering both arches. Shared
   root cause (gate dormancy) and shared shape (structural
   split mirroring ADR-0030); two ADRs would duplicate context.
3. **Test split scope**: 4-way mirror of source split with
   strict `<source>_test.zig` suffix convention. Legacy
   `emit_test_int.zig` / `emit_test_float.zig` left as-is;
   rename deferred to when `emit.zig` source split happens
   (new debt D-081 tracks this).
4. **Naming**: `_int` + `_float` (matches existing
   `emit_test_int.zig` + `emit_test_float.zig` codebase
   precedent). Initial proposal `_int` + `_fp` was incorrect
   (precedent mismatch); corrected to `_int` + `_float`.
5. **Helper visibility**: tiered pub. Cross-class primitives
   (`emitV128IntBinop`, `v128MemPrologue`, `v128LoadExtend/
   Lane`, `v128StoreLane`, `emitV128AllTrue`, ADR-0053
   spilled-V128 helpers) `pub` from day 1. Class-internal
   recipes (cmp/min-max/shift/extend) stay `fn` in their
   class file. No `// internal use only` doc-comments — the
   `pub`/`fn` keyword itself is the contract.

## §9. Decision record

| Date       | Decision                                                                                       | Recorded by              |
|------------|------------------------------------------------------------------------------------------------|--------------------------|
| 2026-05-12 | Q1=B (4-way), Q2=A (single ADR), Q3=B+γ (4-way mirror + suffix convention, legacy left as-is), Q4=(a) `_int`/`_float`, Q5=C (tiered pub) | user (prep mode session) |

## §10. References

- `.dev/decisions/0030_x86_64_emit_test_split.md` (precedent —
  D-051 close)
- `.dev/debt.yaml` D-057 (x86_64 hard-cap breach), D-065 (arm64
  hard-cap breach)
- `.dev/phase10_prep.md` §"Track B"
- `.dev/phase10_prep/track_a_9.10_scope.md` (Track A — sibling
  prep deliverable)
- ROADMAP §A2 / §14 (file-size cap)
- `src/engine/codegen/{x86_64,arm64}/{op_simd,inst_*}.zig`
  (the 5 files this Track partitions)
- `scripts/file_size_check.sh` (gate; currently warn-only
  pending Track B discharge)
- `scripts/gate_commit.sh` (per-commit wrapper)
- 2026-05-11 ADR audit SUMMARY §4.2 (root-cause analysis)
