# 0110 — Widen Value extern union from 8 to 16 bytes (terminal SIMD width)

- **Status**: Accepted 2026-05-24
- **Date**: 2026-05-24
- **Author**: claude (autonomous loop, cycle 37) + user collab review
- **Tags**: value, abi, simd, v128, runtime, runtime.zig, jit_abi, ADR-0052, ADR-0107, ADR-0104, dogfooding
- **Supersedes-portion-of**: ADR-0052 (per-valtype byte offsets for v128 globals — the "cope" mechanism is removed); ADR-0107 (byte-buffer globals propagation to c_api — Withdrawn in the same commit; root-cause-fixed here instead)
- **Amends**: ADR-0104 Phase 9 真スコープ (adds "v128 structural-first-class via Value widening" to the in-scope cohort); ROADMAP §9 (adds §9.13-V row for Value widening cohort)

## Context

ADR-0052 (2026-05-11, Phase 9 §9.9-g-20) introduced
per-valtype byte offsets for v128 globals as a way to support
Wasm 2.0 v128 globals **while preserving the
`@sizeOf(Value) == 8` invariant**. The chosen mechanism:

- `Runtime.globals: []*Value` for scalar globals (8-byte slots)
- `Runtime.globals_byte_storage: []u8` for v128 globals
  (parallel 16-byte storage path)
- `globals_offsets: []u32` module-level table mapping each
  global index to its byte offset
- Per-arch JIT op dispatch with valtype switch routing
  v128 globals to a separate emit path

ADR-0107 (2026-05-23, Proposed) was about to propagate this
shape to the c_api Instance path (cross-module v128 global
imports), continuing the "cope" pattern.

The 2026-05-24 cycle 36-37 user reframe + 8-runtime industry
audit (`docs/runtime_deep_comparison.md`) re-examined the
ADR-0052 trade-off:

- **5/7 surveyed runtimes** (wasmtime, wasmer, wazero,
  WasmEdge, WAMR) use **uniform 16-byte Value**. v128 is
  first-class.
- **2/7** (zware, wasm3) use 8-byte Value — and neither
  supports v128 (zware leaks v128 declaration without
  storage; wasm3 maintenance-only).
- zwasm v2's 8-byte + per-valtype offsets cope is a hybrid
  not exactly replicated elsewhere (WAMR uses byte-buffer
  for globals specifically but its Value is 16-byte).
- ADR-0052's "Why rejected Alt A — 50+ test sites" claim
  was overstated; actual asserts in tree: 2 files. Substantive
  cascade: ~10-20 sites.

Key v128 importance reframe (per
`docs/runtime_deep_comparison.md` §1):

- **v128 = Wasm 2.0 baseline**. Modern toolchains (TinyGo /
  Rust wasm32 / emscripten -msimd128 / Zig wasm32 / Go) emit
  v128 instructions in stdlib (memcpy/memcmp/UTF-8 validate
  /etc) by default. v128-incapable runtimes can't load
  modern Wasm modules.
- **Use cases growing fast**: ML inference (ONNX/TFLite/WebLLM),
  image/video processing, cryptography, compression,
  simdjson, etc. — 2-8× speedup typical.
- **128-bit is the terminal portable Wasm SIMD width**. No
  v256/v512 in any roadmap (AVX-512 native-side problems
  preclude portable wider SIMD). Wasm 3.0 Relaxed SIMD adds
  ~40 ops at the same 128-bit width.
- **Therefore Value=16 is "pay once, never again"**. Once
  widened, no future widening needed for the foreseeable
  future.

The accumulated "Value=8 cope" cost (per ADR-0052 + ADR-0107):

1. `globals_offsets[]` table per module
2. `globals_byte_storage: []u8` parallel storage
3. JitRuntime `globals_byte_base: [*]u8` new ABI field
4. Per-valtype switch in `.global_get` / `.global_set`
   dispatch arms
5. `evalConstScalarValue` / `evalConstV128Value` split
6. Spec runner `GlobalsCtx` byte-buffer adapter
7. (Pending ADR-0107) c_api Instance path byte-buffer
   propagation (~13 callsites)
8. Future Wasm 3.0 Relaxed SIMD ops would extend the
   per-valtype switch further

This cost is **ongoing maintenance debt** that grows with
every new v128-related feature. Value=16 widening pays the
cost once and removes the cope mechanism entirely.

## Decision

**Widen `Value` from 8-byte `extern union` to 16-byte
`extern union`** with v128 as a first-class union variant.
v128 becomes structurally indistinguishable from
i32/i64/f32/f64 at the slot level — no parallel storage, no
per-valtype offsets, no dispatch bifurcation.

```zig
// Target shape (replacing src/runtime/value.zig)
pub const Value = extern union {
    bits128: u128,                   // raw 128-bit access
    bits64_lo: u64,                  // low 64 bits (for scalar access)
    i32: i32, u32: u32,
    i64: i64, u64: u64,
    f32_bits: u32,                   // IEEE-754 bit pattern (low 32 bits)
    f64_bits: u64,                   // IEEE-754 bit pattern (low 64 bits)
    ref: u64,                        // funcref/externref (low 64 bits)
    v128: [16]u8,                    // SIMD-128 byte array (16-byte align)
};

comptime {
    std.debug.assert(@sizeOf(Value) == 16);
    std.debug.assert(@alignOf(Value) >= 16);  // v128 alignment requirement
}
```

The widening implies a multi-layer cascade:

1. **Storage / operand stack**: `Runtime.operand_buf:
   [N]Value` doubles memory (Wasm function frames typically
   10-50 operand slots → +160-800 B per active frame).
2. **Globals**: `Runtime.globals_storage: []Value` becomes
   uniform 16-byte stride; `globals_offsets[]` table removed;
   `globals_byte_storage: []u8` parallel path removed.
3. **JIT codegen — globals**: `[X23, #idx*8]` →
   `[X23, #idx*16]` (or `Q` register variant on arm64,
   `MOVUPS` on x86_64). Per-valtype switch in
   `.global_get` / `.global_set` removed (single emit
   path).
4. **JIT codegen — operand stack spill slots**: `* 8` →
   `* 16` in regalloc spill stride.
5. **JIT extern struct field offsets**: `JitRuntime` field
   offsets shift; all per-arch prologues that load
   `globals_base` / `funcptr_base` / etc. via `[X19 +
   offset]` need offset recomputation. Mechanical but
   exhaustive.
6. **ZIR payload encoding**: per-op result slot assumptions
   are 8-byte. Migrate to 16-byte. Encoder version bump
   (impacts debug-dump format; any consumer of dumped
   ZIR needs migration tool or re-dump).
7. **Host-call marshaling**: `host_calls` Value array
   stride doubles.
8. **C API binding** (`src/api/instance.zig`): the c_api
   `Val` type already supports v128 via its own union; the
   facade Value passthrough simplifies (no `valueToVal`
   hard-coded-0 for v128).
9. **Spec runner**: `GlobalsCtx` byte-buffer adapter
   becomes unnecessary; spec runner uses the same uniform
   Value-stride.
10. **2 test asserts** of `@sizeOf(Value) == 8` updated.
11. **Reference test fixtures** that assume operand stack
    memory footprint (rare; mostly bench rather than
    behavior).

Estimated implementation: **6-8 cycles** of autonomous +
gated work, executed per the detailed plan in
`.dev/phase9_value_widen_plan.md`.

This work is **scoped within Phase 9** (not deferred to
Phase 10) per user direction 2026-05-24: "せっかく情報も
集めたことだし、まず次のクリアセッションが誤解を生まないように、
wasm 2.0までの範囲ですでに対応をすべき". A new ROADMAP row
**§9.13-V — Value widen to 16-byte (terminal SIMD width)**
is added as a Phase-9-eligible cohort, parallel to (but
independent from) the existing §9.13 hard gate. Phase 9
close gate (§9.13) and §9.13-V can land in either order;
both must close before Phase 10 opens.

ADR-0104 (Phase 9 真スコープ) is amended via this ADR's
own Revision-history entry: the in-scope cohort gains
"v128 structural-first-class via Value widening" as a
§18 deviation justification.

ADR-0107 is **Withdrawn in the same commit** — its
"byte-buffer globals propagation to c_api" goal is
root-cause-fixed by this ADR (uniform 16-byte Value =
no propagation needed). ADR-0107 stays in-tree as
design-decision lineage (per the ADR-0108 Withdrawn pattern).

ADR-0052's "per-valtype offsets cope" portion is
superseded; the wider ADR-0052 (Wasm 2.0 v128 globals
exist + must be loadable) stays valid as the historical
record of how zwasm v2 first got v128 globals working
under tight Phase 9 schedule pressure.

## Alternatives considered

### Alternative A — Keep ADR-0052 cope + Accept ADR-0107

- **Sketch**: Continue per-valtype offsets path; accept
  ADR-0107 c_api propagation; Phase 9 closes faster.
- **Why rejected**: cope is **ongoing debt**. Each future
  v128-related feature (Wasm 3.0 Relaxed SIMD ~40 ops;
  GC i31ref already 8 bytes so unaffected; possible
  future wide-arithmetic intrinsics) extends the
  per-valtype dispatch + parallel-storage cope path.
  WAMR-pattern (cope) is valid for "lightweight
  embedded runtime" positioning but zwasm v2 is
  positioning toward "production-grade Wasm 2.0 runtime
  with JIT" (3-host, full spec compliance, dogfooded by
  CW v2). At that positioning, "pay once, never again"
  beats "ongoing cope". User judgment 2026-05-24:
  "影響範囲が死ぬほど広くても取り組む価値がある".

### Alternative B — Defer to Phase 10 entry cohort

- **Sketch**: ADR-0110 Accepted but implementation deferred
  to Phase 10 entry. Phase 9 closes with ADR-0107 cope in
  place; Phase 10 entry removes cope.
- **Why rejected**: defers the test-coverage strengthening
  (which is the explicit user concern: "テスト不足感もあります")
  to after Phase 9 close, when fewer eyes are on the
  Wasm 2.0 substrate. Better to land the strengthening
  and the Value widening alongside, within the
  Phase-9-close-quality discipline. The §9.13-V row
  doesn't block §9.13 (they can land in either order),
  so Phase 9 close itself is not delayed.

### Alternative C — Wait for Wasm 3.0 Relaxed SIMD + GC details before committing

- **Sketch**: Wasm 3.0 may add more value types; widen
  Value all at once when 3.0 lands.
- **Why rejected**: per `docs/runtime_deep_comparison.md`
  §2 — Wasm 3.0 GC types (i31ref / struct refs / array
  refs) fit in 8-byte ref slot already (wasmtime uses
  32-bit compressed handle for GC refs). Wasm 3.0
  Relaxed SIMD is **same 128-bit width** as v128. No
  Wasm proposal anywhere will demand >16-byte slots.
  Waiting brings no new design information.

### Alternative D — Widen to 32-byte (future AVX-512-class)

- **Sketch**: Be future-proof for any conceivable SIMD
  width.
- **Why rejected**: Wasm portable SIMD consensus
  explicitly stays at 128-bit (AVX-512 native-side
  fragmentation precludes wider portable SIMD). No
  proposal exists. 32-byte Value would double scalar
  memory cost for hypothetical future need that may
  never materialize.

## Consequences

**Positive**:

- v128 becomes first-class (structurally same as
  i32/i64/f32/f64 at slot level) — matches industry
  5/7 majority and Wasm 2.0 spec intent.
- All cope code from ADR-0052 + ADR-0107 is **removed**
  (not just papered over): `globals_offsets[]`, parallel
  byte storage, per-valtype JIT dispatch switch, spec
  runner `GlobalsCtx` byte-buffer adapter, c_api Val
  v128 hard-coded-0. Net code reduction expected
  (~300-500 LOC of cope vs ~50-100 LOC of widened-Value
  cleanup).
- Wasm 3.0 Relaxed SIMD will land within the same Value
  representation, no further cope path needed.
- ADR-0109 (native Zig API) `Value` exposure simplifies:
  no `V128` separate type — v128 is a Value variant like
  any other. CW v2 dogfooding contract simplifies.
- Test coverage strengthening for Value semantics
  (boundary fixtures for v128 lane ops / NaN payload
  preservation / sign extension / ref encoding) lands as
  Phase 9 quality investment, addressing the user's
  "テスト不足感" concern.
- "pay once, never again" — terminal at 128-bit per
  industry consensus.

**Negative**:

- 6-8 cycles of impl work; ~10-20 substantive code sites
  cascade; bug-prone migration window.
- Operand stack memory footprint doubles (~+160-800 B
  per active Wasm function frame; not catastrophic).
- ZIR payload encoding migration may invalidate any
  cached `.zir` dumps (acceptable; debug-only artifact).
- Phase 9 close timeline slips by ~6-8 cycles (= 1-2
  weeks at current autonomous pace), unless §9.13-V
  lands in parallel with §9.13 hard gate (which it can,
  per the independence note above).
- Bench regression risk: scalar-only modules (no v128
  use) pay the doubled operand stack cost. Mitigation:
  pre-impl + post-impl bench delta capture per Phase 8b
  discipline.

**Neutral / follow-ups**:

- ADR-0109 (native Zig API) Value section updated in the
  same Phase 9 cohort: facade Value becomes the same
  16-byte extern union as internal; no separate `V128`
  type needed.
- `docs/zig_api_design.md` updated alongside ADR-0109
  Value section (CW v2 dogfooding contract).
- §9.13-V plan doc (`.dev/phase9_value_widen_plan.md`)
  is the implementation playbook.
- Future v128 SIMD extensions (Relaxed SIMD) become
  drop-in additions; no Value-side amendment needed.

## Removal condition

This ADR retires when:

1. §9.13-V row is fully `[x]` with all cope mechanisms
   removed from tree.
2. ADR-0107 obsoletion confirmed (no remaining references
   to byte-buffer propagation as a forward-looking design).
3. ADR-0052's "Why rejected Alt A" revision history
   notes that the Alt A is in fact what was ultimately
   chosen (with the cascade cost confirmed bounded).

When that happens this ADR transitions to `Status: Closed
(implemented)` with the §9.13-V row's commit-SHA range
cited.

## References

- `.dev/phase9_value_widen_plan.md` — implementation
  playbook (read alongside this ADR; canonical execution
  artifact).
- `docs/runtime_deep_comparison.md` — 8-runtime industry
  audit that validated the Value=16 majority.
- `docs/zig_api_design.md` — consumer-facing API spec
  (will be updated to reflect Value=16 in the same
  cohort).
- ADR-0052 — per-valtype byte offsets (this ADR
  supersedes the cope-mechanism portion).
- ADR-0107 — byte-buffer globals propagation
  (Withdrawn 2026-05-24, root-cause-fixed here).
- ADR-0104 — Phase 9 真スコープ (amended to include
  v128 structural-first-class via Value widening).
- ADR-0109 — native Zig API (independent; this ADR
  simplifies its Value section).
- D-079 (ii) in `.dev/debt.md` — re-targeted from
  ADR-0107 Accept to ADR-0110 implementation
  (§9.13-V).
- v1 zwasm `~/Documents/MyProducts/zwasm/` — reference
  for the pre-v2-spec-fidelity approach (predates v128
  considerations).

## Revision history

- 2026-05-24 — Initial draft + Accepted at cycle 37 user
  collab confirmation. Paired with
  `.dev/phase9_value_widen_plan.md`. ADR-0107 Withdrawn
  in same commit. ADR-0052 Status updated.
- 2026-05-24 — ADR-0104 Revision history entry added
  (in same commit): Phase 9 真スコープ amended to
  include §9.13-V cohort.
