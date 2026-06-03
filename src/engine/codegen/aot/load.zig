//! `.cwasm` v0.1 loader / consumer (Phase 12 §12.1 per ADR-0039).
//!
//! Reads a `.cwasm` image produced by `serialise.produceCwasm`, copies
//! its code section into a fresh executable `JitBlock`, applies
//! load-time relocations, and exposes per-function entry pointers. The
//! symmetric reader to the §9.8b producer: `format.parseHeader` /
//! `parseFuncMeta` / `parseReloc` index the fixed-shape sections.
//!
//! **Divergence (vs v1, per §12.1 survey)**: the `.cwasm` file stays
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
    /// Imported-function count; `entry`/`resolveEntry` index defined
    /// funcs (wasm idx - n_imports).
    n_imports: u32,
    allocator: Allocator,

    pub fn deinit(self: *LoadedModule) void {
        for (self.exports) |e| self.allocator.free(e.name);
        self.allocator.free(self.exports);
        self.allocator.free(self.func_offsets);
        jit_mem.free(self.block);
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
    if (h.code_size == 0) return Error.TruncatedImage; // nothing executable to load

    // Exports section (v0.2): dup names into allocator-owned memory so
    // they outlive `bytes` (which the caller may free after `load`).
    const exports = try parseExports(allocator, bytes, h);
    errdefer {
        for (exports) |e| allocator.free(e.name);
        allocator.free(exports);
    }

    // Allocate the executable block, copy the code section in (W^X:
    // writable while copying/patching, executable before any entry call).
    var block = try jit_mem.alloc(h.code_size);
    errdefer jit_mem.free(block);
    try jit_mem.setWritable(block);
    @memcpy(block.bytes[0..h.code_size], bytes[h.code_offset..][0..h.code_size]);

    // Per-defined-function code offsets from the metadata section.
    const func_offsets = try allocator.alloc(u32, h.n_funcs);
    errdefer allocator.free(func_offsets);
    for (0..h.n_funcs) |i| {
        const off = h.metadata_offset + @as(u32, @intCast(i)) * format.func_meta_size;
        const meta = try format.parseFuncMeta(bytes[off..][0..format.func_meta_size]);
        func_offsets[i] = meta.code_offset;
    }

    try applyRelocs(block, func_offsets, bytes, h);

    try jit_mem.setExecutable(block);
    return .{
        .block = block,
        .func_offsets = func_offsets,
        .exports = exports,
        .n_imports = h.n_imports,
        .allocator = allocator,
    };
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
