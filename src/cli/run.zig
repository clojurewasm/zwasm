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
const invoke_args_mod = @import("invoke_args.zig");

pub fn runWasm(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    argv: []const []const u8,
) !u8 {
    return runWasmCaptured(alloc, io, bytes, argv, null, null);
}

/// `zwasm run --engine=jit` (ADR-0136): JIT-compile `bytes` and run the
/// entry export (`invoke_name`, else `_start`) to completion. **D-244 chunk
/// 2c**: now attaches a WASI host (`io`) so the JIT does REAL WASI — clock /
/// random / fd_write→stdout / fd_read→stdin route through the shared interp
/// handlers (`jit_dispatch.zig`). A compute-only module simply ignores the
/// host. (args/preopens + proc_exit exit-code = follow-up chunks.) Returns 0
/// on success; JIT/validate/trap errors propagate (the caller maps to exit 1).
pub fn runWasmJit(
    alloc: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    invoke_name: ?[]const u8,
) !u8 {
    const runner = @import("../engine/runner.zig");
    const entry_name = invoke_name orelse "_start";
    var host = try wasi_host.Host.init(alloc);
    defer host.deinit();
    host.io = io;
    _ = try runner.runVoidExportWasi(alloc, bytes, entry_name, &host);
    return 0;
}

/// `zwasm run <file.cwasm>` (§12.1): load + execute a pre-compiled AOT
/// artefact directly — NO parse / validate / compile (the point of AOT).
/// Resolves the entry via the serialised v0.2 export table (ADR-0138):
/// `--invoke <name>` → `_start` → `main` → first func export. Runs it
/// with a minimal stateless runtime and surfaces an i32 result as the
/// exit code (void → 0). COMPUTE-ONLY — no WASI; stateful `.cwasm`
/// (memory/globals/imports) is §12.3b scope (ADR-0139). The caller routes
/// here on the `CWAS` magic.
pub fn runCwasm(
    alloc: std.mem.Allocator,
    cwasm_bytes: []const u8,
    invoke_name: ?[]const u8,
) !u8 {
    const aot_load = @import("../engine/codegen/aot/load.zig");
    const aot_run = @import("../engine/codegen/aot/run.zig");
    diagnostic.clearDiag();

    var mod = try aot_load.load(alloc, cwasm_bytes);
    defer mod.deinit();

    const idx = mod.resolveEntry(invoke_name) orelse {
        diagnostic.setDiag(.instantiate, .no_func_export, .unknown, "no runnable entry in .cwasm (looked for invoke/_start/main, then first func export)", .{});
        return error.NoFuncExport;
    };
    const result = try aot_run.runEntry(&mod, idx);
    return @intCast(@min(result, std.math.maxInt(u8)));
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
    return runWasmCapturedOpts(alloc, io, bytes, argv, stdout_capture, invoke_name, &.{}, null);
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
    invoke_args: ?[]const u8,
) !u8 {

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

    // Marshal `--invoke NAME=ARGS` arguments against the entry's signature
    // and collect its typed results (D-273(1)). A value-returning export now
    // runs (the results vec is sized to the result arity); the formatted
    // results print on the same channel as guest stdout — wasmtime semantics.
    var result_text: std.ArrayList(u8) = .empty;
    defer result_text.deinit(alloc);
    const trap = invoke_args_mod.invokeFormatted(alloc, entry_fn, invoke_args, &result_text) catch |err| {
        const msg = switch (err) {
            error.ArgCountMismatch => "--invoke: argument count does not match the export's parameters",
            error.UnsupportedArgType => "--invoke: unsupported argument type (CLI args are i32/i64/f32/f64 only)",
            error.InvalidArgValue => "--invoke: could not parse an argument for the export's parameter type",
            else => "--invoke: argument marshalling failed",
        };
        diagnostic.setDiag(.execute, .binding_error, .unknown, "{s}", .{msg});
        return err;
    };
    if (trap == null) {
        try writeResultText(io, stdout_capture, alloc, result_text.items);
        return 0;
    }
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

/// Emit the formatted `--invoke` result text on the guest-stdout channel:
/// the capture buffer when one is wired (tests / realworld differ), else the
/// process stdout. Empty text (void / zero-result export) is a no-op, so the
/// existing `_start`/`main` exit-code paths print nothing extra.
fn writeResultText(io: std.Io, capture: ?*std.ArrayList(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    if (capture) |buf| {
        try buf.appendSlice(alloc, text);
        return;
    }
    var ob: [256]u8 = undefined;
    var sw = std.Io.File.stdout().writer(io, &ob);
    const w = &sw.interface;
    try w.writeAll(text);
    try w.flush();
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

// `(func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)`
const add_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x07, 0x01, 0x60,
    0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20,
    0x00, 0x20, 0x01, 0x6a, 0x0b,
};

test "runWasmCapturedOpts: --invoke add=2,3 marshals args and prints the typed result (D-273(1))" {
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    const code = try runWasmCapturedOpts(testing.allocator, testing.io, &add_wasm, &.{}, &capture, "add", &.{}, "2,3");
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("5\n", capture.items);
}

test "runWasmCapturedOpts: --invoke add with a bad arg count is a loud binding_error" {
    const result = runWasmCapturedOpts(testing.allocator, testing.io, &add_wasm, &.{}, null, "add", &.{}, "2");
    try testing.expectError(error.ArgCountMismatch, result);
    const diag = diagnostic.lastDiagnostic().?;
    try testing.expectEqual(diagnostic.Kind.binding_error, diag.kind);
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

test "runCwasm: compile → produce → load+run a .cwasm, i32 result surfaces as exit code (§12.1)" {
    // Executes native AOT machine code → Win64 deferred, mirroring the
    // aot/load.zig + jit_mem exec tests (skip.phaseEnd; §12.3b/ADR-0139
    // tracks the stateful remainder). The resolveEntry + exit-code mapping
    // itself is host-independent.
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);

    const runner = @import("../engine/runner.zig");
    const aot_produce = @import("../engine/codegen/aot/produce.zig");

    // `() -> i32` returning 42, exported "f". (type/func/export/code)
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66,
        0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
        0x2a, 0x0b,
    };

    var compiled = try runner.compileWasm(testing.allocator, &wasm);
    defer compiled.deinit(testing.allocator);
    const cwasm = try aot_produce.produceFromCompiledWasm(testing.allocator, &compiled, &wasm);
    defer testing.allocator.free(cwasm);

    // Default entry resolution (no _start/main → first func export "f").
    try testing.expectEqual(@as(u8, 42), try runCwasm(testing.allocator, cwasm, null));
    // Explicit --invoke by name.
    try testing.expectEqual(@as(u8, 42), try runCwasm(testing.allocator, cwasm, "f"));
    // A missing name is a loud NoFuncExport, not a silent fallback.
    try testing.expectError(error.NoFuncExport, runCwasm(testing.allocator, cwasm, "nope"));
}

test "runWasmJit: SIMD _start runs via the JIT where the interp traps (ADR-0136 / D-244)" {
    // Interpreter path: no SIMD execution → the `i32x4.add` dispatch slot is
    // null → Trap.Unreachable, which the run path maps to a non-zero exit
    // code (a trap is exit≠0, not a Zig error).
    const interp_code = try runWasm(testing.allocator, testing.io, &simd_start_wasm, &.{});
    try testing.expect(interp_code != 0);

    // JIT path: compiles + runs the SIMD `_start` to completion → 0.
    const jit_code = try runWasmJit(testing.allocator, testing.io, &simd_start_wasm, null);
    try testing.expectEqual(@as(u8, 0), jit_code);
}

// D-244 chunk 2c: a `_start` that calls clock_time_get and traps (unreachable)
// when the loaded time is 0. `runWasmJit` now attaches a WASI host, so the JIT
// clock is REAL (nonzero) → no trap → exit 0. Without the host attachment this
// would trap. Proves `--engine jit` does real WASI end-to-end.
const clock_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0b, 0x02, 0x60, 0x03, 0x7f, 0x7e, 0x7f,
    0x01, 0x7f, 0x60, 0x00, 0x00, 0x02, 0x29, 0x01, 0x16, 0x77, 0x61, 0x73, 0x69, 0x5f, 0x73, 0x6e,
    0x61, 0x70, 0x73, 0x68, 0x6f, 0x74, 0x5f, 0x70, 0x72, 0x65, 0x76, 0x69, 0x65, 0x77, 0x31, 0x0e,
    0x63, 0x6c, 0x6f, 0x63, 0x6b, 0x5f, 0x74, 0x69, 0x6d, 0x65, 0x5f, 0x67, 0x65, 0x74, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x01, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74,
    0x61, 0x72, 0x74, 0x00, 0x01, 0x0a, 0x17, 0x01, 0x15, 0x00, 0x41, 0x00, 0x42, 0x00, 0x41, 0x00,
    0x10, 0x00, 0x1a, 0x41, 0x00, 0x29, 0x03, 0x00, 0x50, 0x04, 0x40, 0x00, 0x0b, 0x0b,
};

test "runWasmJit: --engine jit attaches a WASI host → real clock, no trap (D-244 2c)" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return @import("../test_support/skip.zig").phaseEnd(.win64);
    // Host attached → real (nonzero) clock → the trap-if-zero guard passes → 0.
    const code = try runWasmJit(testing.allocator, testing.io, &clock_start_wasm, null);
    try testing.expectEqual(@as(u8, 0), code);
}
