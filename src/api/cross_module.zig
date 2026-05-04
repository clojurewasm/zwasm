//! Cross-module call thunk (ADR-0014 §2.1 / 6.K.3).
//!
//! Wraps the dispatch dance for non-WASI imported functions.
//! When the importer's `mvp.callOp` resolves an `host_calls[i]`
//! slot to `crossModuleCallThunk`, this code:
//!
//!   1. pops args off the importer's operand stack,
//!   2. pushes them onto the source instance's runtime,
//!   3. runs the source's body via `mvp.invoke` against the
//!      source's runtime context (memory, globals, frame stack),
//!   4. copies results back to the importer's operand stack.
//!
//! Cycle safety: Wasm instantiation order rules out cyclic
//! cross-module calls (a module must be fully instantiated
//! before any other module that imports from it). Re-entry into
//! a still-running runtime would clobber its inline `operand_buf`
//! / `frame_buf`. We do not add runtime cycle detection.
//!
//! Carved out of `c_api/instance.zig` purely to keep that file
//! under the §A2 hard cap (2000 lines). Logically the same code
//! family.
//!
//! Zone 3 (`src/api/`) — may import any layer below.

const runtime = @import("../runtime/runtime.zig");
const interp_mvp = @import("../interp/mvp.zig");
const dispatch_table_mod = @import("../ir/dispatch_table.zig");

/// Heap-stored context for `thunk`. One per non-WASI imported
/// function. Allocated on the importing instance's per-instance
/// arena. After parking-as-zombie (per 6.K.2 sub-change 4), the
/// arena (and thus this struct) lives until store_delete, so the
/// cross-module thunk is valid even if the importer's
/// instantiation later traps.
pub const CallCtx = struct {
    source_rt: *runtime.Runtime,
    source_funcidx: u32,
    dispatch_table: *const dispatch_table_mod.DispatchTable,
};

/// Cross-module dispatch helper invoked by `mvp.callOp` when the
/// importing module's `host_calls[i]` slot points here.
pub fn thunk(rt: *runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const cmc: *const CallCtx = @ptrCast(@alignCast(ctx));
    const source_rt = cmc.source_rt;
    if (cmc.source_funcidx >= source_rt.funcs.len) return runtime.Trap.Unreachable;
    const callee = source_rt.funcs[cmc.source_funcidx];

    // Transfer args importer-stack → source-stack. Args sit at the
    // top of the importer's operand_buf in left-to-right order.
    const num_params: u32 = @intCast(callee.sig.params.len);
    if (rt.operand_len < num_params) return runtime.Trap.StackOverflow;
    const args_start = rt.operand_len - num_params;
    var i: u32 = 0;
    while (i < num_params) : (i += 1) {
        try source_rt.pushOperand(rt.operand_buf[args_start + i]);
    }
    rt.operand_len = args_start;

    try interp_mvp.invoke(source_rt, cmc.dispatch_table, callee);

    // Transfer results source-stack → importer-stack.
    const num_results: u32 = @intCast(callee.sig.results.len);
    if (source_rt.operand_len < num_results) return runtime.Trap.StackOverflow;
    const results_start = source_rt.operand_len - num_results;
    i = 0;
    while (i < num_results) : (i += 1) {
        try rt.pushOperand(source_rt.operand_buf[results_start + i]);
    }
    source_rt.operand_len = results_start;
}
