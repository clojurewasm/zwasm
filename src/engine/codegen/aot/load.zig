//! `.cwasm` loader / consumer (per ADR-0039; v0.2 per ADR-0138).
//!
//! Reads a `.cwasm` image produced by `serialise.produceCwasm`, copies
//! its code section into a fresh executable `JitBlock`, applies
//! load-time relocations, and exposes per-function entry pointers. The
//! symmetric reader to the producer: `format.parseHeader` /
//! `parseFuncMeta` / `parseReloc` index the fixed-shape sections.
//!
//! **Divergence (vs v1)**: the `.cwasm` file stays
//! IMMUTABLE — relocations are applied to the runtime-allocated
//! `JitBlock`, never patched back into the file. This eager
//! copy-and-patch keeps the artefact relocatable (future lazy / COW /
//! cross-arch re-bind per ADR-0039 §"Alternative E").
//!
//! Arch-blind: the header's arch tag must match the host (we execute
//! the code natively); this module does not import `arm64/` or
//! `x86_64/` for the load path (the reloc patch is the one place a
//! per-arch encoding is needed — kept as a local comptime switch, no
//! cross-arch module import).
//!
//! Zone 2 (`src/engine/codegen/aot/`).

const std = @import("std");
const builtin = @import("builtin");

const format = @import("format.zig");
const jit_mem = @import("../../../platform/jit_mem.zig");

const Allocator = std.mem.Allocator;

pub const Error = format.Error || jit_mem.Error || Allocator.Error || error{
    /// The `.cwasm` arch tag does not match the host arch (cross-arch
    /// load is deferred per ADR-0039 §"Alternative D").
    ArchMismatch,
    /// A section offset/size in the header runs past the buffer.
    TruncatedImage,
};

/// A func-kind export resolved from the `.cwasm` exports section.
/// `name` is allocator-owned (duped from the source buffer, which may
/// be freed after `load`).
pub const Export = struct {
    name: []u8,
    func_idx: u32, // wasm-space (imports included)
};

/// One import reconstructed from the v0.4 imports-metadata section
/// (D-251 AOT-WASI): module + field name (allocator-owned dups, since the
/// source `.cwasm` buffer may be freed after `load`) + the import kind
/// byte (`@intFromEnum(sections.ImportKind)`). The standalone runner
/// replays these to rebuild `host_dispatch_base`.
pub const ImportMeta = struct {
    module: []u8,
    name: []u8,
    kind: u8,
};

/// One active data segment reconstructed from the memory_init section
/// (v0.3 cycle-1b): destination byte offset + init bytes (allocator-owned
/// dup, since the source `.cwasm` buffer may be freed after `load`).
pub const MemDataSeg = struct {
    mem_offset: u32,
    bytes: []u8,
};

/// The (single) result type of a defined function, parsed from the
/// `.cwasm` types section so a standalone runner can dispatch the entry
/// call without the original `.wasm`. `unsupported` = 0 results is
/// `void_`; >1 result or a non-scalar valtype is `unsupported` (the
/// MVP CLI runs only void / scalar-result entries — multi-result +
/// v128/ref results are later scope).
pub const ResultKind = enum { void_, i32_, i64_, f32_, f64_, unsupported };

/// A loaded `.cwasm` image: an executable `JitBlock` holding the copied
/// code section + per-defined-function byte offsets into it.
pub const LoadedModule = struct {
    block: jit_mem.JitBlock,
    /// Byte offset of each defined function within `block.bytes`,
    /// indexed by defined-func order (imports excluded). Allocator-owned.
    func_offsets: []u32,
    /// Func-kind exports (name → wasm func idx), v0.2 (ADR-0138).
    /// Allocator-owned; each `name` is independently allocated.
    exports: []Export,
    /// Single-result kind per defined function (indexed by defined
    /// idx), parsed from the types section for standalone entry
    /// dispatch. Allocator-owned.
    func_result_kinds: []ResultKind,
    /// Pre-evaluated defined-global init values (v0.3), one
    /// `Value.bits128` per defined global. A stateful standalone runtime
    /// memcpys these into `globals_base`. Allocator-owned; empty when the
    /// `.cwasm` has no globals.
    globals: []u128,
    /// Linear-memory state (v0.3 cycle-1b). `has_memory` gates the rest;
    /// `mem_min_pages` sizes the allocation; `mem_data` are the active data
    /// segments to memcpy in. All allocator-owned.
    has_memory: bool,
    mem_min_pages: u32,
    mem_data: []MemDataSeg,
    /// Table 0 (v0.3 cycle-2a). `table_size` = slot count; `funcptr_base`
    /// (native loaded func addresses) + `typeidx_base` (canonical typeidx,
    /// maxInt sentinel for empty slots) are computed at load from elem_data +
    /// func_offsets. All allocator-owned; `runEntry` aliases the bases.
    table_size: u32,
    funcptr_base: []u64,
    typeidx_base: []u32,
    /// Imported-function count; `entry`/`resolveEntry` index defined
    /// funcs (wasm idx - n_imports).
    n_imports: u32,
    /// Imports metadata (v0.4 §D-251): `(module, name, kind)` per declared
    /// import in wasm-space order. The standalone WASI runner replays these
    /// to populate `host_dispatch_base`. Empty for a v0.4 image with no
    /// imports. Allocator-owned (module/name independently allocated).
    imports: []ImportMeta,
    allocator: Allocator,

    pub fn deinit(self: *LoadedModule) void {
        for (self.exports) |e| self.allocator.free(e.name);
        self.allocator.free(self.exports);
        self.allocator.free(self.func_result_kinds);
        self.allocator.free(self.globals);
        for (self.mem_data) |seg| self.allocator.free(seg.bytes);
        self.allocator.free(self.mem_data);
        self.allocator.free(self.funcptr_base);
        self.allocator.free(self.typeidx_base);
        self.allocator.free(self.func_offsets);
        for (self.imports) |imp| {
            self.allocator.free(imp.module);
            self.allocator.free(imp.name);
        }
        self.allocator.free(self.imports);
        jit_mem.free(self.block);
    }

    /// Result kind of defined function `idx` (for standalone dispatch).
    pub fn resultKind(self: LoadedModule, idx: usize) ResultKind {
        return self.func_result_kinds[idx];
    }

    /// Entry pointer for defined function `idx`. `Fn` is the
    /// `callconv(.c)` function-pointer type (the JIT ABI passes
    /// `*JitRuntime` in X0/RDI).
    pub fn entry(self: LoadedModule, idx: usize, comptime Fn: type) Fn {
        return @ptrCast(@alignCast(self.block.bytes.ptr + self.func_offsets[idx]));
    }

    /// Resolve the entry func's DEFINED-func index (ready for `entry`),
    /// mirroring `cli/run.zig`'s precedence: explicit `invoke_name`
    /// override → `_start` → `main` → first func export. Returns null
    /// when nothing matches OR the match is an imported function (an
    /// import cannot be an execution entry). Pair with `entry(idx, Fn)`.
    pub fn resolveEntry(self: LoadedModule, invoke_name: ?[]const u8) ?usize {
        const wasm_idx: u32 = if (invoke_name) |n|
            (self.lookup(n) orelse return null)
        else
            self.lookup("_start") orelse self.lookup("main") orelse
                (if (self.exports.len > 0) self.exports[0].func_idx else return null);
        if (wasm_idx < self.n_imports) return null;
        return wasm_idx - self.n_imports;
    }

    fn lookup(self: LoadedModule, name: []const u8) ?u32 {
        for (self.exports) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.func_idx;
        }
        return null;
    }
};

/// Load a `.cwasm` image. `bytes` is the full file; the loader copies
/// the code section into a fresh executable block, so `bytes` may be
/// freed after this returns. Caller owns the result; call `deinit`.
pub fn load(allocator: Allocator, bytes: []const u8) Error!LoadedModule {
    const h = try format.parseHeader(bytes);

    const native_arch: u32 = switch (builtin.target.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => return Error.ArchMismatch,
    };
    if (h.arch != native_arch) return Error.ArchMismatch;

    // Bounds: every section the loader reads must lie within `bytes`.
    if (@as(u64, h.code_offset) + h.code_size > bytes.len) return Error.TruncatedImage;
    if (@as(u64, h.metadata_offset) + h.metadata_size > bytes.len) return Error.TruncatedImage;
    if (@as(u64, h.relocs_offset) + h.relocs_size > bytes.len) return Error.TruncatedImage;
    if (@as(u64, h.exports_offset) + h.exports_size > bytes.len) return Error.TruncatedImage;
    if (@as(u64, h.globals_offset) + h.globals_size > bytes.len) return Error.TruncatedImage;
    if (h.code_size == 0) return Error.TruncatedImage; // nothing executable to load

    // Exports section (v0.2): dup names into allocator-owned memory so
    // they outlive `bytes` (which the caller may free after `load`).
    const exports = try parseExports(allocator, bytes, h);
    errdefer {
        for (exports) |e| allocator.free(e.name);
        allocator.free(exports);
    }

    if (@as(u64, h.memory_init_offset) + h.memory_init_size > bytes.len) return Error.TruncatedImage;

    // Globals section (v0.3): copy pre-evaluated init values out of `bytes`.
    const globals = try parseGlobals(allocator, bytes, h);
    errdefer allocator.free(globals);

    // Memory_init section (v0.3 cycle-1b): dup the active data segments.
    const has_memory = (h.flags & format.flag_has_memory) != 0;
    const mem_data = try parseMemData(allocator, bytes, h);
    errdefer {
        for (mem_data) |seg| allocator.free(seg.bytes);
        allocator.free(mem_data);
    }

    // Imports section (v0.4 §D-251): dup module/name into allocator-owned
    // memory so they outlive `bytes`.
    if (@as(u64, h.imports_offset) + h.imports_size > bytes.len) return Error.TruncatedImage;
    const imports = try parseImports(allocator, bytes, h);
    errdefer {
        for (imports) |imp| {
            allocator.free(imp.module);
            allocator.free(imp.name);
        }
        allocator.free(imports);
    }

    // Allocate the executable block, copy the code section in (W^X:
    // writable while copying/patching, executable before any entry call).
    var block = try jit_mem.alloc(h.code_size);
    errdefer jit_mem.free(block);
    try jit_mem.setWritable(block);
    @memcpy(block.bytes[0..h.code_size], bytes[h.code_offset..][0..h.code_size]);

    // Per-defined-function code offsets + result kinds from the
    // metadata + types sections.
    const func_offsets = try allocator.alloc(u32, h.n_funcs);
    errdefer allocator.free(func_offsets);
    const func_result_kinds = try allocator.alloc(ResultKind, h.n_funcs);
    errdefer allocator.free(func_result_kinds);
    const func_canon = try allocator.alloc(u32, h.n_funcs);
    defer allocator.free(func_canon);
    const types_section = bytes[h.types_offset..][0..h.types_size];
    for (0..h.n_funcs) |i| {
        const off = h.metadata_offset + @as(u32, @intCast(i)) * format.func_meta_size;
        const meta = try format.parseFuncMeta(bytes[off..][0..format.func_meta_size]);
        func_offsets[i] = meta.code_offset;
        func_result_kinds[i] = typeResultKind(types_section, meta.sig_idx);
        func_canon[i] = meta.canon_typeidx;
    }

    try applyRelocs(block, func_offsets, bytes, h);

    // Table 0 + element segments (v0.3 cycle-2a): build funcptr/typeidx
    // arrays from the loaded func addresses + elem_data. Done after relocs
    // (block address stable); slot funcptr = loaded entry of the elem funcidx.
    if (@as(u64, h.elem_offset) + h.elem_size > bytes.len) return Error.TruncatedImage;
    const table = try buildTable(allocator, bytes, h, block, func_offsets, func_canon);
    errdefer {
        allocator.free(table.funcptr_base);
        allocator.free(table.typeidx_base);
    }

    try jit_mem.setExecutable(block);
    return .{
        .block = block,
        .func_offsets = func_offsets,
        .exports = exports,
        .func_result_kinds = func_result_kinds,
        .globals = globals,
        .has_memory = has_memory,
        .mem_min_pages = h.memory_min_pages,
        .mem_data = mem_data,
        .table_size = table.table_size,
        .funcptr_base = table.funcptr_base,
        .typeidx_base = table.typeidx_base,
        .n_imports = h.n_imports,
        .imports = imports,
        .allocator = allocator,
    };
}

/// Parse the v0.4 imports-metadata section ([n_imports_total: u32] then
/// variable-length `(module, name, kind)` entries), duping each name into
/// allocator-owned memory. An `imports_size` < 4 (e.g. a pre-v0.4-shaped
/// image, though those are version-rejected) yields zero imports.
fn parseImports(allocator: Allocator, bytes: []const u8, h: format.CwasmHeader) Error![]ImportMeta {
    if (h.imports_size < 4) return allocator.alloc(ImportMeta, 0);
    const section = bytes[h.imports_offset..][0..h.imports_size];
    const n_imports = std.mem.readInt(u32, section[0..4], .little);

    var list = try allocator.alloc(ImportMeta, n_imports);
    errdefer allocator.free(list);
    var filled: usize = 0;
    errdefer for (list[0..filled]) |imp| {
        allocator.free(imp.module);
        allocator.free(imp.name);
    };

    var cursor: usize = 4;
    for (0..n_imports) |i| {
        const parsed = try format.parseImportEntry(section[cursor..]);
        const module = try allocator.dupe(u8, parsed.imp.module);
        errdefer allocator.free(module);
        const name = try allocator.dupe(u8, parsed.imp.name);
        list[i] = .{ .module = module, .name = name, .kind = parsed.imp.kind };
        filled = i + 1;
        cursor += parsed.consumed;
    }
    return list;
}

/// Table-0 reconstruction (v0.3 cycle-2a). Allocates `funcptr_base`
/// (native loaded entry per slot) + `typeidx_base` (canonical typeidx,
/// `maxInt(u32)` sentinel for empty slots) sized to `table0_size`, then
/// fills them from the active element segments. A slot's funcptr is the
/// loaded address of its elem funcidx (`block.bytes.ptr + func_offsets[F -
/// n_imports]`); imported funcidxs (F < n_imports) cannot populate a table
/// (call_indirect can't invoke a host import) → left as the null/sentinel.
fn buildTable(
    allocator: Allocator,
    bytes: []const u8,
    h: format.CwasmHeader,
    block: jit_mem.JitBlock,
    func_offsets: []const u32,
    func_canon: []const u32,
) Error!struct { table_size: u32, funcptr_base: []u64, typeidx_base: []u32 } {
    const has_table = (h.flags & format.flag_has_table) != 0;
    if (!has_table or h.table0_size == 0) {
        return .{ .table_size = 0, .funcptr_base = try allocator.alloc(u64, 0), .typeidx_base = try allocator.alloc(u32, 0) };
    }
    const n = h.table0_size;
    const funcptr_base = try allocator.alloc(u64, n);
    errdefer allocator.free(funcptr_base);
    @memset(funcptr_base, 0);
    const typeidx_base = try allocator.alloc(u32, n);
    errdefer allocator.free(typeidx_base);
    @memset(typeidx_base, std.math.maxInt(u32)); // "no function in slot"

    if (h.elem_size >= 4) {
        const section = bytes[h.elem_offset..][0..h.elem_size];
        const n_segs = std.mem.readInt(u32, section[0..4], .little);
        var cursor: usize = 4;
        for (0..n_segs) |_| {
            if (cursor + 8 > section.len) return Error.TruncatedImage;
            const table_offset = std.mem.readInt(u32, section[cursor..][0..4], .little);
            const n_funcs = std.mem.readInt(u32, section[cursor + 4 ..][0..4], .little);
            cursor += 8;
            if (cursor + @as(u64, n_funcs) * 4 > section.len) return Error.TruncatedImage;
            for (0..n_funcs) |i| {
                const fidx = std.mem.readInt(u32, section[cursor..][0..4], .little);
                cursor += 4;
                const slot = table_offset + @as(u32, @intCast(i));
                if (slot >= n) return Error.TruncatedImage;
                if (fidx < h.n_imports) continue; // import → can't be a table funcptr
                const defined = fidx - h.n_imports;
                if (defined >= func_offsets.len) return Error.TruncatedImage;
                funcptr_base[slot] = @intFromPtr(block.bytes.ptr + func_offsets[defined]);
                typeidx_base[slot] = func_canon[defined];
            }
        }
    }
    return .{ .table_size = n, .funcptr_base = funcptr_base, .typeidx_base = typeidx_base };
}

/// Parse the v0.3 memory_init section ([n_segs: u32] then per segment
/// [mem_offset:u32][byte_len:u32][bytes]), duping each segment's bytes into
/// allocator-owned memory. Empty (size 0 / no memory) yields zero segments.
fn parseMemData(allocator: Allocator, bytes: []const u8, h: format.CwasmHeader) Error![]MemDataSeg {
    if (h.memory_init_size < 4) return allocator.alloc(MemDataSeg, 0);
    const section = bytes[h.memory_init_offset..][0..h.memory_init_size];
    const n_segs = std.mem.readInt(u32, section[0..4], .little);

    var list = try allocator.alloc(MemDataSeg, n_segs);
    errdefer allocator.free(list);
    var filled: usize = 0;
    errdefer for (list[0..filled]) |seg| allocator.free(seg.bytes);

    var cursor: usize = 4;
    for (0..n_segs) |i| {
        if (cursor + 8 > section.len) return Error.TruncatedImage;
        const mem_offset = std.mem.readInt(u32, section[cursor..][0..4], .little);
        const byte_len = std.mem.readInt(u32, section[cursor + 4 ..][0..4], .little);
        const body = cursor + 8;
        if (body + byte_len > section.len) return Error.TruncatedImage;
        list[i] = .{ .mem_offset = mem_offset, .bytes = try allocator.dupe(u8, section[body..][0..byte_len]) };
        filled = i + 1;
        cursor = body + byte_len;
    }
    return list;
}

/// Parse the v0.3 globals section ([n_globals: u32] then n_globals ×
/// 16-byte values) into an allocator-owned `[]u128`. Empty (or a v0.2-
/// shaped image with globals_size 0) yields zero globals.
fn parseGlobals(allocator: Allocator, bytes: []const u8, h: format.CwasmHeader) Error![]u128 {
    if (h.globals_size < 4) return allocator.alloc(u128, 0);
    const section = bytes[h.globals_offset..][0..h.globals_size];
    const n_globals = std.mem.readInt(u32, section[0..4], .little);
    if (4 + @as(u64, n_globals) * format.global_value_size > section.len) return Error.TruncatedImage;

    const out = try allocator.alloc(u128, n_globals);
    errdefer allocator.free(out);
    for (0..n_globals) |i| {
        const off = 4 + i * format.global_value_size;
        out[i] = std.mem.readInt(u128, section[off..][0..format.global_value_size], .little);
    }
    return out;
}

/// Walk the producer's types section to `type_idx` and return that
/// FuncType's single result kind. Section layout (ADR-0039 §Types,
/// produced by `serialise`): a sequence of FuncTypes, each
/// `[params_count:u8][results_count:u8][params…][results…]` where each
/// valtype byte is `@intFromEnum(zir.ValType)` (i32=0, i64=1, f32=2,
/// f64=3, v128=4, ref=5). `void_` for 0 results; `unsupported` for >1
/// result or a non-scalar valtype. Total (never errors): a too-short /
/// absent types section (e.g. synthetic loader fixtures with no types)
/// yields `unsupported` — the result kind is only consulted by the
/// standalone runner, which rejects `unsupported` loudly at call time.
fn typeResultKind(types_section: []const u8, type_idx: u32) ResultKind {
    var cursor: usize = 0;
    var i: u32 = 0;
    while (true) : (i += 1) {
        if (cursor + 2 > types_section.len) return .unsupported;
        const params_count = types_section[cursor];
        const results_count = types_section[cursor + 1];
        const body = cursor + 2;
        const end = body + params_count + results_count;
        if (end > types_section.len) return .unsupported;
        if (i == type_idx) {
            if (results_count == 0) return .void_;
            if (results_count > 1) return .unsupported;
            return switch (types_section[body + params_count]) {
                0 => .i32_,
                1 => .i64_,
                2 => .f32_,
                3 => .f64_,
                else => .unsupported,
            };
        }
        cursor = end;
    }
}

/// Parse the v0.2 exports section, duplicating each name into
/// allocator-owned memory. An `exports_size` of 0 (or a v0.1-shaped
/// image) yields zero exports.
fn parseExports(allocator: Allocator, bytes: []const u8, h: format.CwasmHeader) Error![]Export {
    if (h.exports_size < 4) return allocator.alloc(Export, 0);
    const section = bytes[h.exports_offset..][0..h.exports_size];
    const n_exports = std.mem.readInt(u32, section[0..4], .little);

    var list = try allocator.alloc(Export, n_exports);
    errdefer allocator.free(list);
    var filled: usize = 0;
    errdefer for (list[0..filled]) |e| allocator.free(e.name);

    var cursor: usize = 4;
    for (0..n_exports) |i| {
        const parsed = try format.parseExportEntry(section[cursor..]);
        list[i] = .{
            .name = try allocator.dupe(u8, parsed.exp.name),
            .func_idx = parsed.exp.func_idx,
        };
        filled = i + 1;
        cursor += parsed.consumed;
    }
    return list;
}

/// Apply every load-time relocation by patching the call-site
/// placeholders in `block.bytes` (the same in-place BL/CALL patch the
/// JIT linker performs — see `shared/linker.zig`). v0.1 supports only
/// `reloc_kind_direct_call`. With zero relocs this is a no-op (a
/// single self-contained function needs no patching).
fn applyRelocs(
    block: jit_mem.JitBlock,
    func_offsets: []const u32,
    bytes: []const u8,
    h: format.CwasmHeader,
) Error!void {
    const n_relocs = h.relocs_size / format.reloc_size;
    for (0..n_relocs) |i| {
        const off = h.relocs_offset + @as(u32, @intCast(i)) * format.reloc_size;
        const r = try format.parseReloc(bytes[off..][0..format.reloc_size]);
        // v0.1: only direct_call. Unknown kinds are a forward-compat
        // gap, not a silent skip — reject loudly.
        if (r.kind != format.reloc_kind_direct_call) return Error.UnsupportedVersion;

        const local_target = r.target_func_idx - h.n_imports;
        const fixup_abs: i64 = r.code_offset;
        const target_abs: i64 = func_offsets[local_target];
        switch (builtin.target.cpu.arch) {
            .aarch64 => {
                const disp_bytes = target_abs - fixup_abs;
                const disp_words = @divExact(disp_bytes, 4);
                // BL imm26: 0x94000000 | (imm26 & 0x03FF_FFFF).
                const imm26: u32 = @bitCast(@as(i32, @intCast(disp_words)));
                const word: u32 = 0x9400_0000 | (imm26 & 0x03FF_FFFF);
                std.mem.writeInt(u32, block.bytes[@intCast(fixup_abs)..][0..4], word, .little);
            },
            .x86_64 => {
                // CALL rel32 (0xE8 + disp32): disp = target - (at + 5).
                const disp: i32 = @intCast(target_abs - fixup_abs - 5);
                block.bytes[@intCast(fixup_abs)] = 0xE8;
                std.mem.writeInt(i32, block.bytes[@intCast(fixup_abs + 1)..][0..4], disp, .little);
            },
            else => return Error.ArchMismatch,
        }
    }
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;
const serialise = @import("serialise.zig");
const skip = @import("../../../test_support/skip.zig");

test "load: single ()->i32 const func executes, returns 7" {
    // Executes native machine code → mirror jit_mem's exec-test Win64
    // deferral (ADR-0122 phaseEnd batch); the loader path itself is
    // host-portable, only the fixture bytes are arch-specific.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);

    const arch_tag: u32 = switch (builtin.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => @compileError("unsupported arch for AOT loader exec test"),
    };
    // A self-contained `() -> i32` returning 7 (ignores the X0/RDI rt
    // arg). arm64: MOVZ X0,#7 (E0 00 80 D2) ; RET (C0 03 5F D6).
    // x86_64: mov eax,7 (B8 07 00 00 00) ; ret (C3).
    const fn_bytes: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => &[_]u8{ 0xE0, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6 },
        .x86_64 => &[_]u8{ 0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3 },
        else => unreachable,
    };

    const cwasm = try serialise.produceCwasm(testing.allocator, .{
        .arch = arch_tag,
        .bytes_per_func = &.{fn_bytes},
        .n_slots_per_func = &.{1},
        .sig_idx_per_func = &.{0},
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &.{},
        .n_imports = 0,
        .n_types = 0,
    });
    defer testing.allocator.free(cwasm);

    var mod = try load(testing.allocator, cwasm);
    defer mod.deinit();

    const f = mod.entry(0, *const fn () callconv(.c) i32);
    try testing.expectEqual(@as(i32, 7), f());
}

test "load: rejects an arch-mismatched image" {
    // Pick the NON-host arch tag; produce a trivially-shaped image.
    const other_arch: u32 = switch (builtin.cpu.arch) {
        .aarch64 => format.arch_x86_64,
        else => format.arch_arm64,
    };
    const cwasm = try serialise.produceCwasm(testing.allocator, .{
        .arch = other_arch,
        .bytes_per_func = &.{&[_]u8{ 0x00, 0x00, 0x00, 0x00 }},
        .n_slots_per_func = &.{0},
        .sig_idx_per_func = &.{0},
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &.{},
        .n_imports = 0,
        .n_types = 0,
    });
    defer testing.allocator.free(cwasm);
    try testing.expectError(Error.ArchMismatch, load(testing.allocator, cwasm));
}

test "load: rejects a truncated buffer (no header)" {
    var buf: [format.header_size - 1]u8 = undefined;
    try testing.expectError(format.Error.TruncatedHeader, load(testing.allocator, &buf));
}

test "load: 2-func direct-call reloc resolves; cross-call returns 7" {
    // Exercises applyRelocs end-to-end: func0 calls func1 (returns 7) and
    // propagates the result; the BL/CALL placeholder must be patched to
    // target func1's loaded address. Executes native code → Win64-deferred.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);

    const arch_tag: u32 = switch (builtin.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => @compileError("unsupported arch for AOT reloc exec test"),
    };
    // func0 (calls func1, propagates its i32 return):
    //   arm64: STP X29,X30,[SP,#-16]! ; BL <placeholder> ; LDP X29,X30,[SP],#16 ; RET
    //          (frame save/restore so the BL-clobbered LR is restored before RET)
    //   x86_64: CALL rel32 <placeholder> ; RET  (return addr is stack-based, no save needed)
    const func0: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => &[_]u8{ 0xFD, 0x7B, 0xBF, 0xA9, 0x00, 0x00, 0x00, 0x94, 0xFD, 0x7B, 0xC1, 0xA8, 0xC0, 0x03, 0x5F, 0xD6 },
        .x86_64 => &[_]u8{ 0xE8, 0x00, 0x00, 0x00, 0x00, 0xC3 },
        else => unreachable,
    };
    // func1: () -> i32 returning 7.
    const func1: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => &[_]u8{ 0xE0, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6 },
        .x86_64 => &[_]u8{ 0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3 },
        else => unreachable,
    };
    // Per-func-relative offset of the call placeholder within func0
    // (arm64: after the 4-byte STP; x86_64: at the start).
    const reloc_off: u32 = switch (builtin.cpu.arch) {
        .aarch64 => 4,
        .x86_64 => 0,
        else => unreachable,
    };

    const cwasm = try serialise.produceCwasm(testing.allocator, .{
        .arch = arch_tag,
        .bytes_per_func = &.{ func0, func1 },
        .n_slots_per_func = &.{ 2, 1 },
        .sig_idx_per_func = &.{ 0, 0 },
        .relocs = &.{.{ .code_offset = reloc_off, .target_func_idx = 1, .kind = format.reloc_kind_direct_call }},
        .func_idx_for_reloc = &.{0},
        .types_serialised = &.{},
        .n_imports = 0,
        .n_types = 1,
    });
    defer testing.allocator.free(cwasm);

    var mod = try load(testing.allocator, cwasm);
    defer mod.deinit();

    const f = mod.entry(0, *const fn () callconv(.c) i32);
    try testing.expectEqual(@as(i32, 7), f());
}

test "load: exports section resolves entry by name, falls back, then executes (v0.2 / ADR-0138)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);

    const arch_tag: u32 = switch (builtin.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => @compileError("unsupported arch for AOT exports exec test"),
    };
    // Self-contained `() -> i32` returning 7 (same bytes as the single-func
    // test), exported as "f".
    const fn_bytes: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => &[_]u8{ 0xE0, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6 },
        .x86_64 => &[_]u8{ 0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3 },
        else => unreachable,
    };

    const cwasm = try serialise.produceCwasm(testing.allocator, .{
        .arch = arch_tag,
        .bytes_per_func = &.{fn_bytes},
        .n_slots_per_func = &.{1},
        .sig_idx_per_func = &.{0},
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &.{},
        .n_imports = 0,
        .n_types = 0,
        .exports = &.{.{ .name = "f", .func_idx = 0 }},
    });
    defer testing.allocator.free(cwasm);

    var mod = try load(testing.allocator, cwasm);
    defer mod.deinit();

    // Named lookup hits; an absent name misses. With no _start/main, the
    // null (default) request falls back to the first func export ("f").
    try testing.expectEqual(@as(?usize, 0), mod.resolveEntry("f"));
    try testing.expectEqual(@as(?usize, null), mod.resolveEntry("missing"));
    try testing.expectEqual(@as(?usize, 0), mod.resolveEntry(null));

    const idx = mod.resolveEntry(null).?;
    const f = mod.entry(idx, *const fn () callconv(.c) i32);
    try testing.expectEqual(@as(i32, 7), f());
}

test "load: v0.4 imports-metadata round-trips module/name/kind (D-251)" {
    // No execution — the imports section is arch-independent metadata, so
    // this exercises produce→load→mod.imports on every host (incl. Win64).
    const arch_tag: u32 = switch (builtin.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => return,
    };
    const stub: []const u8 = &[_]u8{ 0xC0, 0x03, 0x5F, 0xD6 };
    const cwasm = try serialise.produceCwasm(testing.allocator, .{
        .arch = arch_tag,
        .bytes_per_func = &.{stub},
        .n_slots_per_func = &.{0},
        .sig_idx_per_func = &.{0},
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &.{},
        .n_imports = 2,
        .n_types = 0,
        .imports = &.{
            .{ .module = "wasi_snapshot_preview1", .name = "fd_write", .kind = 0x00 },
            .{ .module = "env", .name = "memory", .kind = 0x02 },
        },
    });
    defer testing.allocator.free(cwasm);

    var mod = try load(testing.allocator, cwasm);
    defer mod.deinit();

    try testing.expectEqual(@as(usize, 2), mod.imports.len);
    try testing.expectEqualStrings("wasi_snapshot_preview1", mod.imports[0].module);
    try testing.expectEqualStrings("fd_write", mod.imports[0].name);
    try testing.expectEqual(@as(u8, 0x00), mod.imports[0].kind);
    try testing.expectEqualStrings("env", mod.imports[1].module);
    try testing.expectEqualStrings("memory", mod.imports[1].name);
    try testing.expectEqual(@as(u8, 0x02), mod.imports[1].kind);
}

test "load: _start takes precedence over a non-entry export for the default request" {
    // No execution — `resolveEntry` precedence is arch-independent, so this
    // exercises the name-resolution logic on every host (incl. Win64).
    const arch_tag: u32 = switch (builtin.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => return, // resolveEntry logic is identical; skip on exotic hosts
    };
    // Two trivial funcs; func0 exported "other", func1 exported "_start".
    // The default request must pick "_start" (func1 → defined idx 1), not
    // the first export. Bytes are never executed.
    const stub: []const u8 = &[_]u8{ 0xC0, 0x03, 0x5F, 0xD6 };
    const cwasm = try serialise.produceCwasm(testing.allocator, .{
        .arch = arch_tag,
        .bytes_per_func = &.{ stub, stub },
        .n_slots_per_func = &.{ 0, 0 },
        .sig_idx_per_func = &.{ 0, 0 },
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &.{},
        .n_imports = 0,
        .n_types = 0,
        .exports = &.{ .{ .name = "other", .func_idx = 0 }, .{ .name = "_start", .func_idx = 1 } },
    });
    defer testing.allocator.free(cwasm);

    var mod = try load(testing.allocator, cwasm);
    defer mod.deinit();

    try testing.expectEqual(@as(?usize, 1), mod.resolveEntry(null)); // _start wins
    try testing.expectEqual(@as(?usize, 0), mod.resolveEntry("other"));
    try testing.expectEqual(@as(?usize, 1), mod.resolveEntry("_start"));
}
