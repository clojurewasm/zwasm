//! WASM Spec §4.4 "Traps" — runtime trap conditions + tracing
//! support hooks.
//!
//! `Trap` is the zwasm-internal error set; the wasm-c-api binding
//! marshals these into `wasm_trap_t` via `api/trap_surface.zig`
//! per ADR-0023 §3. The trace types support optional per-instr
//! observation (Phase 6 / ADR-0013) used by §9.6 / 6.A
//! investigation flows and the WAST runner's `--trace` mode.
//!
//! Zone 1 (`src/runtime/`).

const value = @import("value.zig");
const zir = @import("../ir/zir.zig");

/// Trap conditions. The dispatch loop returns one of these on the
/// `Trap!` error union when a runtime-checked invariant fails.
/// `OutOfMemory` is included so allocator-backed paths can bubble
/// up uniformly.
pub const Trap = error{
    Unreachable,
    DivByZero,
    IntOverflow,
    InvalidConversionToInt,
    OutOfBoundsLoad,
    OutOfBoundsStore,
    OutOfBoundsTableAccess,
    UninitializedElement,
    IndirectCallTypeMismatch,
    StackOverflow,
    CallStackExhausted,
    OutOfMemory,
};

/// Per-instruction trace event (Phase 6 / §9.6 / 6.A per ADR-0013).
/// Emitted post-handler when `Runtime.trace_cb` is set; consumed by
/// the runtime-asserting WAST runner's `--trace` mode and by §9.6 /
/// 6.E interp behaviour bug investigation. Zero-cost when disabled
/// (one predicted-not-taken branch in the dispatch loop).
pub const TraceEvent = struct {
    pc: u32,
    op: zir.ZirOp,
    /// Top-of-stack value AFTER the handler ran. `null` when the
    /// stack is empty (e.g. after a `drop` that empties it).
    operand_top: ?value.Value,
    frame_depth: u32,
};

pub const TraceCallback = *const fn (ctx: *anyopaque, ev: TraceEvent) void;
