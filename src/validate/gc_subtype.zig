//! Wasm 3.0 GC structural subtyping + valtype-subtype helpers, extracted from
//! `validator.zig` (D-204) to keep that file under its size cap. These are PURE
//! file-scope helpers — they take `ValType` / `zir.*` / `sections.*` and touch
//! NO Validator instance state — so they form a separable P1 GC-subtype
//! sub-language (ADR-0124). `validator.zig` calls them via `gc_subtype.<fn>`.
//!
//! SIBLING-PUB: the `pub fn`s here are consumed only by the sibling
//! `validator.zig` (P1 spec-defined GC subtype sub-language); the pub-ness is
//! an extraction artifact (D-204), not a wide public API surface.
const zir = @import("../ir/zir.zig");
const sections = @import("../parse/sections.zig");
const ValType = zir.ValType;

/// Returns true iff `actual` is assignment-compatible with `expected`
/// per the Wasm 3.0 subtype rules subset implemented for 10.R:
/// - Identical types match.
/// - Non-null ref is a subtype of nullable ref of the same heap_type.
/// - Full heap-type subtype lattice (any > eq > struct/array/i31; etc.)
///   deferred to 10.G.
pub fn valTypeIsSubtypeFree(actual: ValType, expected: ValType) bool {
    if (actual.eql(expected)) return true;
    if (actual != .ref or expected != .ref) return false;
    // Non-null actual satisfies a nullable expected; not vice-versa.
    if (actual.ref.nullable and !expected.ref.nullable) return false;
    const ah = actual.ref.heap_type;
    const eh = expected.ref.heap_type;
    return switch (ah) {
        .concrete => |a_idx| switch (eh) {
            .concrete => |e_idx| a_idx == e_idx,
            // ADR-0123: a concrete typed ref `(ref $sig)` is a subtype
            // of the abstract `func` head — `ref.func N` (typed) must
            // still satisfy `funcref` globals/tables/params (ref_func.1).
            // Pre-GC the type section holds only func types, so every
            // concrete ref is a funcref; 10.G refines this once
            // struct/array defs (non-func heads) enter module_types.
            .abstract => |e_abs| e_abs == .func,
        },
        // An abstract head never narrows to a concrete type. Abstract→
        // abstract follows the Wasm 3.0 GC §4.2.8 heap-type lattice
        // (i31/eq/struct/array <: any, etc.), so (ref i31) satisfies an
        // anyref slot — global.set/table-init/return into anyref of i31
        // (gc/i31.5, i31.6). Pre-GC heads (func/extern) are disjoint, so
        // this is identity for them (no regression).
        .abstract => |a_abs| switch (eh) {
            .abstract => |e_abs| gcHeapAbstractSubtype(a_abs, e_abs),
            .concrete => false,
        },
    };
}

// ============================================================
// WasmGC structural subtype validation (ADR-0124).
// ============================================================

/// Wasm 3.0 GC §4.2.8 abstract heap-type lattice: is `a <: e`?
/// `any`/`eq`/`struct`/`array`/`i31`/`none` are one hierarchy
/// (none = bottom, any = top); `func`/`nofunc`, `extern`/`noextern`,
/// `exn`/`noexn` are disjoint hierarchies.
pub fn gcHeapAbstractSubtype(a: zir.AbstractHeapType, e: zir.AbstractHeapType) bool {
    if (a == e) return true;
    return switch (e) {
        .any => switch (a) {
            .eq, .i31, .struct_, .array, .none => true,
            .func, .extern_, .any, .noextern, .nofunc, .exn, .noexn => false,
        },
        .eq => switch (a) {
            .i31, .struct_, .array, .none => true,
            .func, .extern_, .any, .eq, .noextern, .nofunc, .exn, .noexn => false,
        },
        .struct_ => a == .none,
        .array => a == .none,
        .i31 => a == .none,
        .func => a == .nofunc,
        .extern_ => a == .noextern,
        .exn => a == .noexn,
        // Bottoms have no proper subtypes.
        .none, .nofunc, .noextern, .noexn => false,
    };
}

/// True if concrete type `super_idx` is reachable from `sub_idx` via
/// its declared supertype chain (transitive). Visited-bounded against
/// malformed cycles (chains are shallow in practice).
pub fn gcConcreteReaches(sub_idx: u32, super_idx: u32, supertypes: []const []const u32) bool {
    if (sub_idx == super_idx) return true;
    if (sub_idx >= supertypes.len) return false;
    var depth: u32 = 0;
    var cur = sub_idx;
    // Single-supertype chains dominate the corpus; walk the first
    // declared supertype up to a small bound, also scanning the
    // declared set at each level.
    while (depth < 64) : (depth += 1) {
        if (cur >= supertypes.len) return false;
        const supers = supertypes[cur];
        if (supers.len == 0) return false;
        for (supers) |s| if (s == super_idx) return true;
        cur = supers[0];
        if (cur == sub_idx) return false; // cycle guard
    }
    return false;
}

/// Like `gcConcreteReaches` but compares each chain member to `super_idx` by
/// iso-recursive CANONICAL equality, not raw index (Wasm 3.0 GC §3.3). A
/// declared supertype may live in a different rec group yet be the same
/// canonical type as `super_idx` (`gc/type-subtyping.12/.14`: `$h <: $g2 <:
/// $f2`, and `$f2 ≡ $f1` via isomorphic rec groups, so `$h <: $f1`). Used on
/// the global-init / module-validation path where the full `Types` is alive.
pub fn gcConcreteReachesCanonical(sub_idx: u32, super_idx: u32, types: *const sections.Types) bool {
    if (sub_idx == super_idx or sections.canonicalEqual(types, sub_idx, super_idx)) return true;
    var depth: u32 = 0;
    var cur = sub_idx;
    while (depth < 64) : (depth += 1) {
        if (cur >= types.supertypes.len) return false;
        const supers = types.supertypes[cur];
        if (supers.len == 0) return false;
        for (supers) |s| if (s == super_idx or sections.canonicalEqual(types, s, super_idx)) return true;
        cur = supers[0];
        if (cur == sub_idx) return false; // cycle guard
    }
    return false;
}

/// Wasm 3.0 GC §4.2.8 valtype subtyping (lattice + concrete chain).
/// Extends `valTypeIsSubtypeFree` with the GC heap lattice + the
/// declared-supertype chain for concrete refs.
pub fn gcValTypeSubtype(actual: ValType, expected: ValType, types: *const sections.Types) bool {
    if (actual.eql(expected)) return true;
    if (actual != .ref or expected != .ref) return false;
    if (actual.ref.nullable and !expected.ref.nullable) return false;
    const ah = actual.ref.heap_type;
    const eh = expected.ref.heap_type;
    return switch (ah) {
        .concrete => |a_idx| switch (eh) {
            // Declared-chain reach OR iso-recursive canonical equality
            // (ADR-0126): a raw index that does not reach the target by
            // declared supertypes may still be the same canonical type
            // (cross-rec-group structural identity, Wasm 3.0 GC §3.3).
            .concrete => |e_idx| gcConcreteReachesCanonical(a_idx, e_idx, types),
            .abstract => |e_abs| blk: {
                // A concrete ref's head is the kind of its typedef.
                const head: zir.AbstractHeapType = if (a_idx >= types.kinds.len) .any else switch (types.kinds[a_idx]) {
                    .func => .func,
                    .structdef => .struct_,
                    .arraydef => .array,
                };
                break :blk gcHeapAbstractSubtype(head, e_abs);
            },
        },
        .abstract => |a_abs| switch (eh) {
            .abstract => |e_abs| gcHeapAbstractSubtype(a_abs, e_abs),
            .concrete => false,
        },
    };
}

/// Field/element subtyping: mutability must match; a `var` (mutable)
/// field is INVARIANT (types equal), a `const` field is COVARIANT.
pub fn gcFieldSubtype(sub_f: sections.StructFieldType, sup_f: sections.StructFieldType, types: *const sections.Types) bool {
    if (sub_f.mutable != sup_f.mutable) return false;
    // ADR-0125 — storage class must match: a packed field is never a
    // subtype of a non-packed one, and packed types are invariant
    // (i8 <: i8, i16 <: i16; no cross/widening). Compare the wire byte.
    const sub_p = sub_f.storage.isPacked();
    if (sub_p != sup_f.storage.isPacked()) return false;
    if (sub_p) return sub_f.storage.specByte() == sup_f.storage.specByte();
    const sub_v = sub_f.storage.operandType();
    const sup_v = sup_f.storage.operandType();
    if (sub_f.mutable) return sub_v.eql(sup_v); // invariant
    return gcValTypeSubtype(sub_v, sup_v, types); // covariant
}
