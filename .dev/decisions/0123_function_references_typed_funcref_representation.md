# ADR-0123 — function-references (10.R): typed-funcref representation + call_ref sig-dispatch

- **Status**: Accepted (2026-05-28 — cycle 90 revision under "完成形がきれい" lens; user-delegated autonomous flip)
- **Date**: 2026-05-28
- **Tags**: wasm-3.0, function-references, valtype, call_ref, zir, phase10
- **Deciders**: autonomous /continue loop (drafts); user (Accept flip)

## Context

ROADMAP §10 row 10.R implements the Wasm 3.0 function-references
proposal: `ref.as_non_null` / `br_on_null` / `br_on_non_null` /
`call_ref` / `return_call_ref` + `(ref $sig)` / `(ref null $sig)`
typed function references.

Current state (Step-0 survey, 10.R cycle 48):

- All 5 ops have `ZirOp` tags (`src/ir/zir_ops.zig:514-520`).
- `ref.as_non_null` / `br_on_null` / `br_on_non_null` are **parsed +
  validated + interpreted** with the *generic* `funcref` reftype
  (`src/validate/validator.zig:1675-1756`); JIT-stubbed.
- `call_ref` / `return_call_ref` are **parsed only**; validate / lower
  / interp return `error.NotMigrated`
  (`src/instruction/wasm_3_0/call_ref.zig`). `return_call_ref` has
  arm64+x86_64 emit skeletons returning `UnsupportedOp`.
- `ValType` (`src/ir/zir.zig:21-54`) is `enum(u8)` — no `(ref $sig)`
  variant, and a bare enum tag cannot carry the sig **index**.
- `validator.zig:1672-1674` already records the intent: "nullability
  narrowing lands at 10.G (WasmGC) where `(ref $sig)` typed refs need
  their own typed-ref module."

No existing ADR decides the typed-funcref **representation**.
ADR-0116 §95-97 names `(ref $func_type)` in the conceptual type
hierarchy but **explicitly scopes typed-funcref impl out** (§229:
"by typed-funcref work; cycle 20+ outside scope"). ADR-0112 leaves
`return_call_ref` green-field. Implementing 10.R therefore needs a
load-bearing §4 decision recorded **first** (ROADMAP §18.2 /
deviation-watch).

## Decision (revised 2026-05-28 cycle 90 — "完成形がきれい" lens)

**The original D1 ("keep ValType narrow, side-band the sig-index")
was structurally a workaround**: it side-stepped the spec-mandated
type system to defer cost. The cycle-90 industry survey (wasmtime
`WasmRefType { nullable, heap_type }`; wasm-tools `RefType(u32)`
bit-packed; WAMR's `WASMRefTypeMap*` side-band; wazero's
backward-compat u64 widening) all confirmed: typed-ref representation
in ValType is **not deferrable** if v2 wants to parse function-
references modules that use `(local (ref $t))` / `(param (ref $t))` /
`(global (ref $t))` / table element type `(ref $t)` (15 of 103 spec
test files). The original D1 architecturally couldn't represent these.

Per user direction "AI は人間の 10x 速い → workaround を避け、あるべ
き論の選択肢をとってください" (cycle 90), this ADR pivots to the clean
wasmtime-style design. Zig's `union(enum)` makes tagged unions
ergonomic in a way C (WAMR) and Go (wazero) lack, removing the
constraint that drove peer runtimes' side-band/widening tricks.

**D1 (revised) — Widen `ValType` to a tagged union with `Ref(RefType)`
variant.**

```zig
pub const ValType = union(enum) {
    i32, i64, f32, f64, v128,
    ref: RefType,
};

pub const RefType = struct {
    nullable: bool,
    heap_type: HeapType,
};

pub const HeapType = union(enum) {
    /// Abstract heaps: func / extern / any / eq / i31 / struct /
    /// array / none / noextern / nofunc / exn / noexn.
    abstract: AbstractHeapType,
    /// Concrete typed reference: `(ref null? $typeidx)`.
    concrete: u32, // type section index
};

pub const AbstractHeapType = enum(u8) {
    func, extern_, any, eq, i31, struct_, array,
    none, noextern, nofunc, exn, noexn,
};
```

Old abstract-ref variants (`funcref`, `externref`, `i31ref`,
`anyref`, `eqref`, `structref`, `arrayref`) become spelt as
`.ref = .{ .nullable = true, .heap_type = .{ .abstract = .func } }`
etc. A helper constructor `ValType.absRef(.func, .nullable)`
preserves call-site ergonomics during the migration.

**D2 (revised) — Static nullability narrowing from day 1.**
Validator narrows `(ref null ht)` → `(ref ht)` after
`ref.as_non_null` / `br_on_null` (fallthrough). `br_on_non_null` cross-
checks branch label's expected nullability. `ref.func $f` yields
non-nullable `(ref ht)` per spec §3.3.10.10. This is what wasmtime /
wasm-tools / WAMR all do at validation time; deferring it costs the
~4 assert_invalid spec tests that test narrowing in `(local (ref $t))`
contexts. With ValType already widened (D1), narrowing is a small
addition to the existing validator type-stack tracking, not a
disruptive refactor.

**D3 — `call_ref` runtime sig-dispatch mirrors `call_indirect`.**
Unchanged from original draft. `call_ref` pops a funcref; traps
`NullReference` on null; reuses the existing indirect-call sig-check
shape. The typed-ref's concrete typeidx flows through `ZirInstr.payload`
as before; runtime check exists because wasmtime / WAMR also keep it
(`func_environ.rs:2155-2170` FIXME: "validator narrowing info not
piped down" — even wasmtime hasn't elided the runtime null-check).

**D4 — `return_call_ref` = `call_ref` + frame teardown.** Unchanged.
ADR-0112 tail-call frame_teardown + D3 null+sig checks. D-186
discharge predicate unchanged.

**D5 (new) — 10.G GC heap types extend RefType without rework.**
The GC heap types (struct/array/i31/exn) already need representation
when 10.G's ref.cast / ref.test / br_on_cast land. Under D1's tagged
union, they're additional `HeapType.abstract` variants OR new
`HeapType.concrete` shapes for `(ref $structtype)` / `(ref $arraytype)`.
No second refactor needed — 10.R + 10.G + 10.E share the same
`ValType.Ref` shape.

## Alternatives (revised cycle 90)

- **Original D1 (no widen; side-band sig-index in payload)**.
  Rejected on revision per cycle-90 survey: provably cannot represent
  `(local (ref $t))` / `(param (ref $t))` etc.; would fail 15/103 spec
  test files at parse, not just at narrowing. The original ADR draft
  conflated "instruction-level typed-ref" (which CAN be side-banded
  via ZirInstr.payload) with "container-level typed-ref in
  FuncType/locals/globals/tables" (which CANNOT). The revised design
  resolves the latter cleanly.
- **WAMR-style side-band** (`uint8 types[]` + parallel
  `ref_type_maps[i]` keyed by position). Rejected: works in C where
  tagged unions are awkward; Zig's `union(enum)` is the natural fit.
  The side-band would touch every type-bearing container (FuncType /
  LocalTypes / GlobalType / TableType) AND every place that consumes
  them, paying churn cost with no representation benefit.
- **Wazero-style backward-compat u64 widening** (low byte = old
  encoding kind; upper bits = nullability + index). Rejected: works in
  Go where tagged unions are absent; Zig's `union(enum)` removes the
  constraint. Backward-compat bit-encoding is unnecessary for v2's
  from-scratch ValType.
- **A3 — call_ref via synthetic single-entry table** (literally reuse
  call_indirect machinery). Rejected as before: adds a fake table +
  bounds check the spec doesn't mandate.

## Consequences (revised cycle 90)

1. **Spec-conformant typed-ref from day 1**: every spec test in
   function-references/* that uses `(local (ref $t))` /
   `(param (ref $t))` etc. (15 of 103 files) becomes parseable. 36
   currently-failing assert_return + 4 trap fixtures move from
   "blocked at parse" to "tractable for impl".
2. **One Phase-wide ValType refactor, not two**: 10.R does the
   widening; 10.G's GC heap types reuse the `RefType` shape via
   additional `HeapType` variants. Per cycle-90 design audit, this is
   strictly cheaper than 10.R-side-band + 10.G-widening = 2 refactors.
3. **Validator narrowing from day 1**: ~4 currently-deferred
   assert_invalid spec tests pass. No "narrowing-strictness debt" row
   needed.
4. **Call-site migration cost (AI-implementation-scale)**: every site
   that does `switch (vt) { .funcref => ... }` becomes
   `switch (vt) { .ref => |r| switch (r.heap_type) { ... } }`. ~100
   call sites (parse + validate + ir + interp + engine + runtime).
   At AI implementation velocity (per user CLAUDE.md guidance),
   estimated 5-10 bundle cycles.
5. **Implementation order (bundle 10.R-valtype-widen)**:
   - **Cycle 1**: Add `RefType` + `HeapType` + `AbstractHeapType` to
     zir.zig alongside existing enum ValType. Add `ValType.absRef`
     constructor helper. New types are unused.
   - **Cycle 2**: Convert ValType from `enum(u8)` to `union(enum)`
     with `.ref: RefType` variant. Migrate the 7 abstract-ref enum
     tags to be expressed via `.ref = .{ .nullable=true, .heap_type=
     .{ .abstract = .X } }`. This is the disruptive cycle — every
     `switch (vt)` site touched. Compiler errors guide migration.
   - **Cycle 3**: Add `0x63` / `0x64` parsing in
     `src/parse/sections.zig::readValType`; concrete-typeidx
     `RefType.heap_type = .{ .concrete = idx }` flows through.
   - **Cycle 4**: Validator static narrowing — ref.as_non_null /
     br_on_null / br_on_non_null narrow the type-stack entry's
     `RefType.nullable` field. ref.func yields non-nullable.
   - **Cycle 5**: call_ref / return_call_ref impl per D3 / D4.
   - **Cycle 6-N**: spec corpus pass-rate increases.
6. **No regressions on non-function-references corpora**: the cycle-2
   ValType migration is a pure refactor; existing memory64 /
   multi-memory / tail-call / EH paths see only structural changes,
   not behaviour changes.

## References

- ROADMAP §10 row 10.R; §18.2 (deviation → ADR-first).
- ADR-0112 (tail-call; return_call_ref frame teardown, green-field note).
- ADR-0116 §95-97 (type hierarchy naming `(ref $func_type)`), §229
  (typed-funcref impl explicitly out of GC-cycle scope).
- `src/ir/zir.zig:21-54` (ValType enum), `:104-107` (ZirInstr
  payload/extra).
- `src/instruction/wasm_3_0/call_ref.zig` (current stub),
  `src/validate/validator.zig:1672-1756` (non-narrowing ref ops).
- `src/interp/trap_audit.zig:73-103` (call_indirect sig-dispatch
  pattern reused by D3).
- Debt D-186 (return_call_ref blocked-by 10.R; unblocked by D4).

## Revision history

| Date | Commit | Notes |
|------|--------|-------|
| 2026-05-28 | `c786a2d8` | Initial Proposed (10.R cycle 48, Step-0 survey outcome). D1: side-band sig-index; D2: defer narrowing to 10.G. |
| 2026-05-28 | `d6b187f8` | Accepted + revised under "完成形がきれい" lens (cycle 90). D1 pivots from side-band to full ValType widening (wasmtime-style tagged union); D2 reverses to "narrow from day 1"; D5 added (10.G GC heap-types extend cleanly). Industry survey (wasmtime / wasm-tools / WAMR / wazero) confirmed the original D1 was structurally a workaround that couldn't represent `(local (ref $t))` at all. Bundle `10.R-valtype-widen` opens with the cycle 1-5 sequence in Consequences §5. |
