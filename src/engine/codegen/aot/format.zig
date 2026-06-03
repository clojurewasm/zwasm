//! `.cwasm` v0.1 binary format types + write/parse helpers
//! (§9.8b / 8b.3-c per ADR-0039).
//!
//! Inline-bytes container: header + per-func metadata +
//! types + relocs + code sections in one file. Producer-only
//! on matching arch (cross-arch deferred to Phase 12+ per
//! ADR-0039 §"Alternative D"). Phase 12's loader reads via
//! the symmetric `parseHeader` / `parseFuncMeta` /
//! `parseReloc` helpers.
//!
//! All multi-byte fields are little-endian. The header is
//! exactly **60 bytes** (ADR-0039's "56 bytes" was an
//! arithmetic miscount; corrected by ADR-0039 Revision 2);
//! per-func metadata is exactly 12 bytes per entry; relocs
//! are 9 bytes each (4 + 4 + 1, packed). All three are
//! fixed-shape so the loader can mmap the file and index
//! sections without sequential parsing.
//!
//! Zone 2 (`src/engine/codegen/aot/`). Class-blind +
//! arch-blind: the arch tag in the header identifies which
//! backend produced the code section, but this module
//! itself doesn't import from `arm64/` or `x86_64/`. The
//! producer (`compile.zig`) supplies the arch tag.

const std = @import("std");

pub const magic = [4]u8{ 'C', 'W', 'A', 'S' };
pub const version_v0_1: u32 = 0x0001_0000; // (major << 16) | minor — superseded
pub const version_v0_2: u32 = 0x0002_0000; // current: adds the exports section (ADR-0138)

pub const arch_arm64: u32 = 1;
pub const arch_x86_64: u32 = 2;

pub const header_size: u32 = 68; // v0.2: 60 (v0.1) + exports_offset + exports_size (ADR-0138)
pub const func_meta_size: u32 = 12;
pub const reloc_size: u32 = 9; // 4 + 4 + 1 (no padding)
pub const reloc_kind_direct_call: u8 = 0;

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    UnknownArch,
    TruncatedHeader,
    TruncatedFuncMeta,
    TruncatedReloc,
    TruncatedExport,
};

/// Top-level container header (per ADR-0039 + Revision 2; v0.2 per
/// ADR-0138). 68 bytes; field offsets are stable for v0.2.
pub const CwasmHeader = struct {
    arch: u32, // arch_arm64 | arch_x86_64
    flags: u32 = 0, // reserved (debug info, signing, …)
    n_funcs: u32,
    n_types: u32,
    n_imports: u32,
    code_offset: u32,
    code_size: u32,
    metadata_offset: u32,
    metadata_size: u32,
    types_offset: u32,
    types_size: u32,
    relocs_offset: u32,
    relocs_size: u32,
    // v0.2 (ADR-0138): exports section so a loaded `.cwasm` resolves
    // entry points by name without re-parsing the original `.wasm`.
    exports_offset: u32 = 0,
    exports_size: u32 = 0,
};

/// One entry in the exports section (v0.2). Func-kind exports only —
/// `zwasm run` invokes functions. On parse, `name` aliases into the
/// source buffer; on write, `name` is caller-owned.
pub const CwasmExport = struct {
    name: []const u8,
    func_idx: u32, // wasm-space function index (imports included)
};

/// Per-function metadata entry. 12 bytes; emitted in
/// `func_idx` order so the loader can index by `func_idx *
/// func_meta_size`.
pub const CwasmFuncMeta = struct {
    code_offset: u32, // offset within code section
    code_size: u32, // bytes of machine code for this func
    n_slots: u16, // regalloc.Allocation.n_slots (frame sizing)
    sig_idx: u16, // index into types section
};

/// Reloc entry: a call-site within the code section that
/// must be patched at load time once function-body
/// addresses are known. Mirrors `arm64/ctx.CallFixup` shape
/// but with an explicit `kind` byte for forward-compat
/// (Phase 12+ may add additional reloc kinds for indirect-
/// call, table-base, etc.).
pub const CwasmReloc = struct {
    code_offset: u32,
    target_func_idx: u32,
    kind: u8, // reloc_kind_direct_call (0) for v0.1
};

// =====================================================================
// Header serialisation
// =====================================================================

pub fn writeHeader(buf: []u8, h: CwasmHeader) Error!void {
    if (buf.len < header_size) return Error.TruncatedHeader;
    @memcpy(buf[0..4], &magic);
    std.mem.writeInt(u32, buf[4..8], version_v0_2, .little);
    std.mem.writeInt(u32, buf[8..12], h.arch, .little);
    std.mem.writeInt(u32, buf[12..16], h.flags, .little);
    std.mem.writeInt(u32, buf[16..20], h.n_funcs, .little);
    std.mem.writeInt(u32, buf[20..24], h.n_types, .little);
    std.mem.writeInt(u32, buf[24..28], h.n_imports, .little);
    std.mem.writeInt(u32, buf[28..32], h.code_offset, .little);
    std.mem.writeInt(u32, buf[32..36], h.code_size, .little);
    std.mem.writeInt(u32, buf[36..40], h.metadata_offset, .little);
    std.mem.writeInt(u32, buf[40..44], h.metadata_size, .little);
    std.mem.writeInt(u32, buf[44..48], h.types_offset, .little);
    std.mem.writeInt(u32, buf[48..52], h.types_size, .little);
    std.mem.writeInt(u32, buf[52..56], h.relocs_offset, .little);
    std.mem.writeInt(u32, buf[56..60], h.relocs_size, .little);
    std.mem.writeInt(u32, buf[60..64], h.exports_offset, .little);
    std.mem.writeInt(u32, buf[64..68], h.exports_size, .little);
}

pub fn parseHeader(buf: []const u8) Error!CwasmHeader {
    if (buf.len < header_size) return Error.TruncatedHeader;
    if (!std.mem.eql(u8, buf[0..4], &magic)) return Error.BadMagic;
    const version = std.mem.readInt(u32, buf[4..8], .little);
    if (version != version_v0_2) return Error.UnsupportedVersion;
    const arch = std.mem.readInt(u32, buf[8..12], .little);
    if (arch != arch_arm64 and arch != arch_x86_64) return Error.UnknownArch;
    return .{
        .arch = arch,
        .flags = std.mem.readInt(u32, buf[12..16], .little),
        .n_funcs = std.mem.readInt(u32, buf[16..20], .little),
        .n_types = std.mem.readInt(u32, buf[20..24], .little),
        .n_imports = std.mem.readInt(u32, buf[24..28], .little),
        .code_offset = std.mem.readInt(u32, buf[28..32], .little),
        .code_size = std.mem.readInt(u32, buf[32..36], .little),
        .metadata_offset = std.mem.readInt(u32, buf[36..40], .little),
        .metadata_size = std.mem.readInt(u32, buf[40..44], .little),
        .types_offset = std.mem.readInt(u32, buf[44..48], .little),
        .types_size = std.mem.readInt(u32, buf[48..52], .little),
        .relocs_offset = std.mem.readInt(u32, buf[52..56], .little),
        .relocs_size = std.mem.readInt(u32, buf[56..60], .little),
        .exports_offset = std.mem.readInt(u32, buf[60..64], .little),
        .exports_size = std.mem.readInt(u32, buf[64..68], .little),
    };
}

// =====================================================================
// Exports section serialisation (v0.2 per ADR-0138)
// =====================================================================
//
// Layout: [n_exports: u32] then n_exports entries, each
//   [name_len: u32][name: name_len bytes][func_idx: u32].

/// Serialised byte size of one export entry.
pub fn exportEntrySize(name_len: usize) usize {
    return 4 + name_len + 4;
}

/// Write one export entry at the start of `buf`; returns bytes written.
pub fn writeExportEntry(buf: []u8, e: CwasmExport) Error!usize {
    const need = exportEntrySize(e.name.len);
    if (buf.len < need) return Error.TruncatedExport;
    std.mem.writeInt(u32, buf[0..4], @intCast(e.name.len), .little);
    @memcpy(buf[4..][0..e.name.len], e.name);
    std.mem.writeInt(u32, buf[4 + e.name.len ..][0..4], e.func_idx, .little);
    return need;
}

/// Parse one export entry at the start of `buf`. The returned `name`
/// aliases into `buf`. `consumed` is the entry's byte length.
pub fn parseExportEntry(buf: []const u8) Error!struct { exp: CwasmExport, consumed: usize } {
    if (buf.len < 8) return Error.TruncatedExport; // name_len + func_idx minimum
    const name_len = std.mem.readInt(u32, buf[0..4], .little);
    const need = exportEntrySize(name_len);
    if (buf.len < need) return Error.TruncatedExport;
    return .{
        .exp = .{
            .name = buf[4..][0..name_len],
            .func_idx = std.mem.readInt(u32, buf[4 + name_len ..][0..4], .little),
        },
        .consumed = need,
    };
}

// =====================================================================
// Per-func metadata serialisation
// =====================================================================

pub fn writeFuncMeta(buf: []u8, m: CwasmFuncMeta) Error!void {
    if (buf.len < func_meta_size) return Error.TruncatedFuncMeta;
    std.mem.writeInt(u32, buf[0..4], m.code_offset, .little);
    std.mem.writeInt(u32, buf[4..8], m.code_size, .little);
    std.mem.writeInt(u16, buf[8..10], m.n_slots, .little);
    std.mem.writeInt(u16, buf[10..12], m.sig_idx, .little);
}

pub fn parseFuncMeta(buf: []const u8) Error!CwasmFuncMeta {
    if (buf.len < func_meta_size) return Error.TruncatedFuncMeta;
    return .{
        .code_offset = std.mem.readInt(u32, buf[0..4], .little),
        .code_size = std.mem.readInt(u32, buf[4..8], .little),
        .n_slots = std.mem.readInt(u16, buf[8..10], .little),
        .sig_idx = std.mem.readInt(u16, buf[10..12], .little),
    };
}

// =====================================================================
// Reloc serialisation
// =====================================================================

pub fn writeReloc(buf: []u8, r: CwasmReloc) Error!void {
    if (buf.len < reloc_size) return Error.TruncatedReloc;
    std.mem.writeInt(u32, buf[0..4], r.code_offset, .little);
    std.mem.writeInt(u32, buf[4..8], r.target_func_idx, .little);
    buf[8] = r.kind;
}

pub fn parseReloc(buf: []const u8) Error!CwasmReloc {
    if (buf.len < reloc_size) return Error.TruncatedReloc;
    return .{
        .code_offset = std.mem.readInt(u32, buf[0..4], .little),
        .target_func_idx = std.mem.readInt(u32, buf[4..8], .little),
        .kind = buf[8],
    };
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "writeHeader/parseHeader: round-trip preserves all fields" {
    const want: CwasmHeader = .{
        .arch = arch_arm64,
        .flags = 0,
        .n_funcs = 3,
        .n_types = 2,
        .n_imports = 1,
        .code_offset = 200,
        .code_size = 300,
        .metadata_offset = 60,
        .metadata_size = 36,
        .types_offset = 96,
        .types_size = 50,
        .relocs_offset = 146,
        .relocs_size = 27,
        .exports_offset = 173,
        .exports_size = 19,
    };
    var buf: [header_size]u8 = undefined;
    try writeHeader(&buf, want);
    const got = try parseHeader(&buf);
    try testing.expectEqual(want, got);
}

test "writeHeader/parseHeader: arch_x86_64 round-trips" {
    const want: CwasmHeader = .{
        .arch = arch_x86_64,
        .n_funcs = 1,
        .n_types = 1,
        .n_imports = 0,
        .code_offset = 60,
        .code_size = 16,
        .metadata_offset = 76,
        .metadata_size = 12,
        .types_offset = 88,
        .types_size = 4,
        .relocs_offset = 92,
        .relocs_size = 0,
    };
    var buf: [header_size]u8 = undefined;
    try writeHeader(&buf, want);
    const got = try parseHeader(&buf);
    try testing.expectEqual(want, got);
}

test "parseHeader: rejects bad magic" {
    var buf: [header_size]u8 = undefined;
    @memset(&buf, 0xAA);
    try testing.expectError(Error.BadMagic, parseHeader(&buf));
}

test "parseHeader: rejects unsupported version" {
    var buf: [header_size]u8 = undefined;
    @memcpy(buf[0..4], &magic);
    std.mem.writeInt(u32, buf[4..8], 0x0003_0000, .little); // v0.3 (future, unsupported)
    @memset(buf[8..], 0);
    try testing.expectError(Error.UnsupportedVersion, parseHeader(&buf));
}

test "parseHeader: rejects the superseded v0.1 version" {
    var buf: [header_size]u8 = undefined;
    @memcpy(buf[0..4], &magic);
    std.mem.writeInt(u32, buf[4..8], version_v0_1, .little);
    @memset(buf[8..], 0);
    try testing.expectError(Error.UnsupportedVersion, parseHeader(&buf));
}

test "parseHeader: rejects unknown arch" {
    var buf: [header_size]u8 = undefined;
    @memcpy(buf[0..4], &magic);
    std.mem.writeInt(u32, buf[4..8], version_v0_2, .little);
    std.mem.writeInt(u32, buf[8..12], 99, .little); // unknown arch
    @memset(buf[12..], 0);
    try testing.expectError(Error.UnknownArch, parseHeader(&buf));
}

test "parseHeader: rejects truncated buffer" {
    var buf: [header_size - 1]u8 = undefined;
    try testing.expectError(Error.TruncatedHeader, parseHeader(&buf));
}

test "writeFuncMeta/parseFuncMeta: round-trip preserves all fields" {
    const want: CwasmFuncMeta = .{
        .code_offset = 0x1234_5678,
        .code_size = 0x0042_0000,
        .n_slots = 7,
        .sig_idx = 2,
    };
    var buf: [func_meta_size]u8 = undefined;
    try writeFuncMeta(&buf, want);
    const got = try parseFuncMeta(&buf);
    try testing.expectEqual(want, got);
}

test "parseFuncMeta: rejects truncated buffer" {
    var buf: [func_meta_size - 1]u8 = undefined;
    try testing.expectError(Error.TruncatedFuncMeta, parseFuncMeta(&buf));
}

test "writeReloc/parseReloc: round-trip preserves all fields" {
    const want: CwasmReloc = .{
        .code_offset = 64,
        .target_func_idx = 3,
        .kind = reloc_kind_direct_call,
    };
    var buf: [reloc_size]u8 = undefined;
    try writeReloc(&buf, want);
    const got = try parseReloc(&buf);
    try testing.expectEqual(want, got);
}

test "parseReloc: rejects truncated buffer" {
    var buf: [reloc_size - 1]u8 = undefined;
    try testing.expectError(Error.TruncatedReloc, parseReloc(&buf));
}

test "header_size + func_meta_size + reloc_size constants are stable" {
    try testing.expectEqual(@as(u32, 68), header_size); // v0.2 (ADR-0138)
    try testing.expectEqual(@as(u32, 12), func_meta_size);
    try testing.expectEqual(@as(u32, 9), reloc_size);
}

test "writeExportEntry/parseExportEntry: round-trip preserves name + func_idx" {
    const want: CwasmExport = .{ .name = "_start", .func_idx = 3 };
    var buf: [64]u8 = undefined;
    const written = try writeExportEntry(&buf, want);
    try testing.expectEqual(exportEntrySize(want.name.len), written);

    const got = try parseExportEntry(buf[0..written]);
    try testing.expectEqual(written, got.consumed);
    try testing.expectEqualStrings(want.name, got.exp.name);
    try testing.expectEqual(want.func_idx, got.exp.func_idx);
}

test "parseExportEntry: rejects a buffer truncated mid-name" {
    var buf: [64]u8 = undefined;
    _ = try writeExportEntry(&buf, .{ .name = "main", .func_idx = 0 });
    // Lop off the trailing func_idx + one name byte.
    try testing.expectError(Error.TruncatedExport, parseExportEntry(buf[0..6]));
}
