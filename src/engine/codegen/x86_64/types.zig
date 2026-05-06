//! x86_64 emit pass — shared output / fixup types (D-030 chunk-a).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape: orchestrator types live in their
//! own module so future op_*.zig handler modules (op_const /
//! op_alu_int / op_alu_float / op_convert / op_memory / op_control
//! / op_call) can import them without circular references back to
//! emit.zig. Behaviour change zero — emit.zig re-exports each
//! symbol so external callers (`zwasm.zig`, `diagnostic/trace.zig`,
//! linker) continue to see them at the original module path.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Errors raised by the x86_64 emit pass. Mirrors arm64's set
/// so the §9.7 / 7.11 differential can match shapes; new
/// per-arch errors get added here as their consumers land.
pub const Error = error{
    AllocationMissing,
    UnsupportedOp,
    SlotOverflow,
    OutOfMemory,
};

/// Pending `CALL rel32` site requiring linker patch. Shape
/// mirrors arm64's CallFixup so the post-emit linker can reuse
/// the same fixup-record contract.
pub const CallFixup = struct {
    byte_offset: u32,
    target_func_idx: u32,
};

pub const EmitOutput = struct {
    bytes: []u8,
    n_slots: u8,
    call_fixups: []CallFixup,
};

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
    if (out.call_fixups.len != 0) allocator.free(out.call_fixups);
}
