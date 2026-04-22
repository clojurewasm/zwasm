// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Module cache — serializes predecoded IR to disk for fast startup.
//!
//! Cache format (little-endian):
//!   Magic: "ZWCACHE\x00" (8 bytes)
//!   Version: u32
//!   Wasm hash: [32]u8 (SHA-256)
//!   Num functions: u32
//!   Per function:
//!     Code length: u32 (number of PreInstr)
//!     Pool64 length: u32 (number of u64)
//!     Code: [code_len * 8]u8 (raw PreInstr bytes)
//!     Pool64: [pool_len * 8]u8 (raw u64 bytes)
//!
//! Functions with no IR (predecode failed) are stored as code_len=0, pool_len=0.

const std = @import("std");
const Allocator = std.mem.Allocator;
const predecode_mod = @import("predecode.zig");
const PreInstr = predecode_mod.PreInstr;
const IrFunc = predecode_mod.IrFunc;
const platform = @import("platform.zig");

pub const MAGIC: [8]u8 = "ZWCACHE\x00".*;
pub const VERSION: u32 = 1;

/// Serialize predecoded IR for all functions to a byte buffer.
/// `ir_funcs` contains one entry per code-section function (null = no IR).
pub fn serialize(alloc: Allocator, wasm_hash: [32]u8, ir_funcs: []const ?*const IrFunc) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    // Header
    try buf.appendSlice(alloc, &MAGIC);
    try buf.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, VERSION)));
    try buf.appendSlice(alloc, &wasm_hash);
    const num_funcs: u32 = @intCast(ir_funcs.len);
    try buf.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, num_funcs)));

    // Per-function data
    for (ir_funcs) |ir_opt| {
        if (ir_opt) |ir| {
            const code_len: u32 = @intCast(ir.code.len);
            const pool_len: u32 = @intCast(ir.pool64.len);
            try buf.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, code_len)));
            try buf.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, pool_len)));
            // PreInstr is extern struct (8 bytes), safe to cast to bytes
            const code_bytes: [*]const u8 = @ptrCast(ir.code.ptr);
            try buf.appendSlice(alloc, code_bytes[0 .. code_len * @sizeOf(PreInstr)]);
            if (pool_len > 0) {
                const pool_bytes: [*]const u8 = @ptrCast(ir.pool64.ptr);
                try buf.appendSlice(alloc, pool_bytes[0 .. pool_len * @sizeOf(u64)]);
            }
        } else {
            // No IR for this function
            try buf.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, 0)));
            try buf.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, 0)));
        }
    }

    return buf.toOwnedSlice(alloc);
}

/// Deserialize cached IR from bytes. Returns array of IrFunc pointers (null = no IR).
/// Caller owns returned IrFunc allocations.
pub fn deserialize(alloc: Allocator, data: []const u8, expected_hash: [32]u8) !?[]?*IrFunc {
    if (data.len < 48) return null; // header too short (8 + 4 + 32 + 4)

    // Validate magic
    if (!std.mem.eql(u8, data[0..8], &MAGIC)) return null;

    // Validate version
    const version = std.mem.littleToNative(u32, @as(*const u32, @alignCast(@ptrCast(data[8..12]))).*);
    if (version != VERSION) return null;

    // Validate hash
    if (!std.mem.eql(u8, data[12..44], &expected_hash)) return null;

    const num_funcs = std.mem.littleToNative(u32, @as(*const u32, @alignCast(@ptrCast(data[44..48]))).*);

    var result = try alloc.alloc(?*IrFunc, num_funcs);
    errdefer {
        for (result) |ir_opt| {
            if (ir_opt) |ir| {
                var ir_mut = ir;
                ir_mut.deinit();
                alloc.destroy(ir_mut);
            }
        }
        alloc.free(result);
    }

    var offset: usize = 48;
    for (0..num_funcs) |i| {
        if (offset + 8 > data.len) {
            // Truncated — free what we have and return null
            for (result[0..i]) |ir_opt| {
                if (ir_opt) |ir| {
                    var ir_mut = ir;
                    ir_mut.deinit();
                    alloc.destroy(ir_mut);
                }
            }
            alloc.free(result);
            return null;
        }

        const code_len = std.mem.littleToNative(u32, @as(*const u32, @alignCast(@ptrCast(data[offset..][0..4]))).*);
        const pool_len = std.mem.littleToNative(u32, @as(*const u32, @alignCast(@ptrCast(data[offset + 4 ..][0..4]))).*);
        offset += 8;

        if (code_len == 0 and pool_len == 0) {
            result[i] = null;
            continue;
        }

        const code_bytes = code_len * @sizeOf(PreInstr);
        const pool_bytes = pool_len * @sizeOf(u64);
        if (offset + code_bytes + pool_bytes > data.len) {
            for (result[0..i]) |ir_opt| {
                if (ir_opt) |ir| {
                    var ir_mut = ir;
                    ir_mut.deinit();
                    alloc.destroy(ir_mut);
                }
            }
            alloc.free(result);
            return null;
        }

        // Allocate IrFunc
        const ir = try alloc.create(IrFunc);
        ir.alloc = alloc;

        // Copy code
        ir.code = try alloc.alloc(PreInstr, code_len);
        const dst_code_bytes: [*]u8 = @ptrCast(ir.code.ptr);
        @memcpy(dst_code_bytes[0..code_bytes], data[offset..][0..code_bytes]);
        offset += code_bytes;

        // Copy pool64
        if (pool_len > 0) {
            ir.pool64 = try alloc.alloc(u64, pool_len);
            const dst_pool_bytes: [*]u8 = @ptrCast(ir.pool64.ptr);
            @memcpy(dst_pool_bytes[0..pool_bytes], data[offset..][0..pool_bytes]);
            offset += pool_bytes;
        } else {
            ir.pool64 = &.{};
        }

        result[i] = ir;
    }

    return result;
}

/// Compute SHA-256 hash of wasm binary.
pub fn wasmHash(wasm_bin: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wasm_bin, &hash, .{});
    return hash;
}

/// Get cache directory path (~/.cache/zwasm/). Creates it if needed.
/// Returns owned slice. Caller must free.
pub fn getCacheDir(alloc: Allocator) ![]u8 {
    const path = try platform.appCacheDir(alloc, "zwasm");
    // Ensure directory exists
    var io_instance: std.Io.Threaded = undefined;
    const io = io_instance.io();
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            alloc.free(path);
            return error.NoCacheDir;
        },
    };
    return path;
}

/// Get cache file path for a given wasm hash.
/// Returns owned slice. Caller must free.
pub fn getCachePath(alloc: Allocator, hash: [32]u8) ![]u8 {
    const dir = try getCacheDir(alloc);
    defer alloc.free(dir);
    // Format hash as hex string
    var hex: [64]u8 = undefined;
    for (hash, 0..) |byte, idx| {
        const chars = "0123456789abcdef";
        hex[idx * 2] = chars[byte >> 4];
        hex[idx * 2 + 1] = chars[byte & 0x0f];
    }
    return std.fmt.allocPrint(alloc, "{s}/{s}.zwcache", .{ dir, hex });
}

/// Save serialized cache to disk.
pub fn saveToFile(alloc: Allocator, hash: [32]u8, ir_funcs: []const ?*const IrFunc) !void {
    const data = try serialize(alloc, hash, ir_funcs);
    defer alloc.free(data);
    const path = try getCachePath(alloc, hash);
    defer alloc.free(path);
    var io_instance: std.Io.Threaded = undefined;
    const io = io_instance.io();
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

/// Load cached IR from disk. Returns null on miss or mismatch.
pub fn loadFromFile(alloc: Allocator, hash: [32]u8) !?[]?*IrFunc {
    const path = getCachePath(alloc, hash) catch return null;
    defer alloc.free(path);
    var io_instance: std.Io.Threaded = undefined;
    const io = io_instance.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > 256 * 1024 * 1024) return null; // sanity limit: 256 MB
    const data = try alloc.alloc(u8, stat.size);
    defer alloc.free(data);
    const bytes_read = try file.readPositionalAll(io, data, 0);
    if (bytes_read != stat.size) return null;
    return deserialize(alloc, data, hash);
}

/// Apply cached IR to WasmFunctions in a store.
/// `funcs` is the store's function list, `num_imports` is the number of imported functions.
/// Cached IR at index i maps to func[num_imports + i].
pub fn applyCachedIr(
    cached: []?*IrFunc,
    funcs: []store_mod.Function,
    num_imports: u32,
) void {
    for (cached, 0..) |ir_opt, i| {
        const func_idx = num_imports + @as(u32, @intCast(i));
        if (func_idx >= funcs.len) break;
        if (ir_opt) |ir| {
            switch (funcs[func_idx].subtype) {
                .wasm_function => |*wf| {
                    if (wf.ir == null and !wf.ir_failed) {
                        wf.ir = ir;
                    }
                },
                else => {},
            }
        }
    }
}

/// Collect IrFuncs from WasmFunctions for serialization.
/// Predecodes any functions that haven't been predecoded yet.
pub fn collectIrFuncs(
    alloc: Allocator,
    funcs: []store_mod.Function,
    num_imports: u32,
) ![]?*const IrFunc {
    const num_code = if (funcs.len > num_imports) funcs.len - num_imports else 0;
    var result = try alloc.alloc(?*const IrFunc, num_code);
    for (0..num_code) |i| {
        const func_idx = num_imports + i;
        switch (funcs[func_idx].subtype) {
            .wasm_function => |*wf| {
                // Predecode if not already done
                if (wf.ir == null and !wf.ir_failed) {
                    wf.ir = predecode_mod.predecode(alloc, wf.code) catch null;
                    if (wf.ir == null) wf.ir_failed = true;
                }
                result[i] = wf.ir;
            },
            else => {
                result[i] = null;
            },
        }
    }
    return result;
}

const store_mod = @import("store.zig");

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "cache — serialize and deserialize empty" {
    const hash = wasmHash("test wasm");

    // No functions
    const empty: []const ?*const IrFunc = &.{};
    const data = try serialize(testing.allocator, hash, empty);
    defer testing.allocator.free(data);

    const result = try deserialize(testing.allocator, data, hash);
    try testing.expect(result != null);
    defer testing.allocator.free(result.?);
    try testing.expectEqual(@as(usize, 0), result.?.len);
}

test "cache — serialize and deserialize with IR" {
    const hash = wasmHash("test wasm 2");

    // Create a test IrFunc
    var code = try testing.allocator.alloc(PreInstr, 3);
    code[0] = .{ .opcode = 0x20, .extra = 0, .operand = 0 }; // local.get 0
    code[1] = .{ .opcode = 0x41, .extra = 0, .operand = 42 }; // i32.const 42
    code[2] = .{ .opcode = 0x6A, .extra = 0, .operand = 0 }; // i32.add

    var pool = try testing.allocator.alloc(u64, 1);
    pool[0] = 0xDEADBEEF_CAFEBABE;

    var ir = IrFunc{
        .code = code,
        .pool64 = pool,
        .alloc = testing.allocator,
    };
    defer ir.deinit();

    const ir_const: *const IrFunc = &ir;
    const funcs: []const ?*const IrFunc = &.{ ir_const, null, ir_const };
    const data = try serialize(testing.allocator, hash, funcs);
    defer testing.allocator.free(data);

    // Deserialize
    const result = (try deserialize(testing.allocator, data, hash)).?;
    defer {
        for (result) |ir_opt| {
            if (ir_opt) |loaded| {
                var m = loaded;
                m.deinit();
                testing.allocator.destroy(m);
            }
        }
        testing.allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 3), result.len);

    // First function: has IR
    try testing.expect(result[0] != null);
    const loaded = result[0].?;
    try testing.expectEqual(@as(usize, 3), loaded.code.len);
    try testing.expectEqual(@as(u16, 0x20), loaded.code[0].opcode);
    try testing.expectEqual(@as(u32, 42), loaded.code[1].operand);
    try testing.expectEqual(@as(usize, 1), loaded.pool64.len);
    try testing.expectEqual(@as(u64, 0xDEADBEEF_CAFEBABE), loaded.pool64[0]);

    // Second function: no IR
    try testing.expect(result[1] == null);

    // Third function: has IR (same as first)
    try testing.expect(result[2] != null);
    try testing.expectEqual(@as(usize, 3), result[2].?.code.len);
}

test "cache — hash mismatch returns null" {
    const hash1 = wasmHash("wasm A");
    const hash2 = wasmHash("wasm B");

    const empty: []const ?*const IrFunc = &.{};
    const data = try serialize(testing.allocator, hash1, empty);
    defer testing.allocator.free(data);

    // Different hash → null
    const result = try deserialize(testing.allocator, data, hash2);
    try testing.expect(result == null);
}

test "cache — invalid magic returns null" {
    var data = [_]u8{0} ** 48;
    data[0] = 'X'; // Wrong magic
    const hash = wasmHash("test");
    const result = try deserialize(testing.allocator, &data, hash);
    try testing.expect(result == null);
}

test "cache — truncated data returns null" {
    const hash = wasmHash("test");
    const short = "ZWCACHE"; // Too short
    const result = try deserialize(testing.allocator, short, hash);
    try testing.expect(result == null);
}
