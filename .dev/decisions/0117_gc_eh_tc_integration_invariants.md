# 0117 — GC × EH × TC integration invariants: cross-subsystem correctness

- **Status**: Accepted (2026-05-25; Phase 10 / 10.D ADR round close)
- **Date**: 2026-05-25
- **Author**: claude (autonomous loop, /continue prep path)
- **Tags**: integration-invariants, gc-eh-tc-cross-product, safepoint,
  exnref-rooting, tail-call-frame-consumption, Phase 10 / 10.G + 10.E + 10.TC
- **Paired ROADMAP row**: §10 / 10.G + 10.E + 10.TC (impl), §10 / 10.D (this ADR's Accept gate)
- **Co-landed with**: ADR-0111..0116 (Phase 10 / 10.D round)

## Context

Phase 10 ships three new Wasm 3.0 subsystems concurrently:
WasmGC (ADR-0115 + ADR-0116), Exception Handling (ADR-0114), and
Tail Call (ADR-0112). Each ADR defines its own invariants in
isolation; the three meet at runtime in ways the individual ADRs
cannot fully address.

The Phase 10 design plan §3.5 final paragraph names this as the
`ADR-0117 integration invariants` slice — the cross-subsystem
correctness contract.

The interactions:

1. **GC × EH** — `exnref` payloads carry GcRef-typed `Exception.payload`
   slots; the GC walker (ADR-0116 D1) must enumerate them, and
   the FP-walk unwind (ADR-0114 D5) must not lose them between
   throw site and catch landing pad. The two ADRs already cite
   each other, but the **shared invariant** (exnref payloads
   reachable from a throw-in-flight remain rooted across unwind
   frames) requires explicit codification.

2. **GC × TC** — A tail-call (ADR-0112) is by spec safepoint-free
   between caller-teardown and callee-jump. If the caller frame
   held the only reference to a live GcRef, that ref must not
   escape collection during the tail-call jump. The ADR-0112
   comptime invariant (`is_safepoint=false`) says no NEW safepoint
   is inserted; this ADR codifies the live-ref preservation
   contract.

3. **EH × TC** — `return_call` does not catch (it consumes the
   frame; there is no try_table in the consumed frame to catch
   a throw that happens at the callee). The spec is explicit:
   tail-call into a function that throws propagates the
   exception past the consumed frame. zwasm's FP-walk unwind
   must correctly walk past tail-call-consumed frames.

4. **All three** — A single function body may contain a
   `try_table` (EH) that wraps a `return_call` (TC) of a function
   returning a `(ref $T)` (GC). Each subsystem's emit shape must
   compose into a valid combined emit. ADR-0117 names the
   composition rules.

If these invariants are left implicit in three sibling ADRs, the
risk is silent divergence: an EH PR ships, a TC PR ships, then a
GC PR exposes that the EH+TC combo never had stack-map coverage
for the tail-call-thrown-ref-typed case. ADR-0117 names the
invariants up-front so each impl-cycle's tests cover them.

## Decision

Codify the following 6 cross-subsystem invariants as ADR-0117
contract. Each is comptime-asserted where possible and runtime-
verified via dedicated fixtures under `test/edge_cases/p10/cross/`.

### Invariant I1 — exnref payloads stay GC-rooted across unwind

**Contract**: from the moment `zwasm_throw(tag, params)` writes
the thread-local `Exception` slot (ADR-0114 D6) until the matching
try_table landing pad executes its catch clause, every GcRef
inside `Exception.payload[0..param_count]` is reachable from the
GC root set.

**Mechanism**: the GC walker (ADR-0116 D1) adds a 5th root source:

```
walkRootsFn(ctx, cb):
  ...
  5. Thread-local pending Exception (if Exception.tag != null):
       for each i in 0..Exception.param_count:
         if Exception.tag.params[i] ∈ ref-typed: cb(Exception.payload[i])
```

The walker invocation order is unchanged (globals → tables →
stack → host → exception); the exception source is unconditionally
walked when the thread-local slot is non-null.

**Test**: `test/edge_cases/p10/cross/gc_x_eh_thrown_ref_rooted.wat`
throws an exception carrying a freshly-allocated `(ref $struct)`,
forces a `collect()` from within the catch clause's hookable
host-call, then reads the payload's field. Pre-fix: SEGV (ref
swept); post-fix: field read returns the original value.

**Comptime check**: NOT applicable (runtime invariant on walker
behaviour); covered by the fixture.

### Invariant I2 — tail-call must not leak GcRefs in transition

**Contract**: between the caller's `frame_teardown` (ADR-0112 D3)
and the callee's `BR X16` jump, no GcRef reachable from caller-frame
local slots may be considered dead. The callee inherits the
"caller-of-caller" frame context; any local that held a live
`(ref $T)` argument passed to the callee is preserved via the
ABI register pass (X1..X7 / V0..V7 per ADR-0112 D4).

**Mechanism**: tail-call argument marshalling (ADR-0112 D4 step
1) happens BEFORE frame_teardown. After teardown, the live refs
are in argument registers ONLY (not on the dying frame). The
callee's prologue establishes a new frame; the callee's first
safepoint (if any) reads the args from regs and records them in
its own stack-map.

**Test**: `test/edge_cases/p10/cross/gc_x_tail_call_thunk_safepoint_free.wat`
verifies the **negative** — a tail-call with a (ref $T) argument
must not allow GC between caller-teardown and callee-entry. The
fixture asserts: a collect() invocation from a finaliser-style
host-call mid-tail-call would NOT see the ref-typed arg as a root
(because it's not on any stack frame for that instant) — and
therefore the collect() must NOT fire mid-tail-call. ADR-0112 D7's
`is_safepoint=false` comptime invariant enforces this structurally.

**Comptime check**: `comptime { std.debug.assert(!@import("op_tail_call.zig").is_safepoint); }`
in `engine/codegen/<arch>/emit.zig` (per ADR-0112 D7). This ADR
extends the assert: any helper called between teardown and jump
must also be `is_safepoint=false`.

### Invariant I3 — FP-walk unwind handles tail-call-consumed frames correctly

**Contract**: when `zwasm_throw` triggers FP-walk unwind
(ADR-0114 D5), and the throw site is inside a function that was
tail-called from caller F1 (so F1's frame was consumed at the
tail-call), the unwind correctly walks past F1's slot in the
frame chain — because F1's frame has already been epilogued.
The unwind sees F1's caller (F0) as the next frame.

**Mechanism**: tail-call's `frame_teardown` (ADR-0112 D3) restores
the FP register to F1's caller's FP (= F0's FP) before the jump.
The callee inherits this FP. When unwind walks `fp = load_frame_chain(fp)`,
it correctly skips F1 and lands on F0.

**Test**: `test/edge_cases/p10/cross/tail_call_throw_unwinds_to_grandparent.wat`
has F0 call F1, F1 tail-call F2, F2 throw E. Catch in F0 (via
try_table wrapping the call to F1). Verify catch executes with
F0's locals intact (no F1 ghost on stack).

**Comptime check**: NOT applicable (runtime FP-chain invariant).
Verified by the fixture + spec corpus.

### Invariant I4 — try_table over GC-typed call records stack-map

**Contract**: a `try_table` whose target call returns or accepts
ref-typed values produces a Callsite (ADR-0113 D1) with
`is_safepoint=true` AND a stack-map naming the live refs at the
landing-pad target PCs. The landing pad executes with full GC
root visibility — refs in caller locals + refs in the
`try_table` `(catch $tag $label (param $T_ref))` parameter slots.

**Mechanism**: the codegen emit pass walks the regalloc output
for the call site, identifies refs in callee-saved + caller-saved
+ try_table-parameter slots, and writes the stack-map per
ADR-0113 D4. The map is consumed at landing-pad entry — the
walker (ADR-0116 D1) reads it via the same per-Instance side-
table.

**Test**: `test/edge_cases/p10/cross/try_table_over_gc_call_landing_pad_rooted.wat`
allocates a struct, passes it to a function that may throw
(carrying the struct's ref in the exception payload), forces a
collect within the catch clause, then verifies the struct's
fields are intact.

**Comptime check**: `comptime { std.debug.assert(@import("op_try_table.zig").n_successor_edges >= 2); }`
+ stack-map population assertion at codegen.

### Invariant I5 — `return_call` into throwing callee — no try_table catch in consumed frame

**Contract**: the spec is explicit (§ 7.1.13): `return_call`
does not implicitly catch. If F1 has a `try_table { ... }` and
emits a `return_call F2` inside the try body, then F2 throws,
the try_table in F1 does NOT catch — because F1's frame is
consumed at the tail-call. The throw propagates to F1's caller
F0.

**Mechanism**: zwasm's `try_table` registration (ADR-0114 D1
`register.zig`) is scoped to the calling frame's PC range. At
tail-call, the frame's PC ceases to be "in scope" the moment
frame_teardown runs. FP-walk unwind correctly skips the
already-consumed frame (Invariant I3); no try_table lookup in
F1 happens for the throw.

**Test**: `test/edge_cases/p10/cross/return_call_throws_skips_caller_try_table.wat`
verifies: F0 calls F1, F1 has a `try_table { return_call F2 }`,
F2 throws E. F1's try_table must NOT catch; F0's outer catch
(if any) must catch. Per spec.

**Comptime check**: NOT applicable (runtime PC-scope invariant);
fixture verifies.

### Invariant I6 — `-Dgc=false` strip preserves EH + TC

**Contract**: when the `-Dgc=false` build option strips the
entire `feature/gc/` directory (ADR-0115 D3 nuclear strip), EH
and TC subsystems MUST remain fully functional. exnref carrying
non-ref payloads (`i32`, `f64`, …) works; tail-calls work; only
GC types (struct / array / (ref $T) / anyref) and exnref-with-
ref-payload are validator-rejected.

**Mechanism**: DCE is structural — `feature/gc/` files are not
imported when `build_options.gc == false`. The walker root list
(Invariant I1) becomes:

```
walkRootsFn := no-op (collector_iface stripped)
```

The thread-local Exception slot still exists (EH ships
independently), but its payload-walking step (Invariant I1 step
5) compiles to a no-op via comptime branch elimination.

**Test**: `test/edge_cases/p10/cross/eh_tc_without_gc_smoke.wat`
built with `-Dgc=false -Dwasm=v3_0` exercises throw / catch /
return_call paths without any GC type involvement. Must pass.

**Comptime check**: build-option-conditioned imports + comptime
assert that `feature/gc/heap.zig` is not in the dependency graph
when `gc == false`.

## Alternatives considered

- **A. Implicit cross-subsystem coverage** (rely on each ADR's
  fixtures to exercise the cross-product). Rejected: the spec
  corpus doesn't comprehensively cover the cross-product
  (proposal testsuites are mostly within-subsystem). Explicit
  edge_cases fixtures per Invariant ensure regression detection.

- **B. Move the invariants into ADR-0114/0115/0116 as side
  references** (no separate ADR). Rejected: the cross-product
  contracts span 3 ADRs; placing the rules in any one of them
  asymmetrically owns shared responsibility. A dedicated ADR
  makes the contract discoverable from any starting point.

- **C. Defer some invariants to Phase 11 close** (ship Phase 10
  with partial coverage). Rejected: each invariant is a
  correctness contract; deferring any of them means the impl
  rows 10.E / 10.G / 10.TC ship without a verified composition
  story. Phase 11 features (threads, multi-memory expansion,
  etc.) compound atop GC×EH×TC; the contract MUST be solid at
  Phase 10 close.

## Consequences

**Positive**:

- Six explicit cross-subsystem invariants, each with a fixture
  + (where applicable) comptime check.
- Impl cycle ordering becomes flexible: whichever of
  10.E / 10.G / 10.TC ships first lands the ADR-0113 callsite
  unification refactor (per ADR-0113 D6); the other two consume
  the shape unchanged AND inherit this ADR's contracts.
- `-Dgc=false` strip remains nuclear (Invariant I6) — embedded
  / MCU deployments can ship Wasm 3.0 EH + TC without paying
  GC cost.
- Edge-case fixture suite (`test/edge_cases/p10/cross/`) grows
  with 6 new fixtures that exercise the cross-product — these
  remain regression detectors for Phase 11+ work.

**Negative**:

- 6 new fixtures under `test/edge_cases/p10/cross/`; bounded
  (~12 files: 6 .wat + 6 .expect).
- The walker (Invariant I1) reads the thread-local Exception
  slot at every collect, even when no throw is in flight. Cost:
  one branch (slot == null check) + no-op fast path. Bounded.
- Invariant I6 doubles `feature/gc/` build-option testing
  surface: every CI must run `-Dgc=false` + `-Dgc=true`
  matrix. Build-time bounded (~30% increase for the GC-stripped
  variant which is smaller).

## Removal condition

This ADR retires when all three subsystem ADRs (0112, 0114,
0115/0116) ship `[x]` at ROADMAP §10 / 10.TC / 10.E / 10.G,
AND each of the 6 Invariants' fixtures land green at 3-host
gate. At that point:

- Status transitions to `Closed (Implemented)` with the impl
  SHA range cited.
- The 6 cross-subsystem fixtures remain in
  `test/edge_cases/p10/cross/` as permanent regression
  detectors.
- The Invariants themselves are codified in
  `.claude/rules/p10_cross_subsystem_invariants.md` (a new
  permanent-regression rule auto-loaded for `feature/gc/`,
  `feature/exception_handling/`, and `engine/codegen/`
  edits).

## References

- `phase10_design_plan_ja.md` §3.5 — full design spec (this
  ADR's source).
- ADR-0112 — Tail Call design (Invariants I2 + I3 + I5
  consume).
- ADR-0113 — callsite_metadata 3-axis (Invariant I4 consumes
  the N-successor + safepoint axes).
- ADR-0114 — Exception Handling (Invariants I1 + I3 + I4 + I5
  consume; thread-local Exception slot from D6).
- ADR-0115 — GC heap + collector (Invariant I6 consumes the
  nuclear strip).
- ADR-0116 — GC roots + RTT + i31 (Invariant I1 + I4 extend
  the walker root-set spec).
- WebAssembly GC × Exception Handling × Tail Call cross-product:
  https://github.com/WebAssembly/gc (proposal interactions
  section)
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/` —
  cross-subsystem precedent (wasmtime's invariants live
  scattered across vm/gc/, vm/exception/, vm/calls/; this ADR
  consolidates them up-front).
- `~/Documents/OSS/wasmtime/crates/cranelift/src/translate/
  code_translator.rs:612-649` (TryTable handler block creation):
  wasmtime processes `try_table.catches.iter().rev()` so that
  left-to-right matching within one try_table unifies with
  inside-out semantics of nested try_tables. Mirrors zwasm v2
  `ExceptionTable.Builder.add` insertion-order discipline
  (innermost-try_table first; first-match wins per
  `shared/exception_table.zig::lookup` linear scan). Confirms
  Invariant I3's directional walk.
- `~/Documents/OSS/wasmtime/crates/cranelift/src/translate/
  code_translator.rs:748-764` (ReturnCall): sets
  `environ.stacks.reachable = false` after the tail-jump,
  classifying the op as a terminator with no fallthrough.
  Mirrors zwasm v2 ADR-0113 §A `is_terminator=true /
  n_successor_edges=0` for return_call (per-op files at
  `engine/codegen/{arm64,x86_64}/ops/wasm_3_0/return_call*.zig`).
  Confirms Invariant I2's safepoint-free terminator shape.
- `~/Documents/OSS/wasmtime/crates/cranelift/src/func_environ.rs:1200-1215`
  (safepoint × moving-GC interaction comment): "we don't
  re-sync GC-rooted values, and we don't root the
  instrumentation slots explicitly. This is safe as long as
  we don't have a moving GC. But if/when we do build a moving
  GC, we will need to handle this, probably by invalidating
  the 'freshness' of all ref-typed values after a safepoint
  and re-writing them". Direct precedent for Invariant I4's
  try_table-over-GC-call stack-map requirement — wasmtime
  records the same invariant as a deferred TODO; zwasm v2
  codifies it ahead of the moving-GC need so the structural
  shape is right from day 1.

## Revision history

- 2026-05-25 — Initial draft via /continue autonomous prep path
  (per `.claude/skills/continue/SKILL.md` §"Autonomous prep
  paths for user-gated ADRs"). Status: Proposed pending user
  collab review at 10.D. **FINAL ADR of the 10.D round (7/7).**
  Co-drafted alongside ADR-0111..0116 across the autonomous
  /continue prep cycles. After Accept flip on all 7 ADRs,
  10.D closes and impl rows 10.M / 10.R / 10.TC / 10.E / 10.G
  unlock.
- 2026-05-26 — References enrichment via /continue autonomous
  prep path. Added concrete wasmtime file/line citations for
  Invariants I2 (return_call terminator shape — cranelift
  `code_translator.rs:748-764`), I3 (try_table reverse-order
  catch insertion — `code_translator.rs:612-649`), and I4
  (safepoint × moving-GC interaction — `func_environ.rs:1200-1215`,
  wasmtime's deferred-TODO comment that zwasm v2 codifies
  ahead-of-need). Replaces the generic
  `~/Documents/OSS/wasmtime/.../vm/` pointer with three
  specific cross-subsystem precedents. No semantic change to
  the 6 invariants.
- 2026-05-25 — Status: Proposed → **Accepted** (user collab 7/7;
  final ADR). All 6 invariants accepted as drafted (I1 exnref
  rooted across unwind / I2 tail-call no-leak / I3 FP-walk skips
  consumed frames / I4 try_table-over-GC-call stack-map / I5
  return_call-in-try-table doesn't catch / I6 `-Dgc=false`
  preserves EH+TC). 4 enhancements added: (a) at Phase 10 close
  (10.P), the 6 invariants get **promoted** to a permanent
  regression rule at `.claude/rules/p10_cross_subsystem_invariants.md`
  (auto-loaded for feature/gc/, feature/exception_handling/,
  engine/codegen/); (b) `-Dgc=false` build matrix runs at every
  per-chunk gate (CI build time +30% acceptable); (c) 6
  cross-fixtures land as **skeleton (.wat only; .expect filled
  per impl row)** at 10.T extension before any of 10.E/10.G/10.TC
  ship, so the cross fixture inventory is in place regardless of
  impl order. The 7-ADR round is now closed; impl rows unlock.
