//! GC Collector vtable — pluggable interface per ADR-0115 §3.
//!
//! Shape mirrors `std.mem.Allocator`: a vtable pointer + opaque
//! `ctx` + free interface methods. Two implementations ship per
//! ADR-0115 §10 / §11:
//!
//!   - `collector_null.zig` (this cycle): bump-pointer alloc-only
//!     over `Heap.allocate`. `collectFn` / `walkRootsFn` are
//!     no-ops. Used to exercise the alloc + ref-touch paths
//!     without collection complexity.
//!   - `collector_mark_sweep.zig` (subsequent bundle): STW mark-
//!     sweep over the slab; barrier-zero (no write barriers).
//!     Production-ship per ADR-0115 §10 (β must-ship).
//!
//! `-Dgc-collector={null,mark_sweep}` build-option selects;
//! `-Dgc=false` strips the entire `feature/gc/` directory via
//! compile-time DCE (WAMR-equivalent nuclear strip).
//!
//! ADR-0115 §3 specifies `allocObjectFn(ctx, *TypeInfo)`; cycle
//! 4 (this commit) ships a placeholder size-based shape because
//! `TypeInfo` lands at cycle 5+ alongside `type_hierarchy.zig`
//! per ROADMAP §10 row 10.G enumeration. The vtable signature
//! is allowed to evolve when TypeInfo arrives; this stub is the
//! anchor for the test-only `collector_null` impl.
//!
//! Zone 1 (`src/feature/gc/`).

const heap_mod = @import("heap.zig");

pub const GcRef = heap_mod.GcRef;

/// Root callback — invoked by `walkRootsFn` per discovered root.
/// Mode A default per ADR-0115 §4 (zwasm owns the GC; host marks
/// roots via `zwasm_runtime_with_root_scope`); Mode B opt-in via
/// host-provided `RootProvider` vtable lands alongside cycle 6.
pub const RootCallback = *const fn (ctx: *anyopaque, root: GcRef) void;

/// Vtable interface per ADR-0115 §3. `ctx` carries the impl's
/// own state (e.g., `*Heap` for `collector_null`); each fn
/// receives it back so implementations can downcast.
pub const Collector = struct {
    /// Allocate `size` bytes from the heap. Returns the GcRef
    /// offset on success, `null` on out-of-heap. Cycle 5+ swaps
    /// `size: u32` for `ti: *TypeInfo` once RTT lands; the
    /// allocator path stays size-only at the lower layer.
    allocObjectFn: *const fn (ctx: *anyopaque, size: u32) ?GcRef,
    /// Run a collection cycle. `collector_null` is a no-op;
    /// `collector_mark_sweep` does STW mark+sweep.
    collectFn: *const fn (ctx: *anyopaque) void,
    /// Walk all live roots (operand stack, frame locals, globals)
    /// invoking `callback` per discovered root. `collector_null`
    /// is a no-op; production collectors walk per ADR-0116.
    walkRootsFn: *const fn (ctx: *anyopaque, root_callback: RootCallback, root_ctx: *anyopaque) void,
    ctx: *anyopaque,

    /// Convenience: invoke `allocObjectFn` via the vtable.
    pub fn allocObject(self: Collector, size: u32) ?GcRef {
        return self.allocObjectFn(self.ctx, size);
    }

    /// Convenience: invoke `collectFn` via the vtable.
    pub fn collect(self: Collector) void {
        self.collectFn(self.ctx);
    }

    /// Convenience: invoke `walkRootsFn` via the vtable.
    pub fn walkRoots(self: Collector, root_callback: RootCallback, root_ctx: *anyopaque) void {
        self.walkRootsFn(self.ctx, root_callback, root_ctx);
    }
};
