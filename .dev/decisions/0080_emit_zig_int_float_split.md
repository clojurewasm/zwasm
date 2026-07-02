# 0080 — Split `src/engine/codegen/x86_64/emit.zig` along driver / int / float boundary

- **Status**: **Withdrawn (2026-05-21, same-day pivot)** — see Revision history footer.
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-055 / D-081 paired discharge)
- **Tags**: file-layout, refactor, zone-2, codegen-x86_64, file-size-cap, withdrawn

> **Withdrawal summary**: implementation-prep verification (same
> day) showed the Step 0 survey overestimated `emit.zig` carve
> potential along the int/float axis. The per-op-file pattern
> from ADR-0074 had already extracted nearly all domain-specific
> code into `op_alu_float.zig`, `op_alu_int.zig`, `op_memory.zig`,
> `op_convert.zig`, `op_simd*.zig`. emit.zig's float dispatch arms
> are 18 single-line routes to those op_*.zig modules; carving
> them into `emit_float.zig` would produce a ~50-LOC wrapper file
> that doesn't shrink the parent. The true extractable mass of
> emit.zig is the **setup-pipeline helpers** (prologue + param
> marshalling + local init + state init + frame helpers,
> ~500 LOC), not the dispatch arms. A successor ADR (target
> ADR-0081) proposes the setup-helper extraction instead. See
> [`.dev/lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md`](../lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md)
> for the lesson capturing the survey-time discipline gap.

> Sections below preserve the original Proposed text for
> historical reference; readers seeking the current emit.zig
> refactor plan should consult ADR-0081 once it lands.

## Context

`src/engine/codegen/x86_64/emit.zig` is **1300 LOC** — over the
1000-LOC soft cap (ROADMAP §A2) and trending upward as Wasm 3.0
opcode landings continue. The companion test files
`emit_test_int.zig` (1607 LOC) and `emit_test_float.zig` (1539
LOC) are also over the soft cap, but for an independent reason
(test-array hardcoded byte offsets predating the
`body_start_offset()`-relative helper that landed via D-052 close
at `ac8238bf`).

The growth axis is dispatcher routing + per-op recipe inlining:

1. **`compile()` function body** (~1000 LOC starting at line 196)
   carries everything the engine driver does — prologue assembly,
   parameter marshalling, local zero-init, dispatch switch, state
   management — in one function.
2. The dispatch switch (~510 LOC; lines 681–1188) has ~113 arms.
   Most short arms (3–5 LOC each) call out to `op_*.zig` modules
   landed during §9.12-B / B69–B102 (per ADR-0074 per-op-file
   shape). Some arms still inline 15–30 LOC of recipe directly:
   integer const families (`i32.const`, `i64.const`, `ref.null`,
   `ref.func`; lines 738–782), integer div/rem variants (lines
   775–782), float const (`f32.const`, `f64.const`; lines
   783–784), memory load/store across all widths (lines 819–841),
   conversion ops (lines 789–818), SIMD inline cases (lines
   847–1141).
3. Parameter marshalling (lines 379–551, ~170 LOC) and local
   zero-init (lines 553–577, ~25 LOC) interleave int-typed and
   float-typed paths in the same loop — both `arg_gprs`/`arg_xmms`
   walking and `rbpStoreR32`/`rbpStoreXmmF32` calls live side by
   side.

The structural reality of emit.zig is therefore different from
ADR-0079's runner.zig case (three sequentially-distinct functions
— `runI32Export` / `compileWasm` / `setupRuntime`). emit.zig has
**one big `compile()`** orchestrating a parametric dispatcher; the
split has to be along the **op-domain axis** the dispatcher already
implicitly encodes.

Two adjacent debt rows depend on this split closing:

- **D-081** (`Status: now` per resume 2026-05-21): `emit_test_int.zig`
  / `emit_test_float.zig` cannot rename to `emit_int_test.zig` /
  `emit_float_test.zig` (per ADR-0054 §"Naming convention") until
  `emit_int.zig` / `emit_float.zig` source files exist.
- **D-055** (`Status: now` per same resume): JIT-execution sentinel
  (`encMovMemDisp32Imm32` call in x86_64 prologue) cannot land
  until the ~95 `expectEqualSlices` test sites migrate from
  hardcoded byte offsets to `prologue.body_start_offset()`-relative.

D-141 also references this row as one of the per-file ADR slots
(other per-file ADRs follow as ADR-0081+ for `validator.zig`,
`dispatch_collector.zig`, `regalloc.zig`, etc.).

## Decision

Split `src/engine/codegen/x86_64/emit.zig` into **three files**
along the int / float / driver semantic boundary. The dispatch
switch in `emit.zig` becomes a thin router; per-domain inline
arms move into `emit_int.zig` / `emit_float.zig` as
ctx-tuple-style `emitOp*` functions registered through the same
`dispatch_x86_64_ctx` mechanism already established in §9.12-B
(B69–B102, ADR-0073 / ADR-0074).

| New file | Contents | Approx LOC |
|----------|----------|-----------|
| `src/engine/codegen/x86_64/emit.zig` (driver) | `compile()` entry, prologue assembly (lines 319–377), frame computation (`computeOutgoingMaxBytes`, `computeLocalLayout`, `localDisp`; lines 117–186 + 1217–1297), dispatch switch routing, state init (lines 587–679), control-flow scaffold (labels + dead_code + fixup lists), epilogue (delegates to `op_control.emitEndCtx`) | ~400 |
| `src/engine/codegen/x86_64/emit_int.zig` (new) | int param-marshalling helpers (i32/i64 path of lines 379–551), int local-init path (lines 553–577 int branch), int-specific switch arms now in emit.zig: `i32.const` / `i64.const` / `ref.null` / `ref.func` const family + `i32/i64.div_s/u + rem_s/u` (lines 738–782), i32/i64 memory load/store (lines 819–837), `i32/i64.{trunc,wrap,extend}` adapters (lines 789–818 int-output rows) | ~450 |
| `src/engine/codegen/x86_64/emit_float.zig` (new) | float param-marshalling helpers (f32/f64 path of lines 379–551), float local-init path (lines 553–577 float branch), float-specific switch arms now in emit.zig: `f32.const` / `f64.const` (lines 783–784), f32/f64 memory load/store (lines 838–841), `f32.demote_f64` / `f64.promote_f32` / convert ops (lines 789–818 float-output rows), return marshalling (epilogue helpers for f32/f64/v128 returns) | ~350 |

Public re-exports stay in `emit.zig` so external callers — `runner.zig`'s
`compileWasm` → x86_64 codegen path, spec runners that link emit.zig
directly, top-level `src/zwasm.zig` aggregator — see no API change:

```zig
// src/engine/codegen/x86_64/emit.zig
pub const compile = compile_impl; // existing public entry
pub const localDisp = @import("emit_int.zig").localDisp; // shared
// per-domain emit helpers are package-private; only consumed by the
// dispatch switch within emit.zig.
```

The dispatch switch transforms from inline recipes to thin routes:

```zig
// before (lines 738–782):
.@"i32.const" => { /* 10 LOC inline */ },
.@"i64.const" => { /* 10 LOC inline */ },
.@"ref.null"  => { /* 5 LOC inline */ },
// ... etc

// after:
.@"i32.const", .@"i64.const", .@"ref.null", .@"ref.func"
    => try emit_int.handleConst(&ctx, op),
.@"i32.div_s", .@"i32.div_u", .@"i32.rem_s", .@"i32.rem_u",
.@"i64.div_s", .@"i64.div_u", .@"i64.rem_s", .@"i64.rem_u"
    => try emit_int.handleDivRem(&ctx, op),
.@"f32.const", .@"f64.const"
    => try emit_float.handleConst(&ctx, op),
```

The bundled-arm shape matches the multi-tag arm audit discipline
codified in [`bug_fix_survey.md`](../../.claude/rules/bug_fix_survey.md) —
each bundled arm dispatches to one helper covering every constituent
tag, no silent drop-through.

### Why three files (not two, not five)

- **Two files** (driver + everything-else): The "everything-else"
  file would absorb both int and float paths into ~800 LOC. This
  repeats ADR-0079's rejected Alt C — `everything-else` becomes
  the new dumping ground. Future SIMD chunks land back in the
  same monolith. Loses the **semantic** value: int vs float
  separation is the actual axis test files already reflect
  cleanly (emit_test_int.zig covers only i32/i64; emit_test_float.zig
  covers float + cross-domain + epilogue).
- **Five files** (driver + int-arith + int-memory + float-arith
  + float-memory): Shatters the int/float domain along an
  orthogonal sub-axis (arith vs memory). Both arith and memory
  ops within a domain share parameter conventions and call
  signatures; readers benefit from co-location. The 450-LOC
  emit_int.zig is below the soft cap; no need to split further.
- **Three files** matches the actual two-domain reality + a
  driver that orchestrates them. Each resulting file sits
  comfortably under the soft cap (driver ~400, int ~450, float
  ~350). Pattern composes with future Wasm 3.0 op additions:
  new GC int ops land in emit_int.zig, new GC float ops land in
  emit_float.zig.

### Companion: test-file rename + D-055 sentinel

After the source split lands, D-081 discharge in same chunk
family (`git mv`):

```sh
git mv src/engine/codegen/x86_64/emit_test_int.zig src/engine/codegen/x86_64/emit_int_test.zig
git mv src/engine/codegen/x86_64/emit_test_float.zig src/engine/codegen/x86_64/emit_float_test.zig
# update src/zwasm.zig root-imports
```

Test bodies remain unchanged in this chunk; the ~95
hardcoded-byte-offset migration to `prologue.body_start_offset()`-
relative is the D-055 follow-up chunk. After that migration
lands, the `inst.encMovMemDisp32Imm32`-call sentinel wires into
emit.zig prologue (5-line patch); D-055 closes.

### Implementation order (follow-up cycles, NOT in this ADR)

1. **Cycle 1** (this ADR): Proposed land.
2. **Cycle 2** (architectural): Carve `emit_float.zig` first
   (leaf — fewer cross-references than int; lower blast radius).
   Move float param marshalling, float const, float memory,
   float convert, return marshalling. Driver dispatch switch
   updates inline routes for `.f32.*` / `.f64.*` arms.
3. **Cycle 3** (architectural): Carve `emit_int.zig`. Move int
   param marshalling, int const, int div/rem, int memory.
   emit.zig shrinks to ~400 LOC driver.
4. **Cycle 4** (infrastructure, paired): D-081 rename via
   `git mv` + `src/zwasm.zig` import refresh. Test bodies
   unchanged.
5. **Cycle 5+ (D-055 discharge)**: Migrate ~95 test-array sites
   to `body_start_offset()`-relative; wire `encMovMemDisp32Imm32`
   call in prologue. Multi-cycle test migration; chunk granularity
   per LOOP.md §"Chunk granularity" (≤ 800 LOC source diff per
   chunk).

Each cycle is a separate chunk with a green `cohort` test gate
(test-all is required because the touched surface crosses module
boundaries — emit.zig is the codegen entry for x86_64).

## Alternatives considered

### Alternative A — Two-way split (driver + monolithic int/float body)

- **Sketch**: `emit.zig` (driver) + `emit_body.zig` (all op
  dispatch). Move prologue/frame/state to driver; everything
  else to emit_body.
- **Why rejected**: `emit_body.zig` lands at ~900 LOC — still
  near hard cap, no semantic separation between int and float
  ops. Future SIMD chunk pushes it over hard cap with no clean
  next split. Repeats ADR-0079 Alt C anti-pattern at finer
  granularity. The test files (emit_test_int.zig vs
  emit_test_float.zig) ALREADY embody the clean int/float
  separation; collapsing it back into one source file is loss-
  only.

### Alternative B — Pipeline-phase split (parse-driver / setup / dispatch)

- **Sketch**: `emit.zig` (compile entry + prologue/frame),
  `emit_setup.zig` (parameter marshalling + local init +
  EmitCtx), `emit_dispatch.zig` (the 510-LOC switch loop).
- **Why rejected**: This split shape mirrors ADR-0079's
  runner.zig case (sequential pipeline). But emit.zig's `compile()`
  is one function — splitting "setup" from "dispatch" inside it
  means either (a) extracting helpers that re-enter compile()'s
  local scope (awkward Zig with no closures), or (b) reorganising
  compile() into a sequence of pure-function passes (much larger
  refactor, ADR-grade on its own). Path (b) is desirable
  eventually but is independent of the int/float domain
  separation that closes D-055/D-081. Defer to a later ADR
  (ADR-0083+ candidate) if the dispatch switch grows further.

### Alternative C — Keep monolith + raise soft cap

- **Sketch**: Leave emit.zig at 1300 LOC, raise §A2 soft cap to
  1500, add `// ====== INT OPS ======` / `// ====== FLOAT OPS
  ======` section markers.
- **Why rejected**: Comment-marker discipline was already
  rejected in ADR-0079 Alt C. ROADMAP §A2 caps exist to enforce
  semantic boundaries, not as suggestion. emit.zig at 1300 is
  already over soft cap; next Wasm 3.0 GC op landing pushes
  it through 1500 and the cap-raise drift continues. Precedent
  collapse: ADR-0079 just split runner.zig for this exact reason;
  accepting monolith here contradicts that decision.

## Consequences

- **Positive**:
  - **D-055 + D-081 paired discharge unblocks** (this ADR's
    existence + acceptance is the structural prerequisite;
    follow-up cycles carry out impl).
  - `emit.zig` returns to ~400 LOC, well under soft cap.
  - File names match contents (`emit_int.zig` ↔ `emit_test_int.zig`,
    `emit_float.zig` ↔ `emit_test_float.zig`; D-081's "tests-only
    naming asymmetry" closes).
  - Future Wasm 3.0 GC op additions have clear landing slot
    (int-typed GC ops → emit_int.zig, float-typed GC ops → emit_float.zig).
  - File-size soft-cap WARN list drops by 3 entries (emit.zig +
    emit_test_int.zig once renamed + emit_test_float.zig once
    renamed, though the rename itself doesn't shrink LOC — those
    files remain over cap pending D-055 migration).
- **Negative**:
  - Three-file codegen surface increases the per-arch file
    count from ~30 to ~32. Mitigated by `emit.zig` re-export
    + `dispatch_x86_64_ctx` registry pattern (existing per-op-file
    discipline ADR-0074 already established the pattern).
  - Reader doing `git grep "i32.const"` finds the recipe in
    emit_int.zig now rather than emit.zig. Mitigated by file
    name reflecting domain; the `emit.zig` driver shows the
    bundled-arm routing line that names the helper.
  - Cross-arch consistency: arm64 has no parallel
    `emit_test_int.zig` / `emit_test_float.zig` (verified
    2026-05-21 — arm64 emit_test files are not int/float-split).
    Arm64 split is **out of scope for this ADR** (D-052 trigger
    fired for x86_64 only; arm64 emit.zig is 1183 LOC, also
    over soft cap but no test-naming pressure). Future ADR may
    mirror this pattern to arm64 if/when arm64 emit.zig itself
    pressures the cap.
- **Neutral / follow-ups**:
  - Implementation chunks land per the order above (3
    architectural-typed chunks + 1 infrastructure-typed
    rename + multi-cycle D-055 test migration). Each chunk's
    test gate is `cohort` (test-all).
  - D-081 retires inline with the rename chunk; D-055 retires
    after sentinel wire-up cycle.
  - D-141 row body retires one entry (paired with this ADR's
    Acceptance).

## References

- D-052 (closed at `ac8238bf`) — prologue.zig helper extract;
  precondition that dissolves D-081's barrier.
- D-055 (`Status: now` per 2026-05-21 resume) — sentinel wire-up
  + test-migration paired discharge.
- D-081 (`Status: now` per 2026-05-21 resume) — `emit_test_*.zig`
  → `emit_*_test.zig` rename paired discharge.
- D-141 — file-size soft cap proliferation (this ADR's
  Acceptance closes one of the per-file ADR slots).
- ADR-0030 — original x86_64 emit_test split (lessons that
  motivated the per-domain test naming).
- ADR-0054 §"Naming convention" — `<source>_test.zig` strict
  suffix convention this ADR's rename enforces.
- ADR-0073 / ADR-0074 — per-op-file Zone split + comptime
  dispatch ctx tuple (existing pattern this ADR's bundled-arm
  routing extends).
- ADR-0079 — `runner.zig` three-way split; shape precedent for
  this ADR.
- ROADMAP §A2 — file size soft (1000) / hard (2000) caps.
- Source: `src/engine/codegen/x86_64/emit.zig` (1300 LOC,
  current shape), `emit_test_int.zig` (1607 LOC), `emit_test_float.zig`
  (1539 LOC), `prologue.zig` (helper landed via D-052 close).

## Revision history

| Date       | SHA          | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
|------------|--------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-21 | `2bbc17f5e`   | Initial Proposed version.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| 2026-05-21 | `2b8e2447` | **Status: Withdrawn** — same-day implementation-prep verification revealed the Step 0 survey overestimated the int/float carve mass. emit.zig's 18 float dispatch arms are 1-line routes to `op_alu_float.zig` / `op_memory.zig` / `op_convert.zig` (ADR-0074 per-op-file pattern already absorbed the float code). emit_float.zig per this ADR would be a ~50-LOC wrapper; doesn't shrink emit.zig meaningfully. The actual extractable mass is the setup-pipeline helpers (~500 LOC) — successor ADR-0081 will propose that target. D-055 + D-081 stay `Status: now` but their discharge paths re-walk per the lesson (D-081's rename-to-strict-suffix may need ADR-0054 amendment alternative since source-split is no longer the chosen path; D-055's sentinel wire-up + test-array migration unaffected). |
