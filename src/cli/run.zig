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

const wasm_c_api = @import("../api/wasm.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");
const wasi_host = @import("../wasi/host.zig");

pub fn runWasm(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
) !u8 {
    return runWasmCaptured(alloc, io, bytes, argv, null, null);
}

/// `zwasm run --engine=jit` (ADR-0136): JIT-compile `bytes` and run the
/// entry export (`invoke_name`, else `_start`) to completion. COMPUTE-ONLY
/// — no WASI I/O or `proc_exit` exit-code plumbing yet (that is the d-3
/// JIT-WASI follow-up, D-244): a guest that does I/O computes but produces
/// no stdout. Intended for compute / SIMD modules (e.g. the §11.3 bench
/// corpus) that the interpreter cannot run because SIMD is JIT-only. No
/// `io` arg — there is no host I/O on this path. Returns 0 on success;
/// JIT/validate/trap errors propagate (the caller maps them to exit 1).
pub fn runWasmJit(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    invoke_name: ?[]const u8,
) !u8 {
    const runner = @import("../engine/runner.zig");
    const entry_name = invoke_name orelse "_start";
    _ = try runner.runVoidExport(alloc, bytes, entry_name);
    return 0;
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
///
/// `invoke_name` overrides the entry-point selection (default
/// `_start` → `main` → first func export). When non-null, the
/// runner locates the func export with that exact name and calls
/// it with zero args. Phase 11 bench prerequisite per §9.12-G;
/// arg marshalling + result printing remain Phase 11 scope.
pub fn runWasmCaptured(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
    stdout_capture: ?*std.ArrayList(u8),
    invoke_name: ?[]const u8,
) !u8 {
    return runWasmCapturedOpts(alloc, io, bytes, argv, stdout_capture, invoke_name, &.{});
}

/// One host→guest directory mapping for a WASI preopen (`--dir`, D-243).
pub const PreopenDir = struct { host_path: []const u8, guest_path: []const u8 };

/// Like `runWasmCaptured` but maps `preopens` host directories into the
/// guest's WASI preopen table (the `--dir <host>[:<guest>]` flag). The
/// opened host dir fds live for the process lifetime (CLI-scoped); the
/// realworld runners pass `&.{}` (no preopens) per D-243.
pub fn runWasmCapturedOpts(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
    stdout_capture: ?*std.ArrayList(u8),
    invoke_name: ?[]const u8,
    preopens: []const PreopenDir,
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
    // D-243 — map host directories into the guest's preopen table. Open
    // each host dir and register its fd via addPreopen; path_open then
    // resolves guest paths relative to it. The fd stays open for the
    // process lifetime (host.deinit frees the preopen names, not the fds).
    for (preopens) |pd| {
        const host_dir = std.Io.Dir.cwd().openDir(io, pd.host_path, .{ .iterate = true }) catch |err| {
            diagnostic.setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi preopen dir open failed", .{});
            wasm_c_api.zwasm_wasi_config_delete(cfg);
            return err;
        };
        _ = cfg.addPreopen(host_dir.handle, pd.guest_path) catch {
            diagnostic.setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi preopen registration failed", .{});
            wasm_c_api.zwasm_wasi_config_delete(cfg);
            return error.ConfigAllocFailed;
        };
    }
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
        // ADR-0016 M3 — `frontendValidate` sets an attributed validate
        // diagnostic (phase=.validate, op/offset) on the cold path; keep
        // it. Only fall back to the generic message if no detail was set
        // (e.g. an allocation failure rather than a validate rejection).
        if (diagnostic.lastDiagnostic() == null) {
            diagnostic.setDiag(.instantiate, .module_alloc_failed, .unknown, "module decode/validate failed", .{});
        }
        return error.ModuleAllocFailed;
    };
    defer wasm_c_api.wasm_module_delete(module);

    const instance = wasm_c_api.wasm_instance_new(store, module, null, null) orelse {
        diagnostic.setDiag(.instantiate, .instance_alloc_failed, .unknown, "instantiation failed (no further detail in phase 1)", .{});
        return error.InstanceAllocFailed;
    };
    defer wasm_c_api.wasm_instance_delete(instance);

    // Locate the entry export. When `invoke_name` is non-null the
    // caller has picked a specific export by name (Phase 11 bench
    // prerequisite per §9.12-G); otherwise WASI guests
    // conventionally export `_start` and our fixtures + hand-rolled
    // hello-worlds also use `main`.
    const entry_idx = blk: {
        if (invoke_name) |name| {
            for (instance.exports_storage, 0..) |exp, i| {
                if (exp.kind == .func and std.mem.eql(u8, exp.name, name)) break :blk i;
            }
            diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "--invoke: named func export not found", .{});
            return error.NoFuncExport;
        }
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
    if (store.wasi_host) |host_opaque| {
        const host: *wasi_host.Host = @ptrCast(@alignCast(host_opaque));
        if (host.exit_code) |_| {
            // exit_code already carries the status; nothing else to surface.
        } else {
            surfaceTrap(io, trap.?);
        }
    } else {
        surfaceTrap(io, trap.?);
    }
    if (store.wasi_host) |host_opaque| {
        const host: *wasi_host.Host = @ptrCast(@alignCast(host_opaque));
        if (host.exit_code) |code| {
            return @intCast(@min(code, std.math.maxInt(u8)));
        }
    }
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
            // EXEMPT-FALLBACK: ADR-0016 phase 1 — surfaceTrap is best-effort trap stderr; closed-pipe failure has no recovery path.
        }) catch {};
    } else {
        // EXEMPT-FALLBACK: ADR-0016 phase 1 — surfaceTrap is best-effort trap stderr; closed-pipe failure has no recovery path.
        w.print("zwasm: trap kind={s}\n", .{@tagName(trap.kind)}) catch {};
    }
    // EXEMPT-FALLBACK: ADR-0016 phase 1 — final stderr flush on trap surfacing; failure here is unrecoverable.
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
    0x01, 0x08, 0x02, 0x60, 0x01, 0x7F, 0x00, 0x60,
    0x00, 0x00, 0x02, 0x24, 0x01, 0x16, 0x77, 0x61,
    0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70, 0x73,
    0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65, 0x76,
    0x69, 0x65, 0x77, 0x31, 0x09, 0x70, 0x72, 0x6F,
    0x63, 0x5F, 0x65, 0x78, 0x69, 0x74, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x01, 0x07, 0x08, 0x01, 0x04,
    0x6D, 0x61, 0x69, 0x6E, 0x00, 0x01, 0x0A, 0x08,
    0x01, 0x06, 0x00, 0x41, 0x2A, 0x10, 0x00, 0x0B,
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

test "runWasmCaptured: --invoke 'main' on proc_exit_42 fixture returns exit code 42" {
    // Phase 11 bench prerequisite (§9.12-G): named-export entry-point
    // selection. The proc_exit_42 fixture exports `main`; invoking it
    // by name returns the same exit code as the default `main` fallback.
    const code = try runWasmCaptured(testing.allocator, testing.io, &proc_exit_42_wasm, &.{}, null, "main");
    try testing.expectEqual(@as(u8, 42), code);
}

test "runWasmCaptured: --invoke <bogus> on proc_exit_42 fixture returns NoFuncExport" {
    const result = runWasmCaptured(testing.allocator, testing.io, &proc_exit_42_wasm, &.{}, null, "bogus_export_name");
    try testing.expectError(error.NoFuncExport, result);

    const diag = diagnostic.lastDiagnostic().?;
    try testing.expectEqual(diagnostic.Phase.instantiate, diag.phase);
    try testing.expectEqual(diagnostic.Kind.no_func_export, diag.kind);
    try testing.expect(std.mem.startsWith(u8, diag.message(), "--invoke:"));
}

test "runWasm: clearDiag is invoked on entry — fresh call clears prior state" {
    diagnostic.setDiag(.execute, .oob_memory, .unknown, "stale", .{});
    try testing.expect(diagnostic.lastDiagnostic() != null);

    // Successful run path — should clear the stale diag at entry.
    _ = try runWasm(testing.allocator, testing.io, &proc_exit_42_wasm, &.{});
    // After a successful run, no diagnostic should be set.
    try testing.expect(diagnostic.lastDiagnostic() == null);
}

// `(module (memory (export "memory") 1) (func (export "_start")
//   (local $i i32) (local $acc v128) ... loop { acc = i32x4.add acc k; i-- }
//   (v128.store 0 acc)))` — a compute-only SIMD `_start`. The interpreter
// has NO SIMD execution (SIMD is JIT-only by design, D-244), so the default
// path traps `Unreachable`; `--engine=jit` (ADR-0136) JIT-compiles + runs it.
const simd_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07,
    0x13, 0x02, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x06,
    0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x55, 0x01, 0x53,
    0x02, 0x01, 0x7f, 0x01, 0x7b, 0x41, 0x80, 0xda, 0xc4, 0x09, 0x21, 0x00,
    0xfd, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x01, 0x02, 0x40, 0x03, 0x40,
    0x20, 0x01, 0xfd, 0x0c, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0xfd, 0xae, 0x01, 0x21,
    0x01, 0x20, 0x00, 0x41, 0x01, 0x6b, 0x21, 0x00, 0x20, 0x00, 0x0d, 0x00,
    0x0b, 0x0b, 0x41, 0x00, 0x20, 0x01, 0xfd, 0x0b, 0x04, 0x00, 0x0b,
};

test "runWasmJit: SIMD _start runs via the JIT where the interp traps (ADR-0136 / D-244)" {
    // Interpreter path: no SIMD execution → the `i32x4.add` dispatch slot is
    // null → Trap.Unreachable, which the run path maps to a non-zero exit
    // code (a trap is exit≠0, not a Zig error).
    const interp_code = try runWasm(testing.allocator, testing.io, &simd_start_wasm, &.{});
    try testing.expect(interp_code != 0);

    // JIT path: compiles + runs the SIMD `_start` to completion → 0.
    const jit_code = try runWasmJit(testing.allocator, &simd_start_wasm, null);
    try testing.expectEqual(@as(u8, 0), jit_code);
}
