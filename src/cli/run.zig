//! `zwasm run` CLI helper (Phase 4 / §9.4 / 4.8 chunk a).
//!
//! Houses `runWasm` — the Zig-callable entry that drives a
//! WASI-importing module from in-memory bytes through to a
//! u8 exit code. The CLI argv-parsing wrapper lives in
//! `src/main.zig` and lands alongside §9.4 / 4.8 chunk b.
//!
//! Zone 3 — may import `c_api/`. CLI is conventionally where
//! the binding's exported surface gets driven from Zig
//! (functions are declared `export fn` for C linkage but
//! remain ordinary Zig functions, callable here).
//!
//! Exit-code mapping:
//!   - guest returns normally     → 0
//!   - guest calls `proc_exit(N)` → N
//!   - guest traps (other)        → 1

const std = @import("std");

const wasm_c_api = @import("../c_api/wasm_c_api.zig");
const diagnostic = @import("../runtime/diagnostic.zig");

pub fn runWasm(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
) !u8 {
    return runWasmCaptured(alloc, io, bytes, argv, null);
}

/// Like `runWasm` but routes guest stdout writes (`fd_write`
/// to fd 1) into the caller-supplied `stdout_capture`. When
/// non-null, the runner wires `host.stdout_buffer` to it; the
/// caller owns the buffer and must release it. The realworld-
/// diff runner (§9.6 / 6.F) uses this to byte-compare against
/// wasmtime's stdout for the same fixture.
///
/// `argv` is forwarded to the WASI host via `setArgs`; conventional
/// WASI guests expect `argv[0]` to be the program name (matching
/// wasmtime's default of using the wasm filename). Pass `&.{}` for
/// "no args" — empty argv yields argc=0.
pub fn runWasmCaptured(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
    stdout_capture: ?*std.ArrayList(u8),
) !u8 {
    _ = alloc; // engine + store own their own c_allocator paths

    // Per ADR-0016 phase 1: clear any stale diagnostic from a
    // previous call before populating a fresh one on failure.
    diagnostic.clearDiag();

    const engine = wasm_c_api.wasm_engine_new() orelse {
        diagnostic.setDiag(.instantiate, .engine_alloc_failed, .unknown, "engine allocation failed", .{});
        return error.EngineAllocFailed;
    };
    defer wasm_c_api.wasm_engine_delete(engine);
    const store = wasm_c_api.wasm_store_new(engine) orelse {
        diagnostic.setDiag(.instantiate, .store_alloc_failed, .unknown, "store allocation failed", .{});
        return error.StoreAllocFailed;
    };
    defer wasm_c_api.wasm_store_delete(store);

    // Configure the WASI host. The CLI threading of args /
    // environ / preopens lands in chunk b; for chunk a the host
    // is the bare default + an io context for path_open / clock /
    // random.
    const cfg = wasm_c_api.zwasm_wasi_config_new() orelse {
        diagnostic.setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi config allocation failed", .{});
        return error.ConfigAllocFailed;
    };
    cfg.io = io;
    if (stdout_capture) |buf| cfg.stdout_buffer = buf;
    if (argv.len > 0) cfg.setArgs(argv) catch {
        diagnostic.setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi argv allocation failed", .{});
        wasm_c_api.zwasm_wasi_config_delete(cfg);
        return error.ConfigAllocFailed;
    };
    wasm_c_api.zwasm_store_set_wasi(store, cfg);

    var bv: wasm_c_api.ByteVec = .{
        .size = bytes.len,
        .data = @constCast(bytes.ptr),
    };
    const module = wasm_c_api.wasm_module_new(store, &bv) orelse {
        diagnostic.setDiag(.instantiate, .module_alloc_failed, .unknown, "module decode/validate failed (no further detail in phase 1)", .{});
        return error.ModuleAllocFailed;
    };
    defer wasm_c_api.wasm_module_delete(module);

    const instance = wasm_c_api.wasm_instance_new(store, module, null, null) orelse {
        diagnostic.setDiag(.instantiate, .instance_alloc_failed, .unknown, "instantiation failed (no further detail in phase 1)", .{});
        return error.InstanceAllocFailed;
    };
    defer wasm_c_api.wasm_instance_delete(instance);

    // Locate the entry export. WASI guests conventionally export
    // `_start`; our fixtures + hand-rolled hello-worlds also use
    // `main`. Prefer `_start` when present; otherwise fall back
    // to the first export.
    const entry_idx = blk: {
        for (instance.exports_storage, 0..) |exp, i| {
            if (exp.kind == .func and std.mem.eql(u8, exp.name, "_start")) break :blk i;
        }
        for (instance.exports_storage, 0..) |exp, i| {
            if (exp.kind == .func and std.mem.eql(u8, exp.name, "main")) break :blk i;
        }
        for (instance.exports_storage, 0..) |exp, i| {
            if (exp.kind == .func) break :blk i;
        }
        diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "no exported function found (looked for _start, main, then any export)", .{});
        return error.NoFuncExport;
    };

    var exports: wasm_c_api.ExternVec = .{ .size = 0, .data = null };
    wasm_c_api.wasm_instance_exports(instance, &exports);
    defer wasm_c_api.wasm_extern_vec_delete(&exports);
    if (entry_idx >= exports.size) {
        diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "exported function vector size mismatch", .{});
        return error.NoFuncExport;
    }
    const ext = exports.data.?[entry_idx] orelse {
        diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "exported function entry is null", .{});
        return error.NoFuncExport;
    };
    const entry_fn = wasm_c_api.wasm_extern_as_func(ext) orelse {
        diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "exported entry is not a function", .{});
        return error.NoFuncExport;
    };

    const args: wasm_c_api.ValVec = .{ .size = 0, .data = null };
    var results: wasm_c_api.ValVec = .{ .size = 0, .data = null };
    const trap = wasm_c_api.wasm_func_call(entry_fn, &args, &results);
    if (trap == null) return 0;
    defer wasm_c_api.wasm_trap_delete(trap);

    // Trap path. If `proc_exit` was the cause, the host carries
    // the requested exit code. Other traps map to 1.
    // For non-exit traps, print the kind + message on stderr so
    // the CLI / `runWasm` callers can see what hit.
    if (store.wasi_host) |host| if (host.exit_code) |_| {
        // exit_code already carries the status; nothing else to surface.
    } else {
        surfaceTrap(io, trap.?);
    };
    if (store.wasi_host) |host| if (host.exit_code) |code| {
        return @intCast(@min(code, std.math.maxInt(u8)));
    };
    return 1;
}

/// Best-effort stderr surface of a non-exit trap. If the underlying
/// writer fails (closed pipe, OOM during print), there is nothing
/// meaningful to do beyond the caller's exit-code path — the print
/// errors are intentionally swallowed.
fn surfaceTrap(io: std.Io, trap: anytype) void {
    var stderr_buf: [256]u8 = undefined;
    var sw = std.Io.File.stderr().writer(io, &stderr_buf);
    const w = &sw.interface;
    if (trap.message_ptr) |p| {
        w.print("zwasm: trap kind={s} msg={s}\n", .{
            @tagName(trap.kind),
            p[0..trap.message_len],
        }) catch {};
    } else {
        w.print("zwasm: trap kind={s}\n", .{@tagName(trap.kind)}) catch {};
    }
    w.flush() catch {};
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test {
    // The diagnostic + diag_print modules ship their own unit
    // tests; reference them from this file's test block so
    // `zig build test` discovers them via the `cli/run.zig`
    // ladder regardless of whether `main.zig` is compiled.
    _ = diagnostic;
}

// Same fixture shape as the §9.4 / 4.7d end-to-end test in
// wasm_c_api.zig:
//   (module (import "wasi_snapshot_preview1" "proc_exit"
//             (func (param i32)))
//          (func (export "main") i32.const 42 call 0))
const proc_exit_42_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7F, 0x00, 0x60, 0x00, 0x00,
    0x02, 0x24, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70,
    0x73, 0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65, 0x76, 0x69,
    0x65, 0x77, 0x31,
    0x09, 0x70, 0x72, 0x6F, 0x63, 0x5F, 0x65, 0x78, 0x69, 0x74,
    0x00, 0x00,
    0x03, 0x02, 0x01, 0x01,
    0x07, 0x08, 0x01, 0x04, 0x6D, 0x61, 0x69, 0x6E, 0x00, 0x01,
    0x0A, 0x08, 0x01, 0x06, 0x00, 0x41, 0x2A, 0x10, 0x00, 0x0B,
};

test "runWasm: proc_exit_42 fixture returns exit code 42" {
    const code = try runWasm(testing.allocator, testing.io, &proc_exit_42_wasm, &.{});
    try testing.expectEqual(@as(u8, 42), code);
}

// ADR-0016 phase 1 golden test: a malformed-magic wasm makes
// `wasm_module_new` fail; runWasm returns ModuleAllocFailed; the
// threadlocal diagnostic is set to the boundary classification
// the CLI render pipeline expects. Locks v1 → v2 parity recovery.
const malformed_magic_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0xff, 0xff, 0xff, 0xff };

test "runWasm: malformed wasm produces an instantiate-phase diagnostic" {
    const result = runWasm(testing.allocator, testing.io, &malformed_magic_wasm, &.{});
    try testing.expectError(error.ModuleAllocFailed, result);

    const diag = diagnostic.lastDiagnostic().?;
    try testing.expectEqual(diagnostic.Phase.instantiate, diag.phase);
    try testing.expectEqual(diagnostic.Kind.module_alloc_failed, diag.kind);
    try testing.expect(std.mem.startsWith(u8, diag.message(), "module decode/validate failed"));
}

test "runWasm: clearDiag is invoked on entry — fresh call clears prior state" {
    diagnostic.setDiag(.execute, .oob_memory, .unknown, "stale", .{});
    try testing.expect(diagnostic.lastDiagnostic() != null);

    // Successful run path — should clear the stale diag at entry.
    _ = try runWasm(testing.allocator, testing.io, &proc_exit_42_wasm, &.{});
    // After a successful run, no diagnostic should be set.
    try testing.expect(diagnostic.lastDiagnostic() == null);
}
