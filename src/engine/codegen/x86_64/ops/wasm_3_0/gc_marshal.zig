//! Shared Win64/SysV arg-marshal helper for the ≥5-arg GC-op emit
//! handlers (array.copy / fill / init_data / init_elem / new_data /
//! new_elem). Each helper trampoline is `callconv(.c)`, so args must
//! follow `abi.current.arg_gprs` per the active CC (D-248).
//!
//! SysV has 6 GPR arg slots (arg0 = RDI = runtime ptr), so all of
//! these ops fit in registers and `routeArg` always takes the
//! register path — byte-identical to the pre-D-248 emit. Win64 has
//! only 4 GPR arg slots (RCX/RDX/R8/R9); a 5th/6th arg spills to the
//! caller's outgoing region ABOVE the 32-byte shadow space, at
//! `[RSP + shadow_space_bytes + 8*(arg_idx - arg_gprs.len)]`. The
//! prologue (`computeOutgoingMaxBytes`, GC-op branch) reserves that
//! region so the store lands inside the frame, not on the return
//! address.

const abi = @import("../../abi.zig");
const ctx_mod = @import("../../ctx.zig");
const inst = @import("../../inst.zig");
const reg_class = @import("../../reg_class.zig");

const Width = reg_class.Width;
const Gpr = abi.Gpr;

/// Route a single already-loaded source register `src` to its
/// `callconv(.c)` argument position `arg_idx` (0-based over the full
/// arg list, where arg_idx 0 = the runtime ptr in arg_gprs[0]).
///
/// `width` is the move size (.d for i32 args, .q for array.fill's
/// 64-bit `value`). When `arg_idx < arg_gprs.len` the arg lives in a
/// register: emit `MOV arg_gprs[arg_idx], src` (elided when already
/// in place). Otherwise (Win64 only — SysV's pool is large enough
/// that this branch is comptime-unreachable for these ops) spill to
/// the outgoing region.
pub fn routeArg(
    ctx: *ctx_mod.EmitCtx,
    arg_idx: u32,
    src: Gpr,
    width: Width,
) ctx_mod.Error!void {
    if (arg_idx < abi.current.arg_gprs.len) {
        const dst = abi.current.arg_gprs[arg_idx];
        if (src != dst) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(width, dst, src).slice());
        return;
    }
    // Spill slot: above the shadow space, one 8-byte slot per
    // overflowed arg. SysV never reaches here (arg_gprs.len == 6 >
    // any of these ops' arg counts), so the disp formula is Win64's.
    const disp: i32 = @intCast(abi.current.shadow_space_bytes + 8 * (arg_idx - abi.current.arg_gprs.len));
    switch (width) {
        .d => try ctx.buf.appendSlice(ctx.allocator, inst.encStoreR32MemRSPDisp32(src, disp).slice()),
        .q => try ctx.buf.appendSlice(ctx.allocator, inst.encStoreR64MemRSPDisp32(src, disp).slice()),
        .b, .w => @panic("gc_marshal.routeArg: only .d/.q arg widths are used by GC ops"),
    }
}
