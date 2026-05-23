//! JIT Runtime ABI (ADR-0017).
//!
//! `JitRuntime` is the extern struct passed to every JIT-compiled
//! Wasm function via X0 (ARM64) / RDI (x86_64 System V). The
//! function's prologue LDRs the five invariants from `*X0` once
//! per call, then the body uses them via the
//! `reserved_invariant_gprs` (ADR-0018):
//!
//!   X28 ← vm_base       (linear-memory base ptr)
//!   X27 ← mem_limit     (linear-memory size in bytes)
//!   X26 ← funcptr_base  (table 0 funcptr array)
//!   X25 ← table_size    (table 0 entry count, W-width)
//!   X24 ← typeidx_base  (parallel u32 typeidx side-array)
//!
//! `extern struct` keeps the layout deterministic across Zig
//! versions and across the ABI boundary the prologue depends on.
//!
//! Zone 1 (`src/runtime/`) — Zone 2 (jit/, jit_arm64/, jit_x86/)
//! consumers import this module to thread the offset constants
//! into prologue emission. Caller-side construction (host code
//! building a JitRuntime before invoking the entry frame) lives
//! in Zone 3 (cli/, c_api/).

const std = @import("std");
const Value = @import("../../../runtime/value.zig").Value;
const FuncEntity = @import("../../../runtime/instance/func.zig").FuncEntity;

/// `@sizeOf(FuncEntity)` — exposed for JIT emit's `ref.func`
/// recipe (`ADD ptr, ptr, #(idx * func_entity_size)`). Comptime
/// derived from the actual FuncEntity struct so layout changes
/// (e.g. adding fields for richer host-call dispatch) are
/// picked up automatically.
pub const func_entity_size: u32 = @sizeOf(FuncEntity);

/// §9.9 / 9.9-m-3b (per ADR-0056): per-data-segment slice
/// descriptor exposed to JIT `memory.init`. Layout is a fixed
/// 16-byte (ptr, len) pair so the JIT body indexes the
/// `data_segments_ptr` array with a stride of `segment_slice_size`.
/// `len = 0` when the host has dropped the segment OR when the
/// module declared no bytes for it — the JIT's seg_len read uses
/// `data_dropped_ptr[idx]` to override `len` to 0, mirroring the
/// interp's `if (dropped) seg_len = 0` arm.
pub const SegmentSlice = extern struct {
    ptr: [*]const u8,
    len: u64,
};

pub const segment_slice_size: u32 = @sizeOf(SegmentSlice);

/// §9.9 / 9.9-m-2a (per ADR-0058): per-table slice descriptor
/// exposed to JIT `table.get` / `table.set` / `table.size` (m-2a),
/// `table.grow` / `table.fill` (m-2b), `table.copy` / `table.init`
/// (m-2c). Layout is a fixed 16-byte stride so the JIT body indexes
/// the `tables_ptr` array with `tableidx * table_slice_size`.
///
/// `refs` points to the table's storage as `[*]u64` raw Value bits
/// (each entry is a `Value.ref`-encoded u64; for funcref tables
/// that means `@intFromPtr(&rt.func_entities[funcidx])` or
/// `Value.null_ref` sentinel; for externref tables, host-supplied
/// u64 handles). The interpretation is identical to interp's
/// `TableInstance.refs: []Value`; the JIT loads/stores raw u64
/// without re-tagging.
///
/// `max` is `std.math.maxInt(u32)` when the module's table type
/// has no explicit max (matches interp's `?u32` `null` semantics);
/// otherwise it's the declared upper bound used by `table.grow`'s
/// max-cap check.
pub const TableSlice = extern struct {
    refs: [*]u64,
    len: u32,
    max: u32,
    /// TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    /// Parallel funcptr-view for the same table slot. `refs[i]` carries
    /// the FuncEntity-ptr encoding (per reftype semantics); `funcptrs[i]`
    /// carries the raw native code entry point that `call_indirect`'s
    /// X26 fast path reads (via `funcptr_base` for table 0 / via the
    /// per-table fast path bind for k > 0). The two views encode the
    /// same logical entry in two shapes; ADR-0068's `mirrorWrite`
    /// helper keeps them in sync after every table-mutating op
    /// (`table.set` / `table.copy` / `table.init` / `table.grow` /
    /// `table.fill`). Stride changed from 16 → 24 bytes; all JIT
    /// `tables_ptr` indexers (op_table.zig / op_call.zig per-arch)
    /// dereference via `table_slice_size` rather than a literal.
    ///
    /// `allowzero` carve-out: externref tables have no funcptr view,
    /// so setup writes the zero sentinel here. JIT mirror code's
    /// leading `CBZ funcptrs_base, .skip` guards against deref.
    funcptrs: [*]allowzero u64,
};

pub const table_slice_size: u32 = @sizeOf(TableSlice);

/// Sentinel for `TableSlice.max` indicating "no explicit max" (per
/// Wasm spec §3.2.1: tables without an explicit max field accept
/// growth up to u32 range). Mirrors interp's `?u32` `null` arm.
pub const table_no_max: u32 = std.math.maxInt(u32);

/// §9.9 / 9.9-m-2c-init (per ADR-0058 amendment): per-element-segment
/// slice descriptor exposed to JIT `table.init`. Each entry stores
/// a pre-computed `[*]const u64` of `Value.ref`-encoded values (for
/// funcref segments: `@intFromPtr(&func_entities[fidx])`; for
/// externref: opaque host u64; for null entries: `Value.null_ref`).
/// 16-byte stride matches `SegmentSlice` (m-3b) and `TableSlice`
/// (m-2a) for ABI consistency. `len = 0` when the segment has been
/// dropped via `elem.drop` (override applied via `elem_dropped_ptr`).
pub const ElemSlice = extern struct {
    refs: [*]const u64,
    len: u32,
    _pad: u32 = 0,
};

pub const elem_slice_size: u32 = @sizeOf(ElemSlice);

/// §9.9 / 9.9-l-1b-d093-d42 (D-112): per-table call_indirect
/// dispatch descriptor. Each entry carries the funcptr and
/// typeidx base pointers for one declared table, indexed by
/// `call_indirect`'s table_idx (Wasm 2.0 multi-table; spec
/// §3.4.6 + §4.4.10.1). The scalar `JitRuntime.funcptr_base`
/// / `typeidx_base` fields remain backed by table 0's arrays
/// for the legacy single-table fast path (X24/X26 / R15-relative
/// preloads); `tables_jit_ci_ptr[k]` provides the parallel view
/// for `k > 0`. `funcptr_base` matches the scalar field's
/// encoding (native code pointer; null for ref.null funcref or
/// imported funcs not exposed via host_dispatch); `typeidx_base`
/// matches D-111 canonicalization.
pub const TableJitCallInfo = extern struct {
    funcptr_base: [*]const u64,
    typeidx_base: [*]const u32,
};

pub const table_jit_ci_size: u32 = @sizeOf(TableJitCallInfo);

/// Pointer-and-counter bundle the JIT body relies on. Layout
/// extends only at the tail (Phase 8+: trap_buf, host-call
/// dispatch table, gc_root_set ptr) so existing prologue
/// offsets stay valid.
pub const JitRuntime = extern struct {
    /// Linear-memory base pointer. JIT body's bounds-checked
    /// memory ops compute effective addresses as `vm_base + idx`.
    vm_base: [*]u8,
    /// Linear-memory size in bytes. JIT body's bounds check
    /// rejects `idx >= mem_limit` with a trap.
    mem_limit: u64,
    /// Table 0 funcptr array (each entry a u64 native funcptr).
    /// Indexed by `call_indirect`'s computed table index.
    funcptr_base: [*]const u64,
    /// Table 0 entry count. JIT body's call_indirect bounds
    /// check rejects `idx >= table_size` with a trap.
    table_size: u32,
    /// Padding to keep `typeidx_base` 8-byte-aligned.
    _pad0: u32 = 0,
    /// Parallel array of u32 typeidx values for table 0;
    /// indexed identically to `funcptr_base`. JIT body's
    /// call_indirect sig check compares `typeidx_base[idx]`
    /// against the call site's expected typeidx, traps on
    /// mismatch.
    typeidx_base: [*]const u32,
    /// Trap flag — JIT body's trap stub stores `1` here
    /// before returning, allowing the entry frame to
    /// distinguish "function trapped (and unwound to its
    /// epilogue with a sentinel return)" from "function
    /// returned a value that happens to equal the sentinel".
    /// Caller (host) zeroes this before each call; reads it
    /// after to detect trap.
    ///
    /// Sub-7.5b-ii scope: single boolean. Diagnostic M3 (D-022)
    /// will widen this to a per-trap-kind code (mem OOB, sig
    /// mismatch, idx OOB, NaN, integer overflow, etc.) +
    /// optional trap-site PC for source-location surfacing.
    trap_flag: u32,
    /// §9.9-III D-144 γ.4 cycle 4 — trap kind marker. Repurposed
    /// from `_pad1`. Per-fixup-class trap stubs (arm64 emit.zig)
    /// pre-set W18 with a distinct ID; the trap stub STR's W18
    /// here so `printCallTrap` can disambiguate bounds vs sig vs
    /// other JIT traps. Sentinel `0` = unmarked (legacy trap stub
    /// path; treat as generic). Codes:
    ///   1  = generic (memory bounds, NaN, range, unreachable, …)
    ///   2  = call_indirect bounds (B.HS)
    ///   3  = call_indirect sig (B.NE)
    /// Layout-stable: replaces the existing 4-byte pad after
    /// `trap_flag`. All offsets in this struct unchanged.
    trap_kind: u32 = 0,
    /// Globals array base pointer (ADR-0027). Each entry is one
    /// `runtime.value.Value` = 8 bytes. JIT body's `global.get`
    /// emits `LDR Rd, [X23, Ridx, LSL #3]` (ARM64) or
    /// `MOV R_dst, [R_scratch + idx*8]` (x86_64) where the
    /// `[*]const Value` `globals_base` is reloaded from
    /// `[R15 + globals_base_off]` (x86_64) or pre-loaded into
    /// X23 at function prologue (ARM64) per ADR-0026's invariant
    /// strategy.
    globals_base: [*]Value,
    /// Globals array length. Reserved for future bounds-checked
    /// global access (gc proposal Phase 11+ runtime-typed
    /// globals); not consulted in Wasm 1.0 spec where global
    /// indices are statically validated.
    globals_count: u32,
    _pad2: u32 = 0,
    /// Host-import dispatch table base (chunk 7.9-d). Indexed by
    /// import-function-idx (0..host_dispatch_count). Each entry
    /// is a C-ABI function pointer with signature
    /// `fn (rt: *JitRuntime, ...wasm_args) callconv(.c) <ret>`
    /// — i.e. arg 0 is the JitRuntime ptr (matching the JIT-body
    /// internal calling convention) and args 1..N are the Wasm
    /// imports' params marshalled per platform C ABI. The JIT
    /// emits `LDR X16, [X19 + host_dispatch_base_off]; LDR X16,
    /// [X16, #(idx*8)]; BLR X16` (arm64) / `MOV RAX, [R15 +
    /// host_dispatch_base_off]; MOV RAX, [RAX + idx*8]; CALL RAX`
    /// (x86_64) for `call N` when `N < num_imports`. Until
    /// chunk d-2 lands real WASI handlers, every entry points to
    /// `defaultTrap` (sets trap_flag = 1 + returns 0), preserving
    /// the prior trap-on-import-call observable behaviour.
    host_dispatch_base: [*]const usize,
    /// Number of populated dispatch slots (= module's import-func
    /// count). Reserved for diagnostic checks; the JIT body does
    /// not bounds-check the dispatch idx because validator
    /// rejects out-of-range function indices.
    host_dispatch_count: u32,
    _pad3: u32 = 0,
    /// §9.8a / 8a.2 (ADR-0034) — JIT-execution sentinel. Every
    /// JIT-emitted prologue stores `1` here unconditionally
    /// after the runtime-ptr handoff completes. Caller pre-clears
    /// to `0` before each guest invocation; post-call read of `0`
    /// proves the JIT body never executed despite compile success;
    /// non-zero proves at least one JIT-emitted prologue ran.
    /// Always-on (no build-flag gate); cost is 8 bytes ARM64 / 7
    /// bytes x86_64 per function prologue.
    jit_executed_flag: u32 = 0,
    _pad4: u32 = 0,
    /// §9.9 / 9.9-m-1b (per ADR-0056, amending ADR-0017): base
    /// pointer to `Runtime.func_entities: []FuncEntity`. Each
    /// entry is a `FuncEntity` struct (size = `@sizeOf(FuncEntity)`,
    /// kept in sync at construction time). JIT `ref.func idx`
    /// emits `LDR Xresult, [X<rt>, #func_entities_ptr_off]` +
    /// `ADD Xresult, Xresult, #(idx * @sizeOf(FuncEntity))` so the
    /// result is `@intFromPtr(&rt.func_entities[idx])`, matching
    /// `Value.fromFuncRef`'s encoding (interp parity). Optional —
    /// caller may pass `&.{}` cast for modules without ref.func.
    func_entities_ptr: [*]const u8 = undefined,
    /// Number of populated entries in `func_entities_ptr`'s array.
    /// JIT `ref.func` does NOT bounds-check (validator rejects
    /// out-of-range funcidx at validate time); this field is for
    /// host-side diagnostic + future debugger hooks.
    func_entities_count: u32 = 0,
    _pad5: u32 = 0,
    /// §9.9 / 9.9-m-3a (per ADR-0056): parallel "data segment
    /// dropped" flag table. JIT `data.drop dataidx` emits
    /// `MOV [r15+data_dropped_ptr_off] + idx, 1` (1 byte per
    /// flag; bool = u8 in Zig extern layout). JIT `memory.init`
    /// (m-3b) reads the same flags before computing seg_len.
    data_dropped_ptr: [*]u8 = undefined,
    data_dropped_count: u32 = 0,
    _pad6: u32 = 0,
    /// §9.9 / 9.9-m-3a (per ADR-0056): parallel "element segment
    /// dropped" flag table. JIT `elem.drop elemidx` emits a byte
    /// store to `[r15+elem_dropped_ptr_off] + idx`. table.init
    /// (m-2) reads.
    elem_dropped_ptr: [*]u8 = undefined,
    elem_dropped_count: u32 = 0,
    _pad7: u32 = 0,
    /// §9.9 / 9.9-m-3b (per ADR-0056): per-data-segment slice
    /// descriptor array. Each entry is a `SegmentSlice` (16 bytes:
    /// `ptr` + `len`). JIT `memory.init dataidx` indexes this with
    /// stride `segment_slice_size` to read the segment's source
    /// bytes, then memcpy n bytes into linear memory at dst.
    data_segments_ptr: [*]const SegmentSlice = undefined,
    data_segments_count: u32 = 0,
    _pad8: u32 = 0,
    /// §9.9 / 9.9-m-2a (per ADR-0058): per-table slice descriptor
    /// array. Each entry is a `TableSlice` (16 bytes: `refs`,
    /// `len`, `max`). JIT `table.get` / `table.set` / `table.size`
    /// (m-2a) index this with stride `table_slice_size`. m-2b's
    /// `table.grow` reads `max` for the cap check; m-2c's
    /// `table.copy` / `table.init` consume both source and
    /// destination slices.
    tables_ptr: [*]const TableSlice = undefined,
    tables_count: u32 = 0,
    _pad9: u32 = 0,
    /// §9.9 / 9.9-m-2c-init (per ADR-0058 amendment): per-element-
    /// segment slice descriptor array. JIT `table.init elemidx
    /// tableidx` indexes this with stride `elem_slice_size` to read
    /// the segment's pre-computed funcref array, then memcpy n
    /// reftype values into the target table. `elem_dropped_ptr[idx]`
    /// (m-3a) overrides seg.len to 0 for dropped segments.
    elem_segments_ptr: [*]const ElemSlice = undefined,
    elem_segments_count: u32 = 0,
    _pad10: u32 = 0,
    /// §9.9 / 9.9-l-1b-d093-d8a (per ADR-0059): opaque pointer to
    /// host-managed state needed by runtime callout fn ptrs (e.g.
    /// allocator + back-reference to the canonical backing buffer
    /// the JitRuntime aliases). Each callout's fn ptr knows how
    /// to interpret this; mismatched casts are silent UB so
    /// `host_state` and the matching callout fn slot are paired
    /// at construction time.
    host_state: ?*anyopaque = null,
    /// §9.9 / 9.9-l-1b-d093-d8a (per ADR-0059): `memory.grow mem=0`
    /// callout. Args: `(rt: *JitRuntime, delta_pages: u32)` →
    /// previous page count on success (widened from u32 to i32),
    /// `-1` on failure. The fn MUST update `rt.vm_base` +
    /// `rt.mem_limit` in place when growth succeeds so the JIT
    /// body's post-call reload (arm64 reloads X28/X27 from these
    /// offsets) sees the new values. Calling convention is C-ABI
    /// (SysV on Linux/macOS x86_64, Win64 on Windows, AAPCS64 on
    /// arm64); callee-saved registers MUST be preserved.
    ///
    /// Defaults to `defaultMemoryGrowReject` (always returns -1,
    /// matches the pre-ADR-0059 skeleton's spec-conformant "host
    /// refuses growth" semantics) so JIT-emitted BLR/CALL through
    /// this slot is SEGV-safe out of the box. Runners that need
    /// actual growth override with their own impl.
    memory_grow_fn: *const fn (rt: *JitRuntime, delta_pages: u32) callconv(.c) i32 = defaultMemoryGrowReject,
    /// §9.9 / 9.9-l-1b-d093-d42 (D-112): per-table call_indirect
    /// dispatch info array. Indexed by `call_indirect`'s table_idx
    /// (carried in `ZirInstr.extra` per lower.zig:927). Entry 0
    /// duplicates the legacy table-0 fast path (`funcptr_base` /
    /// `typeidx_base` scalars above) — both views point at the
    /// same memory at construction time. Entries `k > 0` back the
    /// per-call slow path the JIT emits when `ins.extra != 0`.
    /// `undefined` is safe when no module declares > 1 table (the
    /// emit only LDRs through this when `ins.extra > 0`).
    tables_jit_ci_ptr: [*]const TableJitCallInfo = undefined,
    tables_jit_ci_count: u32 = 0,
    _pad11: u32 = 0,
    /// §9.9 / 9.9-l-1b-d093-d48 (D-122 / D-125): `table.grow tableidx`
    /// callout. Args: `(rt: *JitRuntime, tableidx: u32, init: u64,
    /// delta: u32)` → previous entry count on success (widened to
    /// i32), `-1` on failure. The fn MUST update the per-table
    /// `tables_ptr[tableidx].len` (and `refs` if reallocated) in
    /// place when growth succeeds. Calling convention is C-ABI
    /// (SysV/AAPCS64); callee-saved registers MUST be preserved.
    ///
    /// Defaults to `defaultTableGrowReject` (always returns -1)
    /// so JIT-emitted BLR/CALL through this slot is SEGV-safe out
    /// of the box. Spec runners override with `growableTableGrowFn`.
    table_grow_fn: *const fn (rt: *JitRuntime, tableidx: u32, init: u64, delta: u32) callconv(.c) i32 = defaultTableGrowReject,
    /// ADR-0105 D1 — JIT-prologue stack-probe threshold. Set at
    /// entry-helper construction time via
    /// `platform.stack_limit.computeStackLimit(STACK_GUARD_HEADROOM)`;
    /// the JIT prologue (cycle 2) emits `cmp sp, [vmctx +
    /// stack_limit_off] + b.ls trap-stub` so SP descending below
    /// this threshold traps cleanly via the existing trap-stub
    /// path BEFORE the OS guard page faults. Sentinel `0` =
    /// "probe disabled" (the comparison always passes, since SP
    /// > 0). Cross-platform per ADR-0105 D1 (macOS pthread_*np,
    /// Linux pthread_getattr_np, Win64 GetCurrentThreadStackLimits).
    stack_limit: usize = 0,
    /// D-165 cycle 4 (2026-05-23) — JIT trap-stub entry counter.
    /// Incremented unconditionally as the first instruction in the
    /// x86_64 stack-overflow trap stub (op_control.zig:1334+).
    /// arm64 path unchanged for this cycle (Mac runaway PASSes;
    /// arm64 diagnostic added when needed). Allows host-side
    /// observation of "did the probe fire and the trap stub run"
    /// for the Win64 fac-rec hang investigation — distinguishing
    /// "probe never fired" (count=0) from "probe fired but unwind
    /// stalled" (count>0 with trap_flag possibly 1).
    trap_stub_entry_count: u32 = 0,
    _pad12: u32 = 0,
};

/// Default `memory_grow_fn` — unconditionally refuses growth by
/// returning the spec sentinel `-1`. Spec-conformant for any host
/// that opts to disallow runtime linear-memory growth (per Wasm
/// 1.0 §4.4.7.6). Matches the pre-ADR-0059 skeleton's behaviour
/// so existing test corpora that exercise `memory.grow` without
/// a growable runner observe identical outcomes.
pub fn defaultMemoryGrowReject(rt: *JitRuntime, delta_pages: u32) callconv(.c) i32 {
    _ = rt;
    _ = delta_pages;
    return -1;
}

/// Default `table_grow_fn` — unconditionally refuses growth by
/// returning the spec sentinel `-1`. Spec-conformant for any host
/// that opts to disallow runtime table growth (per Wasm 2.0
/// §4.4.10.1).
pub fn defaultTableGrowReject(rt: *JitRuntime, tableidx: u32, init: u64, delta: u32) callconv(.c) i32 {
    _ = rt;
    _ = tableidx;
    _ = init;
    _ = delta;
    return -1;
}

// ============================================================
// Comptime offset constants — consumed by prologue emit (per-arch
// `compile()` writes `LDR Xn, [X0, #vm_base_off]` etc.).
//
// Each offset must fit in the LDR/STR imm12 budget:
//   X-form (8-byte): scaled by 8, max byte_off = 8*4095 = 32760
//   W-form (4-byte): scaled by 4, max byte_off = 4*4095 = 16380
// JitRuntime fits trivially within imm12 today (40 bytes total);
// future tail-extensions remain within 32760 by construction
// because the prologue only loads the head fields.
// ============================================================

pub const vm_base_off: u12 = @offsetOf(JitRuntime, "vm_base");
pub const mem_limit_off: u12 = @offsetOf(JitRuntime, "mem_limit");
pub const funcptr_base_off: u12 = @offsetOf(JitRuntime, "funcptr_base");
pub const table_size_off: u12 = @offsetOf(JitRuntime, "table_size");
pub const typeidx_base_off: u12 = @offsetOf(JitRuntime, "typeidx_base");
pub const trap_flag_off: u12 = @offsetOf(JitRuntime, "trap_flag");
pub const trap_kind_off: u12 = @offsetOf(JitRuntime, "trap_kind");
pub const globals_base_off: u12 = @offsetOf(JitRuntime, "globals_base");
pub const globals_count_off: u12 = @offsetOf(JitRuntime, "globals_count");
pub const host_dispatch_base_off: u12 = @offsetOf(JitRuntime, "host_dispatch_base");
pub const host_dispatch_count_off: u12 = @offsetOf(JitRuntime, "host_dispatch_count");
pub const jit_executed_flag_off: u12 = @offsetOf(JitRuntime, "jit_executed_flag");
pub const func_entities_ptr_off: u12 = @offsetOf(JitRuntime, "func_entities_ptr");
pub const func_entities_count_off: u12 = @offsetOf(JitRuntime, "func_entities_count");
pub const data_dropped_ptr_off: u12 = @offsetOf(JitRuntime, "data_dropped_ptr");
pub const data_dropped_count_off: u12 = @offsetOf(JitRuntime, "data_dropped_count");
pub const elem_dropped_ptr_off: u12 = @offsetOf(JitRuntime, "elem_dropped_ptr");
pub const elem_dropped_count_off: u12 = @offsetOf(JitRuntime, "elem_dropped_count");
pub const data_segments_ptr_off: u12 = @offsetOf(JitRuntime, "data_segments_ptr");
pub const data_segments_count_off: u12 = @offsetOf(JitRuntime, "data_segments_count");
pub const tables_ptr_off: u12 = @offsetOf(JitRuntime, "tables_ptr");
pub const tables_count_off: u12 = @offsetOf(JitRuntime, "tables_count");
pub const elem_segments_ptr_off: u12 = @offsetOf(JitRuntime, "elem_segments_ptr");
pub const elem_segments_count_off: u12 = @offsetOf(JitRuntime, "elem_segments_count");
pub const host_state_off: u12 = @offsetOf(JitRuntime, "host_state");
pub const memory_grow_fn_off: u12 = @offsetOf(JitRuntime, "memory_grow_fn");
pub const tables_jit_ci_ptr_off: u12 = @offsetOf(JitRuntime, "tables_jit_ci_ptr");
pub const tables_jit_ci_count_off: u12 = @offsetOf(JitRuntime, "tables_jit_ci_count");
pub const table_grow_fn_off: u12 = @offsetOf(JitRuntime, "table_grow_fn");
/// ADR-0105 D1 / D2 — stack-probe threshold field offset. X-form
/// (8-byte usize); prologue emits `LDR Xn, [vmctx, #stack_limit_off]`.
pub const stack_limit_off: u12 = @offsetOf(JitRuntime, "stack_limit");
/// D-165 cycle 4 — trap-stub entry counter; W-form (4-byte u32).
/// x86_64 trap stub emits `INC DWORD PTR [R15 + this]` as its
/// first instruction; arm64 unchanged.
pub const trap_stub_entry_count_off: u12 = @offsetOf(JitRuntime, "trap_stub_entry_count");

/// Total size of the head section consumed by the prologue.
pub const head_size: u32 = @sizeOf(JitRuntime);

// Comptime guards — catching layout drift at build time, the
// W54-class regression-prevention discipline applied to ABI.
comptime {
    // Each X-form load offset must be 8-aligned (imm12 scales
    // by 8). Pointer + u64 fields are naturally 8-aligned by
    // the extern struct layout, but assert explicitly so a
    // future tail-extension that breaks alignment trips here.
    if ((vm_base_off & 7) != 0) @compileError("vm_base_off not 8-aligned");
    if ((mem_limit_off & 7) != 0) @compileError("mem_limit_off not 8-aligned");
    if ((funcptr_base_off & 7) != 0) @compileError("funcptr_base_off not 8-aligned");
    if ((typeidx_base_off & 7) != 0) @compileError("typeidx_base_off not 8-aligned");
    // table_size is W-form (4 bytes); imm12 scales by 4. Must
    // be 4-aligned.
    if ((table_size_off & 3) != 0) @compileError("table_size_off not 4-aligned");
    if ((trap_flag_off & 3) != 0) @compileError("trap_flag_off not 4-aligned");
    // imm12 budget. With current 6 fields all near offset 0, this
    // is comfortable; future tail-extensions could exceed it.
    if (vm_base_off > 32760) @compileError("vm_base_off exceeds X-form imm12 budget");
    if (mem_limit_off > 32760) @compileError("mem_limit_off exceeds X-form imm12 budget");
    if (funcptr_base_off > 32760) @compileError("funcptr_base_off exceeds X-form imm12 budget");
    if (typeidx_base_off > 32760) @compileError("typeidx_base_off exceeds X-form imm12 budget");
    if (table_size_off > 16380) @compileError("table_size_off exceeds W-form imm12 budget");
    if (trap_flag_off > 16380) @compileError("trap_flag_off exceeds W-form imm12 budget");
    // ADR-0027: globals_base + globals_count alignment + budget.
    if ((globals_base_off & 7) != 0) @compileError("globals_base_off not 8-aligned");
    if ((globals_count_off & 3) != 0) @compileError("globals_count_off not 4-aligned");
    if (globals_base_off > 32760) @compileError("globals_base_off exceeds X-form imm12 budget");
    if (globals_count_off > 16380) @compileError("globals_count_off exceeds W-form imm12 budget");
    // Chunk 7.9-d: host_dispatch_base + host_dispatch_count.
    if ((host_dispatch_base_off & 7) != 0) @compileError("host_dispatch_base_off not 8-aligned");
    if ((host_dispatch_count_off & 3) != 0) @compileError("host_dispatch_count_off not 4-aligned");
    if (host_dispatch_base_off > 32760) @compileError("host_dispatch_base_off exceeds X-form imm12 budget");
    if (host_dispatch_count_off > 16380) @compileError("host_dispatch_count_off exceeds W-form imm12 budget");
    // ADR-0034: jit_executed_flag is W-form (4 bytes); imm12 scales by 4.
    if ((jit_executed_flag_off & 3) != 0) @compileError("jit_executed_flag_off not 4-aligned");
    if (jit_executed_flag_off > 16380) @compileError("jit_executed_flag_off exceeds W-form imm12 budget");
    // §9.9 / 9.9-m-1b: func_entities_ptr is X-form (8-byte pointer); count is W-form.
    if ((func_entities_ptr_off & 7) != 0) @compileError("func_entities_ptr_off not 8-aligned");
    if ((func_entities_count_off & 3) != 0) @compileError("func_entities_count_off not 4-aligned");
    if (func_entities_ptr_off > 32760) @compileError("func_entities_ptr_off exceeds X-form imm12 budget");
    if (func_entities_count_off > 16380) @compileError("func_entities_count_off exceeds W-form imm12 budget");
    // §9.9 / 9.9-m-3a: data_dropped / elem_dropped pointer + count.
    if ((data_dropped_ptr_off & 7) != 0) @compileError("data_dropped_ptr_off not 8-aligned");
    if ((data_dropped_count_off & 3) != 0) @compileError("data_dropped_count_off not 4-aligned");
    if (data_dropped_ptr_off > 32760) @compileError("data_dropped_ptr_off exceeds X-form imm12 budget");
    if (data_dropped_count_off > 16380) @compileError("data_dropped_count_off exceeds W-form imm12 budget");
    if ((elem_dropped_ptr_off & 7) != 0) @compileError("elem_dropped_ptr_off not 8-aligned");
    if ((elem_dropped_count_off & 3) != 0) @compileError("elem_dropped_count_off not 4-aligned");
    if (elem_dropped_ptr_off > 32760) @compileError("elem_dropped_ptr_off exceeds X-form imm12 budget");
    if (elem_dropped_count_off > 16380) @compileError("elem_dropped_count_off exceeds W-form imm12 budget");
    // §9.9 / 9.9-m-3b: data_segments_ptr is X-form (8-byte pointer); count is W-form.
    if ((data_segments_ptr_off & 7) != 0) @compileError("data_segments_ptr_off not 8-aligned");
    if ((data_segments_count_off & 3) != 0) @compileError("data_segments_count_off not 4-aligned");
    if (data_segments_ptr_off > 32760) @compileError("data_segments_ptr_off exceeds X-form imm12 budget");
    if (data_segments_count_off > 16380) @compileError("data_segments_count_off exceeds W-form imm12 budget");
    // SegmentSlice layout: 16 bytes (ptr + u64 len). JIT relies on
    // this for `LDR Xn, [seg_base, #(idx*16)+0]` (ptr) and
    // `LDR Xn, [seg_base, #(idx*16)+8]` (len).
    if (@sizeOf(SegmentSlice) != 16) @compileError("SegmentSlice size != 16; JIT memory.init stride assumption broken");
    // §9.9 / 9.9-m-2a: tables_ptr is X-form (8-byte pointer); count is W-form.
    if ((tables_ptr_off & 7) != 0) @compileError("tables_ptr_off not 8-aligned");
    if ((tables_count_off & 3) != 0) @compileError("tables_count_off not 4-aligned");
    if (tables_ptr_off > 32760) @compileError("tables_ptr_off exceeds X-form imm12 budget");
    if (tables_count_off > 16380) @compileError("tables_count_off exceeds W-form imm12 budget");
    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    // TableSlice layout: 24 bytes after ADR-0068 stride extension
    // (refs ptr + u32 len + u32 max + funcptrs ptr). JIT relies on
    // `LDR Xn, [tbl_base, #(idx*24)+0]` (refs),
    // `LDR Wn, [tbl_base, #(idx*24)+8]` (len),
    // `LDR Wn, [tbl_base, #(idx*24)+12]` (max),
    // `LDR Xn, [tbl_base, #(idx*24)+16]` (funcptrs).
    if (@sizeOf(TableSlice) != 24) @compileError("TableSlice size != 24; JIT table.get stride assumption broken");
    if (@offsetOf(TableSlice, "refs") != 0) @compileError("TableSlice.refs offset != 0");
    if (@offsetOf(TableSlice, "len") != 8) @compileError("TableSlice.len offset != 8");
    if (@offsetOf(TableSlice, "max") != 12) @compileError("TableSlice.max offset != 12");
    if (@offsetOf(TableSlice, "funcptrs") != 16) @compileError("TableSlice.funcptrs offset != 16");
    // §9.9 / 9.9-m-2c-init: elem_segments_ptr is X-form; count is W-form.
    if ((elem_segments_ptr_off & 7) != 0) @compileError("elem_segments_ptr_off not 8-aligned");
    if ((elem_segments_count_off & 3) != 0) @compileError("elem_segments_count_off not 4-aligned");
    if (elem_segments_ptr_off > 32760) @compileError("elem_segments_ptr_off exceeds X-form imm12 budget");
    if (elem_segments_count_off > 16380) @compileError("elem_segments_count_off exceeds W-form imm12 budget");
    if (@sizeOf(ElemSlice) != 16) @compileError("ElemSlice size != 16; JIT table.init stride assumption broken");
    // §9.9 / 9.9-l-1b-d093-d8a (ADR-0059): host_state + memory_grow_fn
    // are both X-form (8-byte pointer) — natural 8-alignment from
    // extern struct layout; assert explicitly for future tail growth.
    if ((host_state_off & 7) != 0) @compileError("host_state_off not 8-aligned");
    if ((memory_grow_fn_off & 7) != 0) @compileError("memory_grow_fn_off not 8-aligned");
    if (host_state_off > 32760) @compileError("host_state_off exceeds X-form imm12 budget");
    if (memory_grow_fn_off > 32760) @compileError("memory_grow_fn_off exceeds X-form imm12 budget");
    // §9.9 / 9.9-l-1b-d093-d42 (D-112): tables_jit_ci_ptr is X-form (8-byte pointer); count is W-form.
    if ((tables_jit_ci_ptr_off & 7) != 0) @compileError("tables_jit_ci_ptr_off not 8-aligned");
    if ((tables_jit_ci_count_off & 3) != 0) @compileError("tables_jit_ci_count_off not 4-aligned");
    if (tables_jit_ci_ptr_off > 32760) @compileError("tables_jit_ci_ptr_off exceeds X-form imm12 budget");
    if (tables_jit_ci_count_off > 16380) @compileError("tables_jit_ci_count_off exceeds W-form imm12 budget");
    // TableJitCallInfo layout: 16 bytes (funcptr_base + typeidx_base, both pointers).
    // JIT call_indirect indexes the per-table descriptor array at stride 16.
    if (@sizeOf(TableJitCallInfo) != 16) @compileError("TableJitCallInfo size != 16; JIT call_indirect stride assumption broken");
    if (@offsetOf(TableJitCallInfo, "funcptr_base") != 0) @compileError("TableJitCallInfo.funcptr_base offset != 0");
    if (@offsetOf(TableJitCallInfo, "typeidx_base") != 8) @compileError("TableJitCallInfo.typeidx_base offset != 8");
    // §9.9 / 9.9-l-1b-d093-d48 (D-122 / D-125): table_grow_fn is X-form pointer.
    if ((table_grow_fn_off & 7) != 0) @compileError("table_grow_fn_off not 8-aligned");
    if (table_grow_fn_off > 32760) @compileError("table_grow_fn_off exceeds X-form imm12 budget");
    // ADR-0105 D1: stack_limit is X-form (usize); imm12 scales by 8.
    if ((stack_limit_off & 7) != 0) @compileError("stack_limit_off not 8-aligned");
    if (stack_limit_off > 32760) @compileError("stack_limit_off exceeds X-form imm12 budget");
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "JitRuntime: layout offsets match documented prologue load sequence" {
    try testing.expectEqual(@as(u12, 0), vm_base_off);
    try testing.expectEqual(@as(u12, 8), mem_limit_off);
    try testing.expectEqual(@as(u12, 16), funcptr_base_off);
    try testing.expectEqual(@as(u12, 24), table_size_off);
    try testing.expectEqual(@as(u12, 32), typeidx_base_off);
    try testing.expectEqual(@as(u12, 40), trap_flag_off);
    try testing.expectEqual(@as(u12, 64), host_dispatch_base_off);
    try testing.expectEqual(@as(u12, 72), host_dispatch_count_off);
    try testing.expectEqual(@as(u12, 80), jit_executed_flag_off);
}

test "JitRuntime: total size = 240 bytes (post-D-165 cycle 4 trap_stub_entry_count tail)" {
    try testing.expectEqual(@as(u32, 240), head_size);
}

test "JitRuntime: D-165 cycle 4 trap_stub_entry_count offset (W-form imm12-safe)" {
    try testing.expectEqual(@as(u12, 232), trap_stub_entry_count_off);
    // 4-aligned (W-form); imm12 budget unchecked but 232 << 16380 trivially.
    if ((trap_stub_entry_count_off & 3) != 0) @compileError("trap_stub_entry_count_off not 4-aligned");
}

test "JitRuntime: §9.9 / 9.9-l-1b-d093-d8a callout offsets (host_state + memory_grow_fn)" {
    try testing.expectEqual(@as(u12, 184), host_state_off);
    try testing.expectEqual(@as(u12, 192), memory_grow_fn_off);
}

test "JitRuntime: §9.9 / 9.9-l-1b-d093-d42 tables_jit_ci offsets" {
    try testing.expectEqual(@as(u12, 200), tables_jit_ci_ptr_off);
    try testing.expectEqual(@as(u12, 208), tables_jit_ci_count_off);
}

test "JitRuntime: §9.9 / 9.9-l-1b-d093-d48 table_grow_fn offset" {
    try testing.expectEqual(@as(u12, 216), table_grow_fn_off);
}

test "JitRuntime: ADR-0105 D1 stack_limit offset (tail field; X-form imm12-safe)" {
    try testing.expectEqual(@as(u12, 224), stack_limit_off);
}

test "TableJitCallInfo: layout is 16 bytes with funcptr_base/typeidx_base at expected offsets" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(TableJitCallInfo));
    try testing.expectEqual(@as(usize, 0), @offsetOf(TableJitCallInfo, "funcptr_base"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(TableJitCallInfo, "typeidx_base"));
}

test "JitRuntime: §9.9 / 9.9-m-1b + 9.9-m-3a + 9.9-m-3b + 9.9-m-2a + 9.9-m-2c-init new field offsets" {
    try testing.expectEqual(@as(u12, 88), func_entities_ptr_off);
    try testing.expectEqual(@as(u12, 96), func_entities_count_off);
    try testing.expectEqual(@as(u12, 104), data_dropped_ptr_off);
    try testing.expectEqual(@as(u12, 112), data_dropped_count_off);
    try testing.expectEqual(@as(u12, 120), elem_dropped_ptr_off);
    try testing.expectEqual(@as(u12, 128), elem_dropped_count_off);
    try testing.expectEqual(@as(u12, 136), data_segments_ptr_off);
    try testing.expectEqual(@as(u12, 144), data_segments_count_off);
    try testing.expectEqual(@as(u12, 152), tables_ptr_off);
    try testing.expectEqual(@as(u12, 160), tables_count_off);
    try testing.expectEqual(@as(u12, 168), elem_segments_ptr_off);
    try testing.expectEqual(@as(u12, 176), elem_segments_count_off);
}

test "TableSlice: layout is 24 bytes with refs/len/max/funcptrs at expected offsets (ADR-0068)" {
    try testing.expectEqual(@as(u32, 24), table_slice_size);
    try testing.expectEqual(@as(usize, 0), @offsetOf(TableSlice, "refs"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(TableSlice, "len"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(TableSlice, "max"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(TableSlice, "funcptrs"));
}

test "ElemSlice: layout is 16 bytes with refs/len at expected offsets" {
    try testing.expectEqual(@as(u32, 16), elem_slice_size);
    try testing.expectEqual(@as(usize, 0), @offsetOf(ElemSlice, "refs"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(ElemSlice, "len"));
}

test "JitRuntime: round-trip construction + field reads" {
    var memory: [16]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const funcptrs = [_]u64{0xCAFE0000};
    const typeidxs = [_]u32{7};
    var globals = [_]Value{ Value.fromI32(11), Value.fromI32(22) };
    const dispatch = [_]usize{0xDEADBEEF};
    const rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = &funcptrs,
        .table_size = 1,
        .typeidx_base = &typeidxs,
        .trap_flag = 0,
        .globals_base = &globals,
        .globals_count = globals.len,
        .host_dispatch_base = &dispatch,
        .host_dispatch_count = dispatch.len,
    };
    try testing.expectEqual(@as(u64, 16), rt.mem_limit);
    try testing.expectEqual(@as(u32, 1), rt.table_size);
    try testing.expectEqual(@as(u8, 0xDE), rt.vm_base[0]);
    try testing.expectEqual(@as(u64, 0xCAFE0000), rt.funcptr_base[0]);
    try testing.expectEqual(@as(u32, 7), rt.typeidx_base[0]);
    try testing.expectEqual(@as(u32, 0), rt.trap_flag);
    try testing.expectEqual(@as(i32, 11), rt.globals_base[0].i32);
    try testing.expectEqual(@as(i32, 22), rt.globals_base[1].i32);
    try testing.expectEqual(@as(u32, 2), rt.globals_count);
    try testing.expectEqual(@as(usize, 0xDEADBEEF), rt.host_dispatch_base[0]);
    try testing.expectEqual(@as(u32, 1), rt.host_dispatch_count);
}
