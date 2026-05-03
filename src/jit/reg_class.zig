//! JIT register-class info (§9.7 / 7.0).
//!
//! Owns the canonical `RegClassInfo` table that the §9.7 / 7.1
//! greedy-local allocator + §9.7 / 7.2 jit_arm64 ABI consume.
//! `zir.RegClass` (Zone 1) defines the variant set so the IR
//! shape carries class identity; this module (Zone 2) owns the
//! per-class info — register-file size, slot width, call-
//! clobbered status, etc.
//!
//! Phase-7 / 7.0 scope: name the classes + supply placeholder
//! info entries that downstream passes can extend. Real machine-
//! register tables (which physical aarch64 / x86 register IS in
//! each class) land in §9.7 / 7.2's per-arch ABI module —
//! splitting class identity (here) from register inventory
//! (per-arch) is the W54-class lesson made structural: a JIT
//! that mixes the two on the same enum drifts the regalloc IR
//! shape per backend, which is what produced the v1 D117
//! dual-entry self-call workaround.
//!
//! Zone 2 (`src/jit/`).

const std = @import("std");

const zir = @import("../ir/zir.zig");

pub const RegClass = zir.RegClass;

/// Per-class invariants the regalloc consults independently of
/// the per-arch register inventory. Width / alignment are in
/// bits + bytes respectively to match the most-asked-of-the-
/// table shapes (operand width during emit; spill-slot stride
/// during regalloc spilling). `call_clobbered_default` is the
/// "what's the default callee assumption when no per-callee
/// override applies" bit — per-arch ABIs override per-register
/// in their own tables.
pub const RegClassInfo = struct {
    width_bits: u16,
    spill_align_bytes: u8,
    /// True when ZIR-level identity reservation per the W54
    /// post-mortem demands a special slot in the regalloc IR
    /// (inst_ptr / vm_ptr / simd_base). Drives the v1 D117
    /// dual-entry-workaround prevention: if this is set, the
    /// regalloc MUST keep the value alive across calls without
    /// per-callsite save/restore — the live range is the slot
    /// itself, not a regular vreg.
    is_special_cache: bool,
};

/// Lookup table — flat slice indexed by `@intFromEnum(class)`.
/// Indexed access keeps the regalloc inner loop branch-free.
/// Length matches the count of named variants in `RegClass`
/// (the trailing `_` non-exhaustive placeholder in the enum is
/// not counted; out-of-range queries return null via `info`).
const info_table = [_]RegClassInfo{
    // gpr
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = false },
    // fpr
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = false },
    // simd
    .{ .width_bits = 128, .spill_align_bytes = 16, .is_special_cache = false },
    // inst_ptr_special
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = true },
    // vm_ptr_special
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = true },
    // simd_base_special
    .{ .width_bits = 64, .spill_align_bytes = 8, .is_special_cache = true },
};

/// Look up the per-class invariants. Returns null for the
/// non-exhaustive `_` placeholder (i.e. an unknown future
/// variant) so callers can assert "we cover every named class"
/// at the regalloc layer.
pub fn info(class: RegClass) ?RegClassInfo {
    const idx = @intFromEnum(class);
    if (idx >= info_table.len) return null;
    return info_table[idx];
}

const testing = std.testing;

test "info: every named RegClass variant has an info entry" {
    try testing.expect(info(.gpr) != null);
    try testing.expect(info(.fpr) != null);
    try testing.expect(info(.simd) != null);
    try testing.expect(info(.inst_ptr_special) != null);
    try testing.expect(info(.vm_ptr_special) != null);
    try testing.expect(info(.simd_base_special) != null);
}

test "info: gpr is 64-bit, 8-byte spill, not a special cache" {
    const i = info(.gpr).?;
    try testing.expectEqual(@as(u16, 64), i.width_bits);
    try testing.expectEqual(@as(u8, 8), i.spill_align_bytes);
    try testing.expect(!i.is_special_cache);
}

test "info: simd is 128-bit, 16-byte spill" {
    const i = info(.simd).?;
    try testing.expectEqual(@as(u16, 128), i.width_bits);
    try testing.expectEqual(@as(u8, 16), i.spill_align_bytes);
    try testing.expect(!i.is_special_cache);
}

test "info: every *_special variant is is_special_cache=true (W54 lesson)" {
    try testing.expect(info(.inst_ptr_special).?.is_special_cache);
    try testing.expect(info(.vm_ptr_special).?.is_special_cache);
    try testing.expect(info(.simd_base_special).?.is_special_cache);
}

test "info: unknown future variant returns null (non-exhaustive enum)" {
    // The `_` placeholder in `RegClass` lets us instantiate a
    // value outside the named set; the info() lookup must
    // graceful-degrade rather than index out-of-bounds.
    const future: RegClass = @enumFromInt(99);
    try testing.expect(info(future) == null);
}

test "RegClass identity: re-export from zir.RegClass round-trips" {
    // Sanity: this module's `RegClass` IS `zir.RegClass`. The
    // §4.2 slot identity is preserved (changing this aliasing
    // would be a §4.2 deviation requiring an ADR).
    const x: zir.RegClass = .gpr;
    const y: RegClass = x;
    try testing.expectEqual(@as(u8, 0), @intFromEnum(y));
}
