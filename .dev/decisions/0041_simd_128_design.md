# 0041 — SIMD-128 design framing (Phase 9 / §9.9)

- **Status**: Accepted
- **Date**: 2026-05-09
- **Author**: Phase 9 / §9.9/9.2 autonomous /continue cycle
- **Tags**: roadmap, phase9, simd, jit, validator, ir, neon, sse4_1

## Context

ROADMAP §9.9 (SIMD-128) opened at Phase 8 close (`f0faf1d7`).
Goal: `simd.wast` spec test fail=skip=0 across both backends
(ARM64 NEON + x86_64 SSE4.1) with SSE4.1 as minimum baseline
(runtime feature detection refuses startup on older CPUs).

Step 0 survey at `private/notes/p9-9.1-simd-survey.md` (302
lines, gitignored, landed at commit `ca58cfc5`) covered five
reference codebases:

- **wasmtime/cranelift**: ISLE-DSL declarative lowering. Out
  of reach for Zig (DSL-bound).
- **wasmtime/winch**: single-pass visitor pattern, but SIMD
  is currently a no-op macro — the design idiom is closer
  to zwasm v2's P6 single-pass JIT, but the implementation
  isn't substantive enough to mirror.
- **wasmer compiler-singlepass**: minimal SIMD coverage; per-
  target emit modules.
- **zware**: Zig idiom; doesn't yet implement SIMD.
- **zwasm v1 W43-W44 + W54 post-mortem**: parallel `simd_xreg`
  cache (separate from main FP machinery) created implicit-
  contract sprawl flagged in the post-mortem as anti-pattern.
  v2 must structurally avoid the cache split.

The Wasm spec SIMD-128 proposal spans **~415 op variants
across 59 spec test files** (`~/Documents/OSS/WebAssembly/
testsuite/proposals/simd/*.wast`); zwasm v2's `src/ir/zir.
zig` already pre-declares 171 ZirOp variants across 8
semantic categories (load/store / lane access / int arith /
float arith / bitwise / compare / shuffle / conversion).
Existing infrastructure:

- `src/feature/simd_128/register.zig` — placeholder feature-
  register entry per ADR-0023 §4.5 (not yet activated).
- `src/ir/zir.zig:21:ValType` — `.v128` variant present.
- `src/engine/codegen/shared/regalloc.zig:Allocation` —
  `max_reg_slots_fp = 13` covers ARM64 V16-V28; XMM0-XMM15
  for x86_64 (FP-class slot pool documented at lines 99-119
  as already extending to SIMD).

## Decision

Phase 9 SIMD-128 lands as **one ZirOp per `<shape>.<op>`
combination** (shape-as-variant), reusing the FP-class
register pool (with shape tagging on the RegClass hint axis
to disambiguate scalar 8-byte vs v128 16-byte spill stride),
registered into the central dispatch table via the existing
`src/feature/simd_128/register.zig` slot. Spec-fidelity is
preserved by explicit IEEE-754 trap handling on ARM64 NEON
(overriding NEON's silently-saturating defaults). SSE4.1 is
the x86_64 minimum baseline.

### 1. ZirOp catalogue: shape-as-variant

The 415 spec ops decompose into ~171 `<shape>.<op>` ZirOp
variants (already pre-declared in `src/ir/zir.zig`). Each
ZirOp encodes the lane shape (i8x16 / i16x8 / i32x4 / i64x2
/ f32x4 / f64x2) + the operation as a single enum tag:

```zig
// Already present in zir.zig (verified by survey at line
// catalogue):
pub const ZirOp = enum {
    // ... existing scalar ops ...
    @"i8x16.add", @"i8x16.sub", @"i8x16.mul",
    @"i16x8.add", @"i16x8.sub", @"i16x8.mul",
    @"i32x4.add", @"i32x4.sub", @"i32x4.mul",
    // ... etc ...
};
```

**Why shape-as-variant** (not shape-as-payload):

- **P6 single-pass JIT**: one switch arm per ZirOp keeps
  emit's hot loop O(1) per op. Encoding shape as payload
  would require nested dispatch (`if (op == .vector_add) {
  switch (payload.shape) ...; }`) — extra branch in the hot
  loop.
- **§A12 dispatch-table-not-pervasive-if**: per-op handlers
  register into the central dispatch table; shape-as-payload
  would need 6 sub-handlers per op, defeating the table's
  O(1) lookup discipline.
- **§14 forbidden-list (single field two semantic axes)**:
  shape and op together identify the encoding — mixing them
  into one slot creates the dual-axis hazard.

The 171-variant catalogue costs ~3 KB at runtime (one
function pointer per ZirOp in the dispatch table) — well
within P3 cold-start budget.

### 2. Register-class extension: reuse FP pool with shape tag

v128 vregs occupy the **same register file** as scalar FP:
ARM64 V0-V31 (V16-V28 allocatable per ADR-0027 + D-037);
x86_64 XMM0-XMM15. No new register class is introduced —
the `RegClass.fpr` enum value covers both scalar f32/f64 and
v128 vregs.

**However**, spill-frame stride differs:
- Scalar f32/f64 vreg → 8-byte spill slot (current shape).
- v128 vreg → 16-byte spill slot (alignment requirement on
  both arches: NEON `LDR Q<n>` / SSE4.1 `MOVDQA` need 16-byte
  alignment for fast paths).

Per `single_slot_dual_meaning.md` (§14 enforcement), the
slot ID alone cannot encode the stride. The disambiguation
goes on a **separate axis**: a per-vreg `shape: ShapeTag`
hint passed alongside the slot ID at emit time.

```zig
// New addition to the regalloc.Allocation surface:
pub const ShapeTag = enum(u2) { scalar, v128, _ };
pub fn slotShape(self: Allocation, vreg: usize) ShapeTag {
    // Reads from a parallel `shapes: []const u2` slice,
    // populated at compute() time from the IR's
    // ZirOp metadata (e.g. `.@"v128.load"` produces
    // `.v128`).
}
```

Spill-frame layout: per-shape compaction defers to Phase 15
(per ADR-0038's class-aware-allocation deferral); §9.9 ships
the **conservative** `each-vreg-pays-its-stride` shape — a
single function frame may have 16-byte slots for v128 vregs
interleaved with 8-byte slots for scalar. The frame is
sized as `sum(vreg_strides)` rather than the optimal packing.

**Why deferred packing**: tighter packing is the same shape
of work as Phase 15's class-aware allocator (per ADR-0038);
running it twice would duplicate the liveness type-tagging
prerequisite. §9.9 accepts the conservative frame size; the
~30-50% potential saving on spill-frame bytes lands as a
Phase 15 follow-up.

### 3. Feature-register pattern via `feature/simd_128/`

All 171 SIMD ZirOps register into the central dispatch table
at startup via `src/feature/simd_128/register.zig` (per
ADR-0023 §4.5). The validator / parser / interpreter / emit
**never** `@import("feature/simd_128/...")` directly —
they consult the dispatch table only. Per §A12, this avoids
`if (simd_enabled)` branching in shared code.

```zig
// src/feature/simd_128/register.zig (current placeholder
// becomes load-bearing in §9.9/9.2):
pub fn register() void {
    inline for (simd_ops_table) |entry| {
        dispatch.installValidator(entry.op, entry.validate);
        dispatch.installLowerer(entry.op, entry.lower);
        dispatch.installEmitter(entry.op, entry.emit_arm64,
                                          entry.emit_x86_64);
    }
}
```

The same feature-register pattern carries forward to Phase 10
(GC, EH, tail-call, memory64) and beyond — SIMD-128 is the
**first non-MVP feature** to exercise the mechanism non-
trivially.

### 4. Spec-fidelity: NEON IEEE-754 trap on specials

ARM64 NEON's default float behaviour silently saturates on
IEEE-754 special values (NaN, ±Inf) for some ops, while the
Wasm spec mandates either trap or specific-bit-pattern
returns. The emit handlers for f32x4 / f64x2 ops must:

1. Pre-check operands for special values where Wasm demands
   trap (e.g. `i32x4.trunc_sat_f32x4_s` requires saturate-
   to-spec-defined-bound on NaN, not silent saturate).
2. Use `FPCR` configuration where applicable (default-NaN +
   trap-on-invalid-op flags).
3. For ops with subtle quirks (e.g. `f32x4.min` / `.max`
   propagate -0 vs +0 per spec, but NEON's `FMIN` / `FMAX`
   do not), emit a manual sequence with explicit zero-sign
   handling.

The spec-fidelity audit happens per-op during 9.5/9.6 ARM64
emit; the test suite (`simd.wast`) encodes the canonical
behaviour. Each handler carries a `Wasm spec §X.Y.Z` citation
in its docstring per `.claude/rules/spec_citation.md`.

### 5. SSE4.1 minimum baseline

Required SSE4.1 instructions confirmed:

- **`PMULLD`** — `i32x4.mul` (SSE4.1 only; SSE2's `PMULLW`
  is i16x8-scoped).
- **`PINSRB` / `PINSRW` / `PINSRD`** — lane-replace ops on
  i8x16 / i16x8 / i32x4 (SSE4.1; SSE2 has only i16x8 form).
- **`PBLENDVB`** — `v128.bitselect` mask blend (SSE4.1).

SSSE3 instructions (`PSHUFB`) are also load-bearing for
`i8x16.shuffle` but are subsumed by SSE4.1.

Runtime feature detection: `src/feature/simd_128/register.
zig:register()` checks `cpuid` SSE4.1 bit (CPUID.01H:ECX
bit 19) at startup; if absent, `register()` returns early
without installing handlers, and any SIMD op encountered
later traps with `UnsupportedFeature` rather than
silently miscompiling.

### Concrete chunk plan (refining ROADMAP §9.9 rows)

| Row    | Description                                    | Estimated LOC |
|--------|------------------------------------------------|---------------|
| 9.2    | This ADR (design framing).                     | 0 (doc-only)  |
| 9.3    | Validator extension: v128 type-stack + per-op signatures via dispatch-table install. | ~150 src + ~80 tests |
| 9.4    | IR extension: ZirOp catalogue (already pre-declared, activate) + lower paths. Adds `Allocation.shapeTag()` API. | ~450 src + ~120 tests |
| 9.5    | ARM64 NEON emit: load/store + lane access + int arithmetic (i8x16 / i16x8 / i32x4 / i64x2 add/sub/mul/min/max/avgr). | ~900 src + ~250 tests |
| 9.6    | ARM64 NEON emit: float arith (f32x4 / f64x2 with IEEE-754 trap-on-specials) + comparison + shuffle + conversion. | ~900 src + ~250 tests |
| 9.7    | x86_64 SSE4.1 emit: load/store + lane access + int arithmetic. | ~900 src + ~250 tests |
| 9.8    | x86_64 SSE4.1 emit: float arith + comparison + shuffle + conversion. | ~900 src + ~250 tests |
| 9.9    | `simd.wast` spec test wired in; fail=skip=0 across both backends; 3-host gate. | ~50 (runner glue) |
| 9.10   | SIMD smoke benches against wasmtime + wazero + wasmer; recorded to `bench/results/history.yaml`. | ~30 (script wiring) |
| 9.11   | Phase-9 boundary `audit_scaffolding` pass + SHA backfill. | doc-only      |
| 9.12   | Open §9.10 inline + flip phase tracker.        | doc-only      |

Total: ~4500 LOC across 6 implementation chunks, matching
the survey's estimate.

## Alternatives considered

### Alternative A — Shape-as-payload (one ZirOp per op-family)

- **Sketch**: 27 op-family ZirOps (e.g. `simd.add`, `simd.
  sub`, `simd.mul`, ...) each carry a `shape: ShapeTag`
  payload byte; emit handlers dispatch on the payload.
- **Why rejected**: nested dispatch defeats P6's hot-loop
  shape; per §A12, shape decisions belong in the dispatch
  table, not in payload-driven sub-switches. ZirOp count
  reduction (171→27) saves ~3KB but costs ~6× per-op
  branch in emit. Bench-relevant on SIMD-heavy guests.

### Alternative B — Separate `simd_xreg` register class

- **Sketch**: introduce `RegClass.simd` distinct from
  `.fpr`; allocator has 3 disjoint slot pools (gpr / fpr /
  simd).
- **Why rejected**: v1's W54 post-mortem flagged this exact
  shape as the root cause of the parallel-cache lattice
  that Phase 7's clean-substrate redesign exists to avoid.
  Reusing `.fpr` with shape tagging on a separate axis
  matches the lesson.

### Alternative C — Defer NEON spec-fidelity to Phase 15

- **Sketch**: ship "fast-path" NEON in Phase 9 (silent-
  saturate semantics); trap-on-specials lands as Phase 15
  optimisation.
- **Why rejected**: Phase 9 exit criterion is `simd.wast
  fail=skip=0`. The spec-fidelity-affecting fixtures are
  exactly the ones the wast assertions exercise. Skipping
  them defeats the exit gate.

### Alternative D — Drop SSE4.1 minimum, ship SSE2-only

- **Sketch**: emit fallback sequences for PMULLD / PINSR* /
  PBLENDVB on older x86 hardware.
- **Why rejected**: fallback sequences are ~5-10× slower
  than the SSE4.1 path AND introduce per-op branching the
  P6 single-pass JIT explicitly avoids. The 2009-vintage
  SSE4.1 baseline (Intel Nehalem) is reasonable; CPUs without
  it predate Wasm itself. ROADMAP §9.9's "SSE4.1 minimum"
  text is the load-bearing claim this ADR confirms.

## Consequences

### Positive

- **171 ZirOp catalogue is already in `zir.zig`**: §9.4 just
  activates them via `feature/simd_128/register.zig` — no
  IR substrate change.
- **Reused FP-class pool**: regalloc / spill-frame / emit
  surfaces stay scalar-shaped; only the shape-tag axis is
  new.
- **Phase 15 carries the optimisation work**: tighter spill-
  frame packing + per-shape spill-tier optimisations defer
  alongside the existing class-aware-allocation deferral
  (ADR-0038), keeping §9.9 focused on correctness.
- **Pattern reuse for Phase 10**: GC / EH / tail-call /
  memory64 follow the same feature-register shape SIMD-128
  establishes here.

### Negative

- **Conservative spill-frame size**: each v128 vreg pays
  16 bytes even when adjacent scalar vregs could share a
  16-byte slot. Phase 15 recovers this.
- **NEON spec-fidelity overhead**: per-handler explicit
  pre-checks for IEEE-754 specials add ~3-5 instructions
  per op vs the silent-saturate fast path. Acceptable for
  spec correctness; Phase 15 may add fast-path detection.
- **SSE4.1 baseline excludes pre-2009 x86 CPUs**: a
  documented limitation. Release notes flag this.

### Neutral / follow-ups

- **Bench-driven lift to Phase 15**: per ADR-0040's pattern,
  Phase 15 ROADMAP row inherits any SIMD-specific
  optimisation residual (currently §9.10's smoke benches
  against reference runtimes; if zwasm v2 lags, the gap
  becomes a Phase 15 row).
- **Cross-arch differential**: §9.9/9.9 wires `simd.wast`
  across both backends; the ARM64 + x86_64 emit-side
  divergences (NEON IEEE-754 trap vs SSE4.1's
  spec-friendly defaults) are caught by the differential
  runner.
- **`single_slot_dual_meaning.md` reinforced**: shape-tag-
  on-separate-axis is the textbook example of avoiding
  §14's forbidden pattern. Add a reviewer-facing note.

## References

- ROADMAP §9.9 (SIMD-128), §P3 (cold-start), §P6 (single-
  pass JIT), §P7 (backend parity), §P10 (no copy from v1),
  §A2 (file-size cap), §A3 (no cross-arch imports),
  §A12 (no per-arch logic in shared), §14 (forbidden list)
- ADR-0023 (zone architecture; `feature/<feat>/register.
  zig` slot reservation per §4.5)
- ADR-0027 (callee-saved pool reduction; FP-class register
  pool source)
- ADR-0038 (class-aware allocation deferral; the spill-
  frame packing this ADR explicitly references for Phase
  15 lift)
- ADR-0040 (Phase 8b aggregate target revision; pattern
  source for Phase 15 measurement migration)
- 9.1 survey: `private/notes/p9-9.1-simd-survey.md`
  (gitignored)
- v1 W54 post-mortem: `~/Documents/MyProducts/zwasm/.dev/
  archive/w54-redesign-postmortem.md`
- Wasm SIMD-128 spec testsuite: `~/Documents/OSS/WebAssembly/
  testsuite/proposals/simd/*.wast` (59 files, ~415 op
  variants)
- Intel SDM Vol 2, SSE4.1 chapter (PMULLD line range:
  Vol 2A §4.2; PINSRB/W/D §3.4; PBLENDVB §4.4)
- Arm IHI 0055 §C7 (NEON SIMD instruction encoding)

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-09 | `<backfill>` | Initial accepted version (§9.9/9.2 design framing; shape-as-variant ZirOp catalogue + FP-class pool reuse with shape-tag axis + feature-register pattern + NEON spec-fidelity + SSE4.1 minimum) |
