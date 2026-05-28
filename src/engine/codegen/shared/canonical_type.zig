//! Canonical typeidx resolution — Wasm spec §3.4.6 type
//! equivalence for `call_indirect` checks.
//!
//! The spec (§4.4.10.1) requires the funcref's stored type to
//! **match** the call_indirect's annotated type. "Match" =
//! structurally equivalent (same param + result valtype
//! sequence), not nominal typeidx equality. A module may
//! declare the same FuncType shape multiple times at different
//! typeidx — the spec testsuite's `dispatch-structural-*` and
//! `signature-explicit-duplicate` fixtures exercise this.
//!
//! Our runtime sig check is a bytewise typeidx compare (`CMP
//! W16, #expected` on arm64; analogous on x86_64). To make
//! that compare structurally correct, we collapse aliases at
//! both sides:
//!
//! - emit (`call_indirect`): substitute `canonicalTypeidx(t)`
//!   for `t`.
//! - applyTableInit (table entry's typeidx): same substitution
//!   on the funcref's stored typeidx.
//!
//! `canonicalTypeidx(t)` = the lowest typeidx `c ≤ t` whose
//! FuncType is structurally equal to `types[t]`. Idempotent.
//!
//! O(n_types) per call; module type tables are small in practice
//! (~30 types is typical, low hundreds for very large modules).
//! Pre-computing the full mapping for module-wide reuse is
//! optional — the inline shape suffices today.

const std = @import("std");
const zir = @import("../../../ir/zir.zig");

/// Wasm spec §3.4.6 type equivalence for function types. Two
/// FuncTypes are equivalent iff they have the same valtype
/// sequence for parameters AND results. valtype equality is
/// structural for the MVP scalar set (i32/i64/f32/f64/v128) +
/// nominal for the reftype set (funcref/externref) — both
/// handled by `==` on the `zir.ValType` enum.
pub fn funcTypeEql(a: zir.FuncType, b: zir.FuncType) bool {
    if (a.params.len != b.params.len) return false;
    if (a.results.len != b.results.len) return false;
    for (a.params, b.params) |x, y| if (!x.eql(y)) return false;
    for (a.results, b.results) |x, y| if (!x.eql(y)) return false;
    return true;
}

/// Returns the canonical (lowest-index) typeidx whose FuncType
/// is structurally equal to `types[t]`. Out-of-range `t` is
/// returned unchanged (caller checks bounds; the compile-time
/// validator already rejected OOB typeidx earlier in the
/// pipeline). When `types[t]` is unique within `types[0..t]`,
/// `t` itself is canonical.
pub fn canonicalTypeidx(types: []const zir.FuncType, t: u32) u32 {
    if (t >= types.len) return t;
    const target = types[t];
    var i: u32 = 0;
    while (i < t) : (i += 1) {
        if (funcTypeEql(types[i], target)) return i;
    }
    return t;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "canonicalTypeidx: no aliases — each typeidx canonicalizes to itself" {
    const t0: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const t1: zir.FuncType = .{ .params = &.{.i32}, .results = &.{} };
    const t2: zir.FuncType = .{ .params = &.{ .i32, .i64 }, .results = &.{.f32} };
    const types = [_]zir.FuncType{ t0, t1, t2 };
    try testing.expectEqual(@as(u32, 0), canonicalTypeidx(&types, 0));
    try testing.expectEqual(@as(u32, 1), canonicalTypeidx(&types, 1));
    try testing.expectEqual(@as(u32, 2), canonicalTypeidx(&types, 2));
}

test "canonicalTypeidx: duplicate-shape types collapse to the lowest index" {
    const empty: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const t1: zir.FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    // `t3` shares shape with `t1`; both should canonicalize to 1.
    const types = [_]zir.FuncType{ empty, t1, empty, t1 };
    try testing.expectEqual(@as(u32, 0), canonicalTypeidx(&types, 0));
    try testing.expectEqual(@as(u32, 1), canonicalTypeidx(&types, 1));
    try testing.expectEqual(@as(u32, 0), canonicalTypeidx(&types, 2));
    try testing.expectEqual(@as(u32, 1), canonicalTypeidx(&types, 3));
}

test "funcTypeEql: differing param count rejects" {
    const a: zir.FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const b: zir.FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
    try testing.expect(!funcTypeEql(a, b));
}

test "funcTypeEql: differing result valtype rejects" {
    const a: zir.FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    const b: zir.FuncType = .{ .params = &.{.i32}, .results = &.{.i64} };
    try testing.expect(!funcTypeEql(a, b));
}

test "canonicalTypeidx: out-of-range typeidx returns unchanged" {
    const types = [_]zir.FuncType{
        .{ .params = &.{}, .results = &.{.i32} },
    };
    try testing.expectEqual(@as(u32, 5), canonicalTypeidx(&types, 5));
}
