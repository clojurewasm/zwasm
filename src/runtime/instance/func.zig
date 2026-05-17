//! Per-runtime function handle — instance-bearing funcref
//! representation per ADR-0014 §6.K.1.
//!
//! Per ADR-0023 §3 reference table + §7 item 6: extracted from
//! `runtime/value.zig`'s prior `FuncEntity` location. The funcref
//! Value still encodes `@intFromPtr(*const FuncEntity)`; this
//! file just gives the type its canonical home alongside the
//! other instance-side runtime types.
//!
//! Zone 1 (`src/runtime/`).

const runtime_mod = @import("../runtime.zig");

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
    runtime: *runtime_mod.Runtime,
    /// Index into `runtime.funcs`.
    func_idx: u32,
    /// TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    /// Native code entry point for this function. JIT `emitTableSet`
    /// reads this via `LDR Xfp, [Xref, #funcptr_offset]` to mirror
    /// the funcref input into the dual-view funcptr storage (per
    /// ADR-0068 §A1). For local funcs:
    /// `@intFromPtr(compiled.module.block.bytes.ptr + func_offsets[i])`.
    /// For imports: `dispatch[i]` (host-call trampoline / cross-module
    /// bridge thunk). `0` when the entity is interp-only and no JIT
    /// dispatch slot has been populated; downstream JIT paths that
    /// would dereference this MUST coordinate via the dispatch
    /// machinery that produced the funcref in the first place.
    funcptr: usize,
};

/// TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
/// Byte offset of `FuncEntity.funcptr` from the FuncEntity base.
/// JIT mirror-write emit (`shared/table_storage.zig`) reads via
/// `LDR Xfp, [Xref, #funcentity_funcptr_offset]`. Comptime-derived
/// from `@offsetOf` so layout changes propagate.
pub const funcentity_funcptr_offset: u32 = @offsetOf(FuncEntity, "funcptr");
