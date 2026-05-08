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

const Allocator = std.mem.Allocator;
const FuncType = zir.FuncType;

pub const Error = serialise.Error || error{
    ParamCountTooLarge,
    ResultCountTooLarge,
    UnsupportedHostArch,
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
    };

    return serialise.produceCwasm(allocator, input);
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
        0x01, 0x05, 0x01,
        0x60, 0x00, 0x01, 0x7f,
        // Function section: 1 func, type 0
        0x03, 0x02, 0x01, 0x00,
        // Code section: 1 body, locals=0, i32.const 7, end
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x07, 0x0b,
    };

    var compiled = try runner.compileWasm(testing.allocator, &wasm_bytes);
    defer compiled.deinit(testing.allocator);

    const out = try produceFromCompiledWasm(testing.allocator, &compiled);
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
