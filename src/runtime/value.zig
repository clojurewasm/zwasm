//! WASM Spec §4.2.2 "Values" — runtime value representation.
//!
//! Per ADR-0023 §3 P-D: extracted from the previous monolithic
//! `runtime/runtime.zig` so each WASM Spec §4.2 concept lives in
//! its own file under `runtime/`. The extern union shape is
//! load-bearing per ROADMAP §P3 (cold-start: no per-slot type
//! byte) and §P13 (type up-front: invariants fixed at design time).
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

/// 64-bit value slot. The dispatch loop knows the type from the
/// `ZirOp`; the union never carries a runtime tag (per §P3
/// cold-start: no per-slot type byte). Float values are stored as
/// their IEEE-754 bit pattern via `bits64` on entry/exit so NaN
/// canonicalisation can be deferred to the boundary opcodes that
/// need it (Wasm 1.0 §6.2.3).
pub const Value = extern union {
    i32: i32,
    u32: u32,
    i64: i64,
    u64: u64,
    f32: f32,
    f64: f64,
    bits64: u64,
    /// Reference value (Wasm 2.0 §9.2 / 2.3 chunk 5). Funcref:
    /// `@intFromPtr(*const FuncEntity)` — the pointer carries
    /// source-runtime identity so cross-module `call_indirect`
    /// can route to the source's function table without a
    /// separate routing layer (per ADR-0014 §2.1 / 6.K.1).
    /// Externref: opaque 64-bit host handle (unchanged). The
    /// sentinel `null_ref` represents the spec null reference;
    /// it equals literal `0` because `c_allocator.alloc` cannot
    /// return address 0 on any of the three target platforms
    /// (Mac aarch64 darwin, Linux x86_64 glibc/musl, Windows
    /// x86_64 ucrt) per the C-standard `malloc` contract.
    ref: u64,

    pub const zero: Value = .{ .bits64 = 0 };
    pub const null_ref: u64 = 0;

    pub fn fromI32(v: i32) Value {
        return .{ .i32 = v };
    }
    pub fn fromI64(v: i64) Value {
        return .{ .i64 = v };
    }
    pub fn fromF32Bits(b: u32) Value {
        return .{ .bits64 = b };
    }
    pub fn fromF64Bits(b: u64) Value {
        return .{ .bits64 = b };
    }
    pub fn fromRef(r: u64) Value {
        return .{ .ref = r };
    }

    /// Encode a `*FuncEntity` as a funcref `Value`. The pointer
    /// must outlive every read of this Value (its lifetime is
    /// tied to the owning Runtime's `func_entities` array, which
    /// the per-instance arena holds for the Runtime's lifetime).
    pub fn fromFuncRef(fe: *const FuncEntity) Value {
        return .{ .ref = @intFromPtr(fe) };
    }

    /// Decode a funcref `Value` to its `*const FuncEntity` source,
    /// or `null` if the cell holds the null reference.
    pub fn refAsFuncEntity(v: Value) ?*const FuncEntity {
        if (v.ref == null_ref) return null;
        return @ptrFromInt(v.ref);
    }
};

comptime {
    // Locks in the platform contract above: any future change to
    // null_ref must re-survey the malloc guarantees on all three
    // target hosts. A change here without an ADR is a §18 deviation.
    std.debug.assert(Value.null_ref == 0);
}

/// Per-runtime function handle. One entry per index in
/// `Runtime.funcs`; allocated in `instantiateRuntime`. A funcref
/// `Value` stores `@intFromPtr(*const FuncEntity)` so dereference
/// reveals which Runtime owns the callee body — the encoding
/// 6.K.3 needs to drop the cross-module-import error returns.
///
/// Per ADR-0014 §2.1 / 6.K.1: the source runtime back-ref lives
/// here (rather than baked into the Runtime via 6.K.2's Instance
/// back-ref) because the Value's encoding contract is what matters
/// for the table cell — every consumer dereferences the FuncEntity
/// and reads `runtime` + `func_idx` from a single cache line.
pub const FuncEntity = struct {
    /// Runtime whose `funcs[func_idx]` (and `host_calls[func_idx]`
    /// when imported) describes the callee body.
    runtime: *@import("runtime.zig").Runtime,
    /// Index into `runtime.funcs`.
    func_idx: u32,
};

const testing = std.testing;

test "Value: extern union slot is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Value));
}

test "Value.fromI32 / fromI64 round-trip" {
    const a = Value.fromI32(-7);
    try testing.expectEqual(@as(i32, -7), a.i32);

    const b = Value.fromI64(0x7FFF_FFFF_FFFF_FFFF);
    try testing.expectEqual(@as(i64, 0x7FFF_FFFF_FFFF_FFFF), b.i64);
}

test "Value.fromF32Bits / fromF64Bits store IEEE bits" {
    const f32_one_bits: u32 = 0x3F800000;
    const a = Value.fromF32Bits(f32_one_bits);
    try testing.expectEqual(@as(u64, f32_one_bits), a.bits64);

    const f64_one_bits: u64 = 0x3FF0_0000_0000_0000;
    const b = Value.fromF64Bits(f64_one_bits);
    try testing.expectEqual(f64_one_bits, b.bits64);
}
