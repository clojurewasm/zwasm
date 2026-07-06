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
const dbg = @import("../../../support/dbg.zig");

const Allocator = std.mem.Allocator;

/// Errors raised by the x86_64 emit pass. Mirrors arm64's set
/// so the arm64↔x86_64 differential can match shapes; new
/// per-arch errors get added here as their consumers land.
pub const Error = error{
    AllocationMissing,
    UnsupportedOp,
    SlotOverflow,
    OutOfMemory,
};

/// Centralised diagnostic for `Error.UnsupportedOp` rejects across
/// op-handler files (op_control / op_alu_int / op_alu_float /
/// op_call / etc). Every silent reject site goes through here so
/// the spec_assert / test runner stderr can identify **which**
/// structural path fired. Avoids per-file print scaffolding.
pub fn rejectUnsupported(reason: []const u8, ctx: u32) Error {
    dbg.print("codegen", "x86_64/op: UnsupportedOp[{s}] ctx={d}\n", .{ reason, ctx });
    return Error.UnsupportedOp;
}

/// Pending `CALL rel32` / `JMP rel32` site requiring linker
/// patch. Shape mirrors arm64's CallFixup so the post-emit linker
/// can reuse the same fixup-record contract.
///
/// `is_tail` mirrors arm64's flag (ADR-0112 D4): `false` → CALL
/// (0xE8 opcode), `true` → JMP (0xE9 opcode). The emit pass
/// writes the opcode byte; the linker only patches the `rel32`
/// displacement via `patchRel32`, which leaves the opcode byte
/// untouched — so the x86_64 linker patch loop ignores `is_tail`
/// (the emit-time opcode choice is load-bearing). Carried in the
/// shared record so per-arch handlers can read it uniformly when
/// useful (e.g. for diagnostic counters).
pub const CallFixup = struct {
    byte_offset: u32,
    target_func_idx: u32,
    is_tail: bool = false,
};

/// Pending `MOVUPS xmm, [RIP+disp32]` site requiring const-pool
/// patch (per ADR-0042 — x86_64 mirror of ARM64's
/// `SimdConstFixup`). The post-emit pass appends the per-function
/// const-pool past the spill region and patches each fixup's
/// disp32 to the RIP-relative offset of `func.simd_consts[const_idx]`.
/// `disp32_byte_offset` is the location of the 4-byte disp32 field
/// within the placeholder instruction (= MOVUPS opcode byte +
/// REX-aware offset).
pub const SimdConstFixup = struct {
    disp32_byte_offset: u32,
    post_insn_byte: u32,
    const_idx: u32,
};

const exception_table = @import("../shared/exception_table.zig");
const trap_registry = @import("../../../platform/trap_registry.zig"); // ADR-0202 D3

pub const EmitOutput = struct {
    bytes: []u8,
    n_slots: u16,
    call_fixups: []CallFixup,
    /// Per-function EH HandlerEntry slice (ADR-0114 +
    /// phase10_eh_integration_plan.md): harvested from
    /// the `ExceptionTable.Builder` at compile end. The linker folds the
    /// per-function slices into the per-Instance ExceptionTable on
    /// CompiledWasm. Empty for functions without try_table.
    exception_handlers: []const exception_table.HandlerEntry = &.{},
    /// Per-function aligned frame size in
    /// bytes (= prologue's `SUB RSP, frame_bytes`). Consumed by
    /// the linker to populate `CodeMap.Entry.frame_bytes`; the EH
    /// SP-restore path uses it to recover the handler frame's
    /// post-prologue SP boundary after `MOV RSP, RBP`.
    frame_bytes: u32 = 0,
    /// ADR-0202 D3 — byte offset (from body start) of this function's
    /// kind=6 oob trap stub, the guard-fault PC-redirect target. The
    /// linker adds the function's absolute base to build the trap
    /// registry's FuncEntry. `FuncEntry.no_stub` when the function has
    /// no bounds-checked memory access.
    oob_stub_off: u32 = trap_registry.FuncEntry.no_stub,
};

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
    if (out.call_fixups.len != 0) allocator.free(out.call_fixups);
    if (out.exception_handlers.len != 0) allocator.free(out.exception_handlers);
}
