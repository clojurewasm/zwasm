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
    _pad1: u32 = 0,
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
};

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
    // TableSlice layout: 16 bytes (refs ptr + u32 len + u32 max). JIT
    // relies on this for `LDR Xn, [tbl_base, #(idx*16)+0]` (refs),
    // `LDR Wn, [tbl_base, #(idx*16)+8]` (len), and m-2b's
    // `LDR Wn, [tbl_base, #(idx*16)+12]` (max).
    if (@sizeOf(TableSlice) != 16) @compileError("TableSlice size != 16; JIT table.get stride assumption broken");
    // §9.9 / 9.9-m-2c-init: elem_segments_ptr is X-form; count is W-form.
    if ((elem_segments_ptr_off & 7) != 0) @compileError("elem_segments_ptr_off not 8-aligned");
    if ((elem_segments_count_off & 3) != 0) @compileError("elem_segments_count_off not 4-aligned");
    if (elem_segments_ptr_off > 32760) @compileError("elem_segments_ptr_off exceeds X-form imm12 budget");
    if (elem_segments_count_off > 16380) @compileError("elem_segments_count_off exceeds W-form imm12 budget");
    if (@sizeOf(ElemSlice) != 16) @compileError("ElemSlice size != 16; JIT table.init stride assumption broken");
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

test "JitRuntime: total size = 184 bytes (post-§9.9 / 9.9-m-2c-init elem_segments tail)" {
    try testing.expectEqual(@as(u32, 184), head_size);
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

test "TableSlice: layout is 16 bytes with refs/len/max at expected offsets" {
    try testing.expectEqual(@as(u32, 16), table_slice_size);
    try testing.expectEqual(@as(usize, 0), @offsetOf(TableSlice, "refs"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(TableSlice, "len"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(TableSlice, "max"));
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
