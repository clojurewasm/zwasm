//! `.cwasm` producer (per ADR-0039; v0.2 exports per ADR-0138).
//!
//! Wraps already-emitted per-function machine code +
//! relocation list + type metadata in the inline-bytes
//! container defined by `format.zig`. Arch-blind: the
//! caller (typically `compile.zig`) passes the arch tag
//! that identifies which backend produced the bytes.
//!
//! **Pipeline reuse**: the existing JIT pipeline
//! (`compile.zig`: lower → loop_info → hoist → liveness →
//! regalloc → coalesce → emit) ends with `emit.compile()`
//! returning `EmitOutput { bytes, n_slots, call_fixups }`.
//! This module accepts the same per-func data as **input
//! slices** (`bytes_per_func`, `n_slots_per_func`,
//! `sig_idx_per_func`, `relocs`) — no direct dependency on
//! `arm64/` or `x86_64/` per A12 + A3.
//!
//! 8b.3-c MVP: produce the .cwasm payload from a fully-
//! materialised `Input` struct. 8b.3-d wires `compile.zig`
//! to call this module after `emit.compile()` for the AOT
//! path.
//!
//! Zone 2 (`src/engine/codegen/aot/`).

const std = @import("std");

const format = @import("format.zig");

const Allocator = std.mem.Allocator;
const CwasmHeader = format.CwasmHeader;
const CwasmFuncMeta = format.CwasmFuncMeta;
const CwasmReloc = format.CwasmReloc;

pub const Error = format.Error || error{OutOfMemory};

/// Producer input — arch-blind aggregate of the per-function
/// data the AOT path needs. The caller pre-emits the code
/// per function (using `arm64.emit.compile` or
/// `x86_64.emit.compile`) and packs the per-func slices in
/// `func_idx` order.
pub const Input = struct {
    /// `arch_arm64` | `arch_x86_64`. Identifies the backend
    /// that produced `bytes_per_func`.
    arch: u32,
    /// Per-function machine code, indexed by `func_idx` for
    /// non-imported functions only. Imports are not coded
    /// (their indices are reserved by `n_imports`).
    bytes_per_func: []const []const u8,
    /// Mirrors `regalloc.Allocation.n_slots` per func.
    /// Length == `bytes_per_func.len`.
    n_slots_per_func: []const u16,
    /// Index into `types_serialised` per func. Length ==
    /// `bytes_per_func.len`.
    sig_idx_per_func: []const u16,
    /// Reloc list across all functions. Each reloc's
    /// `code_offset` is interpreted relative to the
    /// **per-func bytes** (not the concatenated code
    /// section); this module rebases them at write time.
    /// `func_idx_for_reloc[i]` names which func owns
    /// `relocs[i]`.
    relocs: []const CwasmReloc,
    func_idx_for_reloc: []const u32,
    /// Pre-serialised types section (caller-formatted; this
    /// module copies verbatim). Phase 12's loader parses it
    /// per the format defined in ADR-0039 §"Types section".
    types_serialised: []const u8,
    /// Number of imported functions. Reserved indices 0..n_imports
    /// don't appear in `bytes_per_func`.
    n_imports: u32,
    /// Number of distinct FuncTypes in `types_serialised`.
    n_types: u32,
    /// Func-kind exports (name → wasm func idx), v0.2 per ADR-0138.
    /// Lets a loaded `.cwasm` resolve `_start`/`main`/`--invoke <name>`
    /// without re-parsing the original `.wasm`. Empty for none.
    exports: []const format.CwasmExport = &.{},
    /// Pre-evaluated defined-global init values (v0.3, ADR-0139),
    /// one `Value.bits128` per global in defined-global order. A standalone
    /// runtime memcpys these into `globals_base` — no init-expr eval at
    /// load. Empty for modules with no defined globals.
    globals: []const u128 = &.{},
    /// Linear memory (v0.3 cycle-1b). `has_memory` gates the memory_*
    /// header fields + the memory_init data section. `mem_data` is the
    /// ACTIVE data segments with pre-evaluated destination offsets.
    has_memory: bool = false,
    mem_min_pages: u32 = 0,
    mem_max_pages: u32 = format.memory_max_none,
    mem_data: []const format.CwasmDataSeg = &.{},
    /// Table 0 + element segments (v0.3 cycle-2a). `has_table` gates
    /// `table0_size` + the elem_data section. `elem` = active segments
    /// (table offsets pre-evaluated; funcidx lists).
    has_table: bool = false,
    table0_size: u32 = 0,
    elem: []const format.CwasmElemSeg = &.{},
    /// Canonical typeidx per defined function (parallel to `bytes_per_func`),
    /// written into each `CwasmFuncMeta.canon_typeidx`. Empty → all 0.
    canon_typeidx_per_func: []const u32 = &.{},
    /// Imports metadata (v0.4, D-251 AOT-WASI): `(module, name, kind)` per
    /// declared import in wasm-space order. Lets a standalone `.cwasm`
    /// rebuild `host_dispatch_base` (WASI syscall fn-ptrs). Empty for none.
    imports: []const format.CwasmImport = &.{},
    /// v0.5 (ADR-0203 stage 2): the original module bytes, copied verbatim —
    /// the full-fidelity loader re-derives all module metadata from these
    /// and hands them to the normal setup path.
    wasm_bytes: []const u8 = &.{},
    /// v0.5: per-defined-func re-link extras (parallel to `bytes_per_func`).
    /// Empty → zero-filled entries are written.
    func_extras: []const format.CwasmFuncExtra = &.{},
    /// v0.5: the module-level exception table (module-relative pcs).
    eh_entries: []const format.CwasmEhEntry = &.{},
    /// ADR-0203 stage 4 — the code was compiled with memory0 bounds checks
    /// elided; recorded as `flag_bounds_elided` for the loader to restore.
    bounds_elided: bool = false,
};

/// Produce a `.cwasm` v0.2 byte stream. Caller owns the
/// returned slice; pair with `allocator.free`.
///
/// Layout (per ADR-0039; v0.2 exports section per ADR-0138):
///   [0..68)            CwasmHeader
///   [68..)             metadata section (n_funcs × 12 bytes)
///   then               types section (verbatim copy)
///   then               relocs section (n_relocs × 9 bytes)
///   then               exports section ([n_exports][entries…])
///   then               code section (concatenated per-func
///                      bytes; per-func 4-byte alignment)
pub fn produceCwasm(allocator: Allocator, input: Input) Error![]u8 {
    const n_funcs: u32 = @intCast(input.bytes_per_func.len);
    if (input.n_slots_per_func.len != n_funcs) return Error.TruncatedFuncMeta;
    if (input.sig_idx_per_func.len != n_funcs) return Error.TruncatedFuncMeta;
    if (input.func_idx_for_reloc.len != input.relocs.len) return Error.TruncatedReloc;

    // Compute section sizes.
    const metadata_size: u32 = n_funcs * format.func_meta_size;
    const types_size: u32 = @intCast(input.types_serialised.len);
    const relocs_size: u32 = @intCast(input.relocs.len * format.reloc_size);

    // Exports section: 4-byte count then one variable-length entry each.
    // The count is always written (size >= 4), so the loader has a fixed
    // place to read n_exports even when there are none.
    var exports_size: u32 = 4;
    for (input.exports) |e| exports_size += @intCast(format.exportEntrySize(e.name.len));

    // Globals section: 4-byte count then n_globals × 16-byte values.
    const globals_size: u32 = 4 + @as(u32, @intCast(input.globals.len)) * format.global_value_size;

    // Memory_init section: 4-byte count then per active segment
    // [mem_offset:u32][byte_len:u32][bytes]. Empty (size 0) when no memory.
    var memory_init_size: u32 = if (input.has_memory) 4 else 0;
    for (input.mem_data) |seg| memory_init_size += 8 + @as(u32, @intCast(seg.bytes.len));

    // Elem_data section: 4-byte count then per active segment
    // [table_offset:u32][n_funcs:u32][funcidx... ×u32]. Empty when no table.
    var elem_size: u32 = if (input.has_table) 4 else 0;
    for (input.elem) |seg| elem_size += 8 + @as(u32, @intCast(seg.funcidxs.len)) * 4;

    // Imports section (v0.4): 4-byte count then one variable-length entry
    // each. The count is always written so the loader has a fixed place to
    // read n_imports_total even when there are none.
    var imports_size: u32 = 4;
    for (input.imports) |imp| imports_size += @intCast(format.importEntrySize(imp.module.len, imp.name.len));

    // Code section: concatenate per-func bytes with 4-byte
    // alignment between funcs (loader mmap()s with
    // PROT_EXEC; arm64 prefers 4-byte-aligned function
    // entries).
    var code_size: u32 = 0;
    var per_func_offsets = try allocator.alloc(u32, n_funcs);
    defer allocator.free(per_func_offsets);
    for (input.bytes_per_func, 0..) |b, i| {
        per_func_offsets[i] = code_size;
        code_size += @intCast(b.len);
        code_size = std.mem.alignForward(u32, code_size, 4);
    }

    // v0.5 sections (ADR-0203 stage 2).
    const wasm_bytes_size: u32 = @intCast(input.wasm_bytes.len);
    const func_extras_size: u32 = n_funcs * format.func_extra_size;
    const eh_size: u32 = 4 + @as(u32, @intCast(input.eh_entries.len)) * format.eh_entry_size;

    // Compute section offsets.
    const metadata_offset: u32 = format.header_size;
    const types_offset: u32 = metadata_offset + metadata_size;
    const relocs_offset: u32 = types_offset + types_size;
    const exports_offset: u32 = relocs_offset + relocs_size;
    const globals_offset: u32 = exports_offset + exports_size;
    const memory_init_offset: u32 = globals_offset + globals_size;
    const elem_offset: u32 = memory_init_offset + memory_init_size;
    const imports_offset: u32 = elem_offset + elem_size;
    const wasm_bytes_offset: u32 = imports_offset + imports_size;
    const func_extras_offset: u32 = wasm_bytes_offset + wasm_bytes_size;
    const eh_offset: u32 = func_extras_offset + func_extras_size;
    const code_offset: u32 = eh_offset + eh_size;
    const total_size: u32 = code_offset + code_size;

    var out = try allocator.alloc(u8, total_size);
    errdefer allocator.free(out);
    @memset(out, 0); // alignment padding stays zero

    // 1. Header.
    const header: CwasmHeader = .{
        .arch = input.arch,
        .n_funcs = n_funcs,
        .n_types = input.n_types,
        .n_imports = input.n_imports,
        .code_offset = code_offset,
        .code_size = code_size,
        .metadata_offset = metadata_offset,
        .metadata_size = metadata_size,
        .types_offset = types_offset,
        .types_size = types_size,
        .relocs_offset = relocs_offset,
        .relocs_size = relocs_size,
        .exports_offset = exports_offset,
        .exports_size = exports_size,
        .globals_offset = globals_offset,
        .globals_size = globals_size,
        .flags = (if (input.has_memory) format.flag_has_memory else 0) |
            (if (input.has_table) format.flag_has_table else 0) |
            (if (input.bounds_elided) format.flag_bounds_elided else 0),
        .memory_min_pages = if (input.has_memory) input.mem_min_pages else 0,
        .memory_max_pages = if (input.has_memory) input.mem_max_pages else 0,
        .memory_init_offset = memory_init_offset,
        .memory_init_size = memory_init_size,
        .table0_size = if (input.has_table) input.table0_size else 0,
        .elem_offset = elem_offset,
        .elem_size = elem_size,
        .imports_offset = imports_offset,
        .imports_size = imports_size,
        .wasm_bytes_offset = wasm_bytes_offset,
        .wasm_bytes_size = wasm_bytes_size,
        .func_extras_offset = func_extras_offset,
        .func_extras_size = func_extras_size,
        .eh_offset = eh_offset,
        .eh_size = eh_size,
    };
    try format.writeHeader(out[0..format.header_size], header);

    // v0.5 sections (ADR-0203 stage 2): embedded module bytes, per-func
    // extras (zero-filled when the caller supplies none — mini-runtime-only
    // test producers), and the module exception table.
    @memcpy(out[wasm_bytes_offset..][0..wasm_bytes_size], input.wasm_bytes);
    for (0..n_funcs) |i| {
        const extra: format.CwasmFuncExtra = if (i < input.func_extras.len)
            input.func_extras[i]
        else
            .{ .frame_bytes = 0, .oob_stub_off = 0 };
        const slot = func_extras_offset + @as(u32, @intCast(i)) * format.func_extra_size;
        try format.writeFuncExtra(out[slot..][0..format.func_extra_size], extra);
    }
    std.mem.writeInt(u32, out[eh_offset..][0..4], @intCast(input.eh_entries.len), .little);
    for (input.eh_entries, 0..) |e, i| {
        const slot = eh_offset + 4 + @as(u32, @intCast(i)) * format.eh_entry_size;
        try format.writeEhEntry(out[slot..][0..format.eh_entry_size], e);
    }

    // 2. Per-func metadata.
    for (input.bytes_per_func, 0..) |b, i| {
        const meta: CwasmFuncMeta = .{
            .code_offset = per_func_offsets[i],
            .code_size = @intCast(b.len),
            .n_slots = input.n_slots_per_func[i],
            .sig_idx = input.sig_idx_per_func[i],
            .canon_typeidx = if (i < input.canon_typeidx_per_func.len) input.canon_typeidx_per_func[i] else 0,
        };
        const slot_off = metadata_offset + @as(u32, @intCast(i)) * format.func_meta_size;
        try format.writeFuncMeta(out[slot_off..][0..format.func_meta_size], meta);
    }

    // 3. Types section (verbatim).
    @memcpy(out[types_offset..][0..types_size], input.types_serialised);

    // 4. Relocs section. Rebase each reloc's `code_offset`
    // from per-func-relative to code-section-relative.
    for (input.relocs, input.func_idx_for_reloc, 0..) |r, fidx, i| {
        // Imports occupy the low indices but have no code
        // bytes; the relocs reference defined-func indices.
        // Caller is responsible for ensuring fidx >= n_imports
        // and (fidx - n_imports) < n_funcs.
        const local_fidx = fidx - input.n_imports;
        const rebased: CwasmReloc = .{
            .code_offset = per_func_offsets[local_fidx] + r.code_offset,
            .target_func_idx = r.target_func_idx,
            .kind = r.kind,
        };
        const slot_off = relocs_offset + @as(u32, @intCast(i)) * format.reloc_size;
        try format.writeReloc(out[slot_off..][0..format.reloc_size], rebased);
    }

    // 5. Exports section: [n_exports: u32] then variable-length entries.
    std.mem.writeInt(u32, out[exports_offset..][0..4], @intCast(input.exports.len), .little);
    var exp_cursor: u32 = exports_offset + 4;
    for (input.exports) |e| {
        const written = try format.writeExportEntry(out[exp_cursor .. exports_offset + exports_size], e);
        exp_cursor += @intCast(written);
    }

    // 6. Globals section: [n_globals: u32] then n_globals × 16-byte values.
    std.mem.writeInt(u32, out[globals_offset..][0..4], @intCast(input.globals.len), .little);
    for (input.globals, 0..) |v, i| {
        const off = globals_offset + 4 + @as(u32, @intCast(i)) * format.global_value_size;
        std.mem.writeInt(u128, out[off..][0..format.global_value_size], v, .little);
    }

    // 7. Memory_init section: [n_segs: u32] then per active segment
    // [mem_offset:u32][byte_len:u32][bytes].
    if (input.has_memory) {
        std.mem.writeInt(u32, out[memory_init_offset..][0..4], @intCast(input.mem_data.len), .little);
        var cursor: u32 = memory_init_offset + 4;
        for (input.mem_data) |seg| {
            std.mem.writeInt(u32, out[cursor..][0..4], seg.mem_offset, .little);
            std.mem.writeInt(u32, out[cursor + 4 ..][0..4], @intCast(seg.bytes.len), .little);
            @memcpy(out[cursor + 8 ..][0..seg.bytes.len], seg.bytes);
            cursor += 8 + @as(u32, @intCast(seg.bytes.len));
        }
    }

    // 8. Elem_data section: [n_segs:u32] then per segment
    // [table_offset:u32][n_funcs:u32][funcidx... ×u32].
    if (input.has_table) {
        std.mem.writeInt(u32, out[elem_offset..][0..4], @intCast(input.elem.len), .little);
        var cursor: u32 = elem_offset + 4;
        for (input.elem) |seg| {
            std.mem.writeInt(u32, out[cursor..][0..4], seg.table_offset, .little);
            std.mem.writeInt(u32, out[cursor + 4 ..][0..4], @intCast(seg.funcidxs.len), .little);
            cursor += 8;
            for (seg.funcidxs) |fidx| {
                std.mem.writeInt(u32, out[cursor..][0..4], fidx, .little);
                cursor += 4;
            }
        }
    }

    // 9. Imports section (v0.4): [n_imports_total: u32] then variable-length
    // entries. Always writes the count; standalone-run rebuilds host dispatch.
    std.mem.writeInt(u32, out[imports_offset..][0..4], @intCast(input.imports.len), .little);
    var imp_cursor: u32 = imports_offset + 4;
    for (input.imports) |imp| {
        const written = try format.writeImportEntry(out[imp_cursor .. imports_offset + imports_size], imp);
        imp_cursor += @intCast(written);
    }

    // 10. Code section.
    for (input.bytes_per_func, 0..) |b, i| {
        const off = code_offset + per_func_offsets[i];
        @memcpy(out[off..][0..b.len], b);
    }

    return out;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "produceCwasm: empty module produces parseable header" {
    const input: Input = .{
        .arch = format.arch_arm64,
        .bytes_per_func = &.{},
        .n_slots_per_func = &.{},
        .sig_idx_per_func = &.{},
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &.{},
        .n_imports = 0,
        .n_types = 0,
    };
    const out = try produceCwasm(testing.allocator, input);
    defer testing.allocator.free(out);

    try testing.expect(out.len >= format.header_size);
    const h = try format.parseHeader(out[0..format.header_size]);
    try testing.expectEqual(format.arch_arm64, h.arch);
    try testing.expectEqual(@as(u32, 0), h.n_funcs);
    try testing.expectEqual(@as(u32, 0), h.code_size);
}

test "produceCwasm: single-func round-trip preserves bytes" {
    const fn_bytes = [_]u8{ 0x40, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6 }; // arm64 MOV X0, #2; RET
    const input: Input = .{
        .arch = format.arch_arm64,
        .bytes_per_func = &.{&fn_bytes},
        .n_slots_per_func = &.{1},
        .sig_idx_per_func = &.{0},
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &.{ 0x60, 0x00, 0x01, 0x7F }, // synthetic: () -> i32
        .n_imports = 0,
        .n_types = 1,
    };
    const out = try produceCwasm(testing.allocator, input);
    defer testing.allocator.free(out);

    const h = try format.parseHeader(out[0..format.header_size]);
    try testing.expectEqual(@as(u32, 1), h.n_funcs);
    try testing.expectEqual(@as(u32, 1), h.n_types);
    try testing.expectEqual(format.func_meta_size, h.metadata_size);
    try testing.expectEqual(@as(u32, 4), h.types_size); // length of synthetic types
    try testing.expectEqual(@as(u32, 0), h.relocs_size);

    // Per-func metadata.
    const meta = try format.parseFuncMeta(out[h.metadata_offset..][0..format.func_meta_size]);
    try testing.expectEqual(@as(u32, 0), meta.code_offset);
    try testing.expectEqual(@as(u32, fn_bytes.len), meta.code_size);
    try testing.expectEqual(@as(u16, 1), meta.n_slots);
    try testing.expectEqual(@as(u16, 0), meta.sig_idx);

    // Code section bytes preserved.
    const code_slice = out[h.code_offset..][0..fn_bytes.len];
    try testing.expectEqualSlices(u8, &fn_bytes, code_slice);
}

test "produceCwasm: two-func with reloc round-trips bytes + reloc rebase" {
    const fn0 = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const fn1 = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const reloc_within_fn1: format.CwasmReloc = .{
        .code_offset = 1, // within fn1 (index 1 of fn1's bytes)
        .target_func_idx = 0, // calls fn0
        .kind = format.reloc_kind_direct_call,
    };
    const input: Input = .{
        .arch = format.arch_x86_64,
        .bytes_per_func = &.{ &fn0, &fn1 },
        .n_slots_per_func = &.{ 0, 0 },
        .sig_idx_per_func = &.{ 0, 0 },
        .relocs = &.{reloc_within_fn1},
        .func_idx_for_reloc = &.{1}, // owned by fn1
        .types_serialised = &.{0x60},
        .n_imports = 0,
        .n_types = 1,
    };
    const out = try produceCwasm(testing.allocator, input);
    defer testing.allocator.free(out);

    const h = try format.parseHeader(out[0..format.header_size]);
    try testing.expectEqual(format.arch_x86_64, h.arch);
    try testing.expectEqual(@as(u32, 2), h.n_funcs);
    try testing.expectEqual(@as(u32, 1) * format.reloc_size, h.relocs_size);

    // Reloc rebase: fn1 sits at offset 4 (fn0 is 4 bytes,
    // 4-byte aligned). reloc_within_fn1.code_offset = 1
    // becomes 4 + 1 = 5 in the code section.
    const got_reloc = try format.parseReloc(out[h.relocs_offset..][0..format.reloc_size]);
    try testing.expectEqual(@as(u32, 5), got_reloc.code_offset);
    try testing.expectEqual(@as(u32, 0), got_reloc.target_func_idx);
    try testing.expectEqual(format.reloc_kind_direct_call, got_reloc.kind);

    // Per-func metadata: fn0 at 0, fn1 at 4 (aligned).
    const meta0 = try format.parseFuncMeta(out[h.metadata_offset..][0..format.func_meta_size]);
    const meta1 = try format.parseFuncMeta(out[h.metadata_offset + format.func_meta_size ..][0..format.func_meta_size]);
    try testing.expectEqual(@as(u32, 0), meta0.code_offset);
    try testing.expectEqual(@as(u32, 4), meta1.code_offset);

    // Code bytes preserved.
    try testing.expectEqualSlices(u8, &fn0, out[h.code_offset..][0..fn0.len]);
    try testing.expectEqualSlices(u8, &fn1, out[h.code_offset + 4 ..][0..fn1.len]);
}

test "produceCwasm: alignment pads code section to 4 bytes" {
    const fn0 = [_]u8{ 0x01, 0x02, 0x03 }; // 3 bytes — not 4-aligned
    const fn1 = [_]u8{0xFF};
    const input: Input = .{
        .arch = format.arch_arm64,
        .bytes_per_func = &.{ &fn0, &fn1 },
        .n_slots_per_func = &.{ 0, 0 },
        .sig_idx_per_func = &.{ 0, 0 },
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &.{},
        .n_imports = 0,
        .n_types = 0,
    };
    const out = try produceCwasm(testing.allocator, input);
    defer testing.allocator.free(out);

    const h = try format.parseHeader(out[0..format.header_size]);
    const meta1 = try format.parseFuncMeta(out[h.metadata_offset + format.func_meta_size ..][0..format.func_meta_size]);
    // fn0 is 3 bytes, padded to 4; fn1 starts at offset 4.
    try testing.expectEqual(@as(u32, 4), meta1.code_offset);
    // Total code size: 4 (fn0+pad) + 1 (fn1) = 5, padded to 8.
    try testing.expectEqual(@as(u32, 8), h.code_size);
}
