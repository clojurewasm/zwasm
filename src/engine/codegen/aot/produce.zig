//! `.cwasm` v0.1 producer orchestrator (§9.8b / 8b.3-d per
//! ADR-0039).
//!
//! Takes a `CompiledWasm` (the JIT pipeline's output, per
//! `src/engine/runner.zig:84:compileWasm`) and produces a
//! `.cwasm` byte stream. Bridges the per-func emit outputs
//! (bytes + n_slots + call_fixups) into the arch-blind
//! `Input` shape consumed by `serialise.produceCwasm`.
//!
//! Pipeline reuse per ADR-0039 §"Decision":
//!   wasm bytes
//!   → parse / validate / lower / liveness / regalloc / coalesce / emit
//!   → CompiledWasm { func_results, func_sigs, num_imports, … }
//!   → produceFromCompiledWasm                      (this module)
//!   → serialise.produceCwasm                       (format wrapper)
//!   → .cwasm bytes
//!
//! Zone 2 (`src/engine/codegen/aot/`).

const std = @import("std");
const builtin = @import("builtin");

const format = @import("format.zig");
const serialise = @import("serialise.zig");

const zir = @import("../../../ir/zir.zig");
const runner = @import("../../runner.zig");
const parser = @import("../../../parse/parser.zig");
const sections = @import("../../../parse/sections.zig");
const instantiate = @import("../../../runtime/instance/instantiate.zig");
const runner_validate = @import("../../runner_validate.zig");

const Allocator = std.mem.Allocator;
const FuncType = zir.FuncType;

pub const Error = serialise.Error || error{
    ParamCountTooLarge,
    ResultCountTooLarge,
    UnsupportedHostArch,
    /// A defined global's init-expr is outside the §12.3b cycle-1 subset
    /// (simple i32/i64/f/v128.const + ref.null). ref.func / global.get-import
    /// / struct.new globals are cycle-2 — surfaced loudly, not zero-filled.
    UnsupportedGlobalInit,
    /// Re-parsing `wasm_bytes` for the global/memory sections failed (should
    /// not happen — `compileWasm` already parsed+validated the same bytes).
    GlobalSectionParseFailed,
    /// A memory/data segment is outside the §12.3b cycle-1b subset (a
    /// non-const active-data offset, or a memory larger than the loader cap).
    UnsupportedMemoryState,
};

/// Linear-memory state collected for the producer (v0.3 cycle-1b).
pub const MemoryState = struct {
    has_memory: bool = false,
    min_pages: u32 = 0,
    max_pages: u32 = format.memory_max_none,
    /// Active data segments (offset pre-evaluated); `bytes` alias `wasm_bytes`.
    data: []format.CwasmDataSeg = &.{},
};

/// Produce `.cwasm` bytes for the given CompiledWasm. The
/// arch tag is derived from the host architecture
/// (producer-only-on-matching-arch per ADR-0039 §Alternative
/// D); cross-arch production is a Phase 12+ concern.
///
/// Caller owns the returned slice; pair with `allocator.free`.
pub fn produceFromCompiledWasm(
    allocator: Allocator,
    compiled: *const runner.CompiledWasm,
    wasm_bytes: []const u8,
) Error![]u8 {
    const arch = try hostArch();

    const n_funcs = compiled.func_results.len;

    var bytes_per_func = try allocator.alloc([]const u8, n_funcs);
    defer allocator.free(bytes_per_func);
    var n_slots_per_func = try allocator.alloc(u16, n_funcs);
    defer allocator.free(n_slots_per_func);
    var sig_idx_per_func = try allocator.alloc(u16, n_funcs);
    defer allocator.free(sig_idx_per_func);

    var n_relocs: usize = 0;
    for (compiled.func_results) |r| n_relocs += r.out.call_fixups.len;
    var relocs = try allocator.alloc(format.CwasmReloc, n_relocs);
    defer allocator.free(relocs);
    var func_idx_for_reloc = try allocator.alloc(u32, n_relocs);
    defer allocator.free(func_idx_for_reloc);

    var reloc_w: usize = 0;
    for (compiled.func_results, 0..) |r, defined_idx| {
        bytes_per_func[defined_idx] = r.out.bytes;
        n_slots_per_func[defined_idx] = r.out.n_slots;
        // sig_idx maps to types-section index; v0.1 emits one
        // FuncType per defined function in func-order, so
        // sig_idx == defined_idx.
        sig_idx_per_func[defined_idx] = @intCast(defined_idx);

        const wasm_idx: u32 = @as(u32, @intCast(defined_idx)) + compiled.num_imports;
        // CallFixup shape is identical across arm64 + x86_64
        // (both expose `byte_offset` + `target_func_idx`); we
        // access fields polymorphically rather than naming
        // the type, keeping aot/ arch-blind per A12.
        for (r.out.call_fixups) |cf| {
            relocs[reloc_w] = .{
                .code_offset = cf.byte_offset,
                .target_func_idx = cf.target_func_idx,
                .kind = format.reloc_kind_direct_call,
            };
            func_idx_for_reloc[reloc_w] = wasm_idx;
            reloc_w += 1;
        }
    }

    // Serialise the types section: one FuncType per defined
    // function (v0.1 doesn't dedupe — Phase 12+ may add type
    // hash-consing). Format per ADR-0039 §"Types section":
    //   per FuncType:
    //     u8 params_count
    //     u8 results_count
    //     params_count × u8 (ValType byte: @intFromEnum)
    //     results_count × u8
    var types_buf: std.ArrayList(u8) = .empty;
    defer types_buf.deinit(allocator);
    for (compiled.func_results, 0..) |_, defined_idx| {
        const wasm_idx = compiled.num_imports + @as(u32, @intCast(defined_idx));
        const ty = compiled.func_sigs[wasm_idx];
        if (ty.params.len > std.math.maxInt(u8)) return Error.ParamCountTooLarge;
        if (ty.results.len > std.math.maxInt(u8)) return Error.ResultCountTooLarge;
        try types_buf.append(allocator, @intCast(ty.params.len));
        try types_buf.append(allocator, @intCast(ty.results.len));
        for (ty.params) |p| try types_buf.append(allocator, @intFromEnum(p));
        for (ty.results) |rs| try types_buf.append(allocator, @intFromEnum(rs));
    }

    // Map the func-export table → the format's export shape (identical
    // fields). produceCwasm copies names into the output, so this temp
    // can be freed after; the source names are arena-owned by `compiled`.
    var exports = try allocator.alloc(format.CwasmExport, compiled.exports.len);
    defer allocator.free(exports);
    for (compiled.exports, 0..) |e, i| {
        exports[i] = .{ .name = e.name, .func_idx = e.func_idx };
    }

    // Pre-evaluate defined-global init values (v0.3 §12.3b) so the loader
    // reconstructs `globals_base` by memcpy, no init-expr eval at load.
    const globals = try collectGlobalInits(allocator, wasm_bytes);
    defer allocator.free(globals);

    // Linear memory (v0.3 cycle-1b): min/max pages + active data segments
    // (offsets pre-evaluated). `mem.data` bytes alias `wasm_bytes`.
    const mem = try collectMemory(allocator, wasm_bytes);
    defer allocator.free(mem.data);

    const input: serialise.Input = .{
        .arch = arch,
        .bytes_per_func = bytes_per_func,
        .n_slots_per_func = n_slots_per_func,
        .sig_idx_per_func = sig_idx_per_func,
        .relocs = relocs,
        .func_idx_for_reloc = func_idx_for_reloc,
        .types_serialised = types_buf.items,
        .n_imports = compiled.num_imports,
        .n_types = @intCast(n_funcs),
        .exports = exports,
        .globals = globals,
        .has_memory = mem.has_memory,
        .mem_min_pages = mem.min_pages,
        .mem_max_pages = mem.max_pages,
        .mem_data = mem.data,
    };

    return serialise.produceCwasm(allocator, input);
}

/// Evaluate each DEFINED global's init-expr into its 16-byte `Value` bits
/// (v0.3 §12.3b). Re-parses `wasm_bytes` for the global section (a one-time
/// generator cost; mirrors `setup.setupRuntime`'s eval). Returns an empty
/// slice for modules with no global section. Cycle-1 handles simple const
/// inits only — `ref.func` / `global.get` / `struct.new` globals (which need
/// func_entities / imported-global values / a GC heap) surface as
/// `UnsupportedGlobalInit` (cycle-2), never silently zero-filled.
fn collectGlobalInits(allocator: Allocator, wasm_bytes: []const u8) Error![]u128 {
    var module = parser.parse(allocator, wasm_bytes) catch return Error.GlobalSectionParseFailed;
    defer module.deinit(allocator);

    const gs = module.find(.global) orelse return allocator.alloc(u128, 0);
    var globals = sections.decodeGlobals(allocator, gs.body) catch return Error.GlobalSectionParseFailed;
    defer globals.deinit();

    const out = try allocator.alloc(u128, globals.items.len);
    errdefer allocator.free(out);
    for (globals.items, 0..) |gd, i| {
        const v = instantiate.evalConstExprValue(gd.init_expr) catch return Error.UnsupportedGlobalInit;
        out[i] = v.bits128;
    }
    return out;
}

/// Page-count cap mirroring `setup.zig`'s 256 MiB ceiling (256 MiB / 64 KiB).
const max_min_pages: u32 = 256 * 1024 * 1024 / 65536;

/// Collect linear-memory state (v0.3 cycle-1b): min/max pages + ACTIVE data
/// segments with offsets pre-evaluated (`runner_validate.evalConstOffsetU64`,
/// mirroring `setup.zig`). Passive segments are deferred (memory.init =
/// cycle-2). `data` bytes alias `wasm_bytes` (borrowed by the parser), so the
/// returned segs stay valid for the `produceCwasm` copy. Caller frees `.data`.
fn collectMemory(allocator: Allocator, wasm_bytes: []const u8) Error!MemoryState {
    var module = parser.parse(allocator, wasm_bytes) catch return Error.GlobalSectionParseFailed;
    defer module.deinit(allocator);

    var st: MemoryState = .{};
    if (module.find(.memory)) |s| {
        var memories = sections.decodeMemory(allocator, s.body) catch return Error.GlobalSectionParseFailed;
        defer memories.deinit();
        if (memories.items.len > 0) {
            const m0 = memories.items[0];
            if (m0.min > max_min_pages) return Error.UnsupportedMemoryState;
            st.has_memory = true;
            st.min_pages = @intCast(m0.min);
            st.max_pages = if (m0.max) |mx| (if (mx > std.math.maxInt(u32)) format.memory_max_none else @intCast(mx)) else format.memory_max_none;
        }
    }
    if (!st.has_memory) return st;

    if (module.find(.data)) |s| {
        var datas = sections.decodeData(allocator, s.body) catch return Error.GlobalSectionParseFailed;
        defer datas.deinit();
        var list: std.ArrayList(format.CwasmDataSeg) = .empty;
        errdefer list.deinit(allocator);
        for (datas.items) |seg| {
            if (seg.kind != .active) continue; // passive → memory.init (cycle-2)
            const off = runner_validate.evalConstOffsetU64(seg.offset_expr) catch return Error.UnsupportedMemoryState;
            if (off > std.math.maxInt(u32)) return Error.UnsupportedMemoryState;
            try list.append(allocator, .{ .mem_offset = @intCast(off), .bytes = seg.bytes });
        }
        st.data = try list.toOwnedSlice(allocator);
    }
    return st;
}

/// Map host arch → `.cwasm` arch tag. Producer-only-on-matching-
/// arch per ADR-0039.
pub fn hostArch() Error!u32 {
    return switch (builtin.target.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => Error.UnsupportedHostArch,
    };
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "hostArch maps to a valid .cwasm arch tag on supported hosts" {
    if (builtin.target.cpu.arch == .aarch64 or builtin.target.cpu.arch == .x86_64) {
        const a = try hostArch();
        try testing.expect(a == format.arch_arm64 or a == format.arch_x86_64);
    } else {
        try testing.expectError(Error.UnsupportedHostArch, hostArch());
    }
}

test "produceFromCompiledWasm: tiny synthetic wasm round-trips through compileWasm + AOT producer" {
    // Synthetic wasm: () -> i32 returning 7.
    // Module sections: type, function, code.
    const wasm_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // \0asm
        0x01, 0x00, 0x00, 0x00, // version 1
        // Type section: 1 entry, () -> i32
        0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f,
        // Function section: 1 func, type 0
        0x03,
        0x02, 0x01, 0x00,
        // Code section: 1 body, locals=0, i32.const 7, end
        0x0a,
        0x06, 0x01, 0x04, 0x00,
        0x41, 0x07, 0x0b,
    };

    var compiled = try runner.compileWasm(testing.allocator, &wasm_bytes);
    defer compiled.deinit(testing.allocator);

    const out = try produceFromCompiledWasm(testing.allocator, &compiled, &wasm_bytes);
    defer testing.allocator.free(out);

    const h = try format.parseHeader(out[0..format.header_size]);
    try testing.expectEqual(@as(u32, 1), h.n_funcs);
    try testing.expectEqual(@as(u32, 1), h.n_types);
    try testing.expectEqual(@as(u32, 0), h.n_imports);
    const expected_arch = try hostArch();
    try testing.expectEqual(expected_arch, h.arch);

    // Per-func metadata.
    const meta = try format.parseFuncMeta(out[h.metadata_offset..][0..format.func_meta_size]);
    try testing.expectEqual(@as(u32, 0), meta.code_offset);
    try testing.expect(meta.code_size > 0);
    try testing.expectEqual(@as(u16, 0), meta.sig_idx);

    // Types section: 1 FuncType encoded as `params_count=0,
    // results_count=1, results=[i32 byte]`.
    const types_slice = out[h.types_offset..][0..h.types_size];
    try testing.expectEqual(@as(usize, 3), types_slice.len);
    try testing.expectEqual(@as(u8, 0), types_slice[0]); // 0 params
    try testing.expectEqual(@as(u8, 1), types_slice[1]); // 1 result
    try testing.expectEqual(@as(u8, @intFromEnum(zir.ValType.i32)), types_slice[2]);

    // Code bytes: ARM64 emits a non-empty function body for
    // `(func (result i32) (i32.const 7))`. Just assert
    // non-zero length matching meta.code_size.
    const code_slice = out[h.code_offset..][0..meta.code_size];
    try testing.expect(code_slice.len > 0);
}
