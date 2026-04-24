// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! C ABI export layer for zwasm.
//!
//! Provides a flat C-callable API wrapping WasmModule. All functions use
//! `callconv(.c)` for FFI compatibility. Opaque pointer types hide internal
//! layout. Error messages are stored in a thread-local buffer accessible
//! via `zwasm_last_error_message()`.
//!
//! Allocator strategy: The C API uses libc malloc (c_allocator) as the
//! default backing allocator for WasmModule and all its internal state.
//! Custom allocators can be injected via zwasm_config_t.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const WasmModule = types.WasmModule;
const WasiOptions = types.WasiOptions;

/// Convert isize (C intptr_t) to platform File.Handle.
fn isizeToHandle(v: isize) std.fs.File.Handle {
    if (builtin.os.tag == .windows) {
        return @ptrFromInt(@as(usize, @bitCast(v)));
    } else {
        return @intCast(v);
    }
}

// ============================================================
// Error handling — thread-local error message buffer
// ============================================================

const ERROR_BUF_SIZE = 512;
threadlocal var error_buf: [ERROR_BUF_SIZE]u8 = undefined;
threadlocal var error_len: usize = 0;

fn setError(err: anyerror) void {
    const msg = @errorName(err);
    const len = @min(msg.len, ERROR_BUF_SIZE);
    @memcpy(error_buf[0..len], msg[0..len]);
    error_len = len;
}

fn clearError() void {
    error_len = 0;
}

// ============================================================
// Custom allocator wrapper — C callback → std.mem.Allocator
// ============================================================

const Alignment = std.mem.Alignment;

/// C callback types for custom allocator injection.
pub const zwasm_alloc_fn_t = *const fn (?*anyopaque, usize, usize) callconv(.c) ?[*]u8;
pub const zwasm_free_fn_t = *const fn (?*anyopaque, [*]u8, usize, usize) callconv(.c) void;

/// Wraps C alloc/free callbacks as a std.mem.Allocator.
/// Heap-allocated via page_allocator so the pointer remains stable.
const CAllocatorWrapper = struct {
    alloc_fn: zwasm_alloc_fn_t,
    free_fn: zwasm_free_fn_t,
    ctx: ?*anyopaque,

    fn allocator(self: *CAllocatorWrapper) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = cAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = cFree,
    };

    fn cAlloc(ptr: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *CAllocatorWrapper = @ptrCast(@alignCast(ptr));
        return self.alloc_fn(self.ctx, len, alignment.toByteUnits());
    }

    fn cFree(ptr: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
        const self: *CAllocatorWrapper = @ptrCast(@alignCast(ptr));
        self.free_fn(self.ctx, memory.ptr, memory.len, alignment.toByteUnits());
    }
};

// ============================================================
// Configuration — zwasm_config_t
// ============================================================

/// Configuration handle for module creation. Optional custom allocator.
const CApiConfig = struct {
    c_alloc: ?*CAllocatorWrapper = null,
    cancellable: bool = true,

    fuel: ?u64 = null,
    timeout_ms: ?u64 = null,
    max_memory_bytes: ?u64 = null,
    force_interpreter: ?bool = null,

    fn deinit(self: *CApiConfig) void {
        if (self.c_alloc) |ca| page_alloc.destroy(ca);
    }

    /// Return the configured allocator, or null for default GPA.
    fn getAllocator(self: *CApiConfig) ?std.mem.Allocator {
        if (self.c_alloc) |ca| return ca.allocator();
        return null;
    }

    /// Build a WasmModule.Config from this C API config.
    /// The C ABI exposes `cancellable` as a plain bool, so we always forward a
    /// concrete value. The C default (true) matches the Vm default, so the
    /// resulting Config is a no-op override for callers who never touch the
    /// setter.
    fn toModuleConfig(self: *CApiConfig) types.WasmModule.Config {
        return .{
            .fuel = self.fuel,
            .timeout_ms = self.timeout_ms,
            .max_memory_bytes = self.max_memory_bytes,
            .force_interpreter = self.force_interpreter,
            .cancellable = self.cancellable,
        };
    }
};

pub const zwasm_config_t = CApiConfig;

// ============================================================
// Internal wrapper — allocator + WasmModule co-located
// ============================================================

// Zig 0.15's GeneralPurposeAllocator crashes in Debug-mode shared
// libraries on Linux x86_64 (PIC codegen issue, see GitHub #11).
// The C API uses libc malloc (c_allocator) as the default backing
// allocator, which is correct for a library loaded via dlopen/ctypes.
// GPA is only used when running Zig tests (leak detection).
const default_allocator = std.heap.c_allocator;

/// Internal wrapper owning a WasmModule.
/// Heap-allocated via page_allocator for address stability.
///
/// When a custom allocator is injected via zwasm_config_t, that
/// allocator is used instead of the default.
const CApiModule = struct {
    module: *WasmModule,

    fn create(wasm_bytes: []const u8, wasi: bool, config: ?*CApiConfig) !*CApiModule {
        return createConfigured(wasm_bytes, wasi, config);
    }

    fn createConfigured(wasm_bytes: []const u8, wasi: bool, config: ?*CApiConfig) !*CApiModule {
        const self = try std.heap.page_allocator.create(CApiModule);
        errdefer std.heap.page_allocator.destroy(self);

        const allocator = if (config) |c| c.getAllocator() orelse default_allocator else default_allocator;
        var mod_cfg = if (config) |c| c.toModuleConfig() else types.WasmModule.Config{};
        mod_cfg.wasi = wasi;

        self.module = try WasmModule.loadWithOptions(allocator, wasm_bytes, mod_cfg);
        return self;
    }

    fn createWasiConfigured(wasm_bytes: []const u8, opts: WasiOptions, config: ?*CApiConfig) !*CApiModule {
        return createWasiConfiguredEx(wasm_bytes, opts, config);
    }

    fn createWasiConfiguredEx(wasm_bytes: []const u8, opts: WasiOptions, config: ?*CApiConfig) !*CApiModule {
        const self = try std.heap.page_allocator.create(CApiModule);
        errdefer std.heap.page_allocator.destroy(self);

        const allocator = if (config) |c| c.getAllocator() orelse default_allocator else default_allocator;
        var mod_cfg = if (config) |c| c.toModuleConfig() else types.WasmModule.Config{};
        mod_cfg.wasi = true;
        mod_cfg.wasi_options = opts;

        self.module = try WasmModule.loadWithOptions(allocator, wasm_bytes, mod_cfg);
        return self;
    }

    fn createWithImports(wasm_bytes: []const u8, imports: []const types.ImportEntry, config: ?*CApiConfig) !*CApiModule {
        const self = try std.heap.page_allocator.create(CApiModule);
        errdefer std.heap.page_allocator.destroy(self);

        const allocator = if (config) |c| c.getAllocator() orelse default_allocator else default_allocator;
        var mod_cfg = if (config) |c| c.toModuleConfig() else types.WasmModule.Config{};
        mod_cfg.imports = imports;

        self.module = try WasmModule.loadWithOptions(allocator, wasm_bytes, mod_cfg);
        return self;
    }

    fn destroy(self: *CApiModule) void {
        self.module.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

// ============================================================
// Host function import support
// ============================================================

/// C callback type for host functions.
/// env: user-provided context pointer
/// args: input parameters as uint64_t array (nargs elements)
/// results: output buffer as uint64_t array (nresults elements)
/// Returns true on success, false on error.
pub const zwasm_host_fn_callback_t = *const fn (?*anyopaque, [*]const u64, [*]u64) callconv(.c) bool;

/// A single host function registration.
const CHostFn = struct {
    callback: zwasm_host_fn_callback_t,
    env: ?*anyopaque,
    param_count: u32,
    result_count: u32,
};

/// Import collection — stores module_name → function_name → CHostFn mappings.
const CApiImports = struct {
    alloc: std.mem.Allocator,
    /// Flat list of (module_name, func_name, host_fn) tuples
    entries: std.ArrayList(ImportItem) = .empty,

    const ImportItem = struct {
        module_name: []const u8,
        func_name: []const u8,
        host_fn: CHostFn,
    };

    fn deinit(self: *CApiImports) void {
        self.entries.deinit(self.alloc);
    }
};

pub const zwasm_imports_t = CApiImports;

/// Trampoline context stored per-import for bridging C callbacks to Zig HostFn.
/// These are stored in a global registry so the trampoline can look them up.
var trampoline_registry: std.ArrayList(CHostFn) = .empty;
var trampoline_alloc: std.mem.Allocator = std.heap.page_allocator;

/// The HostFn trampoline: called by the Wasm VM, bridges to C callback.
fn hostFnTrampoline(ctx_ptr: *anyopaque, context_id: usize) anyerror!void {
    const vm: *types.Vm = @ptrCast(@alignCast(ctx_ptr));
    if (context_id >= trampoline_registry.items.len) return error.InvalidContext;
    const host_fn = trampoline_registry.items[context_id];

    // Pop args from VM stack (in reverse order — last arg is on top)
    var args_buf: [32]u64 = undefined;
    const nargs = host_fn.param_count;
    var i: u32 = nargs;
    while (i > 0) {
        i -= 1;
        args_buf[i] = vm.popOperand();
    }

    // Call C callback
    var results_buf: [32]u64 = undefined;
    const ok = host_fn.callback(host_fn.env, &args_buf, &results_buf);
    if (!ok) return error.HostFunctionError;

    // Push results onto VM stack
    for (0..host_fn.result_count) |ri| {
        try vm.pushOperand(results_buf[ri]);
    }
}

// ============================================================
// Opaque types (C sees zwasm_module_t*, zwasm_imports_t*, etc.)
// ============================================================

pub const zwasm_module_t = CApiModule;

// ============================================================
// Configuration lifecycle
// ============================================================

/// Create a new configuration handle.
export fn zwasm_config_new() ?*zwasm_config_t {
    const config = page_alloc.create(CApiConfig) catch return null;
    config.* = .{};
    return config;
}

/// Free a configuration handle.
export fn zwasm_config_delete(config: *zwasm_config_t) void {
    config.deinit();
    page_alloc.destroy(config);
}

/// Set a custom allocator for module creation.
/// alloc_fn: fn(ctx, size, alignment_log2) -> ?[*]u8
/// free_fn: fn(ctx, ptr, size, alignment_log2) -> void
export fn zwasm_config_set_allocator(
    config: *zwasm_config_t,
    alloc_fn: zwasm_alloc_fn_t,
    free_fn: zwasm_free_fn_t,
    ctx: ?*anyopaque,
) void {
    // Free existing wrapper if any
    if (config.c_alloc) |ca| page_alloc.destroy(ca);
    const wrapper = page_alloc.create(CAllocatorWrapper) catch return;
    wrapper.* = .{
        .alloc_fn = alloc_fn,
        .free_fn = free_fn,
        .ctx = ctx,
    };
    config.c_alloc = wrapper;
}

export fn zwasm_config_set_fuel(config: *zwasm_config_t, fuel: u64) void {
    config.fuel = fuel;
}

export fn zwasm_config_set_timeout(config: *zwasm_config_t, timeout_ms: u64) void {
    config.timeout_ms = timeout_ms;
}

export fn zwasm_config_set_max_memory(config: *zwasm_config_t, max_memory_bytes: u64) void {
    config.max_memory_bytes = max_memory_bytes;
}

export fn zwasm_config_set_force_interpreter(config: *zwasm_config_t, force_interpreter: bool) void {
    config.force_interpreter = force_interpreter;
}

/// Enable or disable periodic JIT cancellation checks (default: true).
/// Disabling this improves performance but makes cancel() ineffective for JIT code.
export fn zwasm_config_set_cancellable(config: *zwasm_config_t, enabled: bool) void {
    config.cancellable = enabled;
}

// ============================================================
// Module lifecycle
// ============================================================

/// Create a new Wasm module from binary bytes.
/// Returns null on error — call `zwasm_last_error_message()` for details.
export fn zwasm_module_new(wasm_ptr: [*]const u8, len: usize) ?*zwasm_module_t {
    clearError();
    return CApiModule.create(wasm_ptr[0..len], false, null) catch |err| {
        setError(err);
        return null;
    };
}

/// Create a new WASI module from binary bytes.
/// Returns null on error — call `zwasm_last_error_message()` for details.
export fn zwasm_module_new_wasi(wasm_ptr: [*]const u8, len: usize) ?*zwasm_module_t {
    clearError();
    return CApiModule.create(wasm_ptr[0..len], true, null) catch |err| {
        setError(err);
        return null;
    };
}

/// Create a module with optional custom configuration (allocator, etc.).
/// Pass null for config to use default allocator (same as zwasm_module_new).
export fn zwasm_module_new_configured(wasm_ptr: [*]const u8, len: usize, config: ?*zwasm_config_t) ?*zwasm_module_t {
    clearError();
    return CApiModule.createConfigured(wasm_ptr[0..len], false, config) catch |err| {
        setError(err);
        return null;
    };
}

/// Create a WASI module with both WASI config and optional custom allocator.
/// Pass null for config to use default allocator.
export fn zwasm_module_new_wasi_configured2(
    wasm_ptr: [*]const u8,
    len: usize,
    wasi_config: *zwasm_wasi_config_t,
    config: ?*zwasm_config_t,
) ?*zwasm_module_t {
    clearError();

    // Build WasiOptions from wasi_config (same logic as zwasm_module_new_wasi_configured)
    const argv_slice: []const [:0]const u8 = blk: {
        const items = wasi_config.argv.items;
        const ptr: [*]const [:0]const u8 = @ptrCast(items.ptr);
        break :blk ptr[0..items.len];
    };

    const alloc = page_alloc;
    const env_keys = alloc.alloc([]const u8, wasi_config.env_keys.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer alloc.free(env_keys);
    const env_vals = alloc.alloc([]const u8, wasi_config.env_vals.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer alloc.free(env_vals);
    for (wasi_config.env_keys.items, wasi_config.env_key_lens.items, 0..) |ptr, l, i| {
        env_keys[i] = ptr[0..l];
    }
    for (wasi_config.env_vals.items, wasi_config.env_val_lens.items, 0..) |ptr, l, i| {
        env_vals[i] = ptr[0..l];
    }

    const preopens = alloc.alloc([]const u8, wasi_config.preopen_host.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer alloc.free(preopens);
    for (wasi_config.preopen_host.items, wasi_config.preopen_host_lens.items, 0..) |ptr, l, i| {
        preopens[i] = ptr[0..l];
    }

    const wasi = @import("wasi.zig");
    const fd_count2 = wasi_config.preopen_fd_hosts.items.len;
    const preopen_fds2 = alloc.alloc(types.PreopenFd, fd_count2) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer alloc.free(preopen_fds2);
    for (0..fd_count2) |i| {
        preopen_fds2[i] = .{
            .host_fd = isizeToHandle(wasi_config.preopen_fd_hosts.items[i]),
            .guest_path = wasi_config.preopen_fd_guests.items[i][0..wasi_config.preopen_fd_guest_lens.items[i]],
            .kind = if (wasi_config.preopen_fd_kinds.items[i] == 1) .dir else .file,
            .ownership = if (wasi_config.preopen_fd_ownerships.items[i] == 1) .own else .borrow,
        };
    }

    var stdio_fds2: [3]?std.fs.File.Handle = .{ null, null, null };
    var stdio_ownership2: [3]wasi.Ownership = .{ .borrow, .borrow, .borrow };
    for (0..3) |idx| {
        if (wasi_config.stdio_fds[idx] >= 0) {
            stdio_fds2[idx] = isizeToHandle(wasi_config.stdio_fds[idx]);
            stdio_ownership2[idx] = if (wasi_config.stdio_ownerships[idx] == 1) .own else .borrow;
        }
    }

    const opts = WasiOptions{
        .args = argv_slice,
        .env_keys = env_keys,
        .env_vals = env_vals,
        .preopen_paths = preopens,
        .preopen_fds = preopen_fds2,
        .stdio_fds = stdio_fds2,
        .stdio_ownership = stdio_ownership2,
    };

    return CApiModule.createWasiConfiguredEx(wasm_ptr[0..len], opts, config) catch |err| {
        setError(err);
        return null;
    };
}

/// Free all resources held by a module.
/// After this call, the module pointer is invalid.
export fn zwasm_module_delete(module: *zwasm_module_t) void {
    module.destroy();
}

/// Validate a Wasm binary without instantiating it.
/// Returns true if valid, false if invalid or malformed.
export fn zwasm_module_validate(wasm_ptr: [*]const u8, len: usize) bool {
    clearError();
    const allocator = default_allocator;
    const validate = types.runtime.validateModule;
    var module = types.runtime.Module.init(allocator, wasm_ptr[0..len]);
    defer module.deinit();
    module.decode() catch |err| {
        setError(err);
        return false;
    };
    validate(allocator, &module) catch |err| {
        setError(err);
        return false;
    };
    return true;
}

// ============================================================
// Function invocation
// ============================================================

/// Invoke an exported function by name.
/// Args and results are passed as uint64_t arrays. Returns false on error.
export fn zwasm_module_invoke(
    module: *zwasm_module_t,
    name_ptr: [*:0]const u8,
    args: ?[*]const u64,
    nargs: u32,
    results: ?[*]u64,
    nresults: u32,
) bool {
    clearError();
    const name = std.mem.sliceTo(name_ptr, 0);
    var empty = [_]u64{};
    const args_slice: []const u64 = if (args) |a| a[0..nargs] else &empty;
    const results_slice: []u64 = if (results) |r| r[0..nresults] else &empty;
    module.module.invoke(name, args_slice, results_slice) catch |err| {
        setError(err);
        return false;
    };
    return true;
}

/// Invoke the _start function (WASI entry point). Returns false on error.
export fn zwasm_module_invoke_start(module: *zwasm_module_t) bool {
    clearError();
    var empty = [_]u64{};
    module.module.invoke("_start", &empty, &empty) catch |err| {
        setError(err);
        return false;
    };
    return true;
}

// ============================================================
// Export introspection
// ============================================================

/// Return the number of exported functions.
export fn zwasm_module_export_count(module: *zwasm_module_t) u32 {
    return @intCast(module.module.export_fns.len);
}

/// Return the name of the idx-th exported function as a null-terminated string.
/// Returns null if idx is out of range.
export fn zwasm_module_export_name(module: *zwasm_module_t, idx: u32) ?[*:0]const u8 {
    if (idx >= module.module.export_fns.len) return null;
    const name = module.module.export_fns[idx].name;
    // Wasm names are stored as slices. Return as pointer — the data lives in
    // the module's decoded section and is null-terminated by virtue of the
    // underlying wasm bytes being contiguous. However, we can't guarantee a
    // null terminator after the slice, so we copy into the error_buf as a
    // scratch space. This is a simplification for C callers.
    // For zero-copy, callers should use memory_data + offsets.
    if (name.len >= ERROR_BUF_SIZE) return null;
    @memcpy(error_buf[0..name.len], name);
    error_buf[name.len] = 0;
    return @ptrCast(error_buf[0..name.len :0]);
}

/// Return the number of parameters of the idx-th exported function.
/// Returns 0 if idx is out of range.
export fn zwasm_module_export_param_count(module: *zwasm_module_t, idx: u32) u32 {
    if (idx >= module.module.export_fns.len) return 0;
    return @intCast(module.module.export_fns[idx].param_types.len);
}

/// Return the number of results of the idx-th exported function.
/// Returns 0 if idx is out of range.
export fn zwasm_module_export_result_count(module: *zwasm_module_t, idx: u32) u32 {
    if (idx >= module.module.export_fns.len) return 0;
    return @intCast(module.module.export_fns[idx].result_types.len);
}

/// Request cancellation of currently executing Wasm in this module.
/// Thread-safe. Can be called from a different thread during invoke/invoke_start.
/// Execution stops at the next checkpoint (~1024 instructions or JIT interval).
/// Has no effect if module is idle (not executing).
export fn zwasm_module_cancel(module: *zwasm_module_t) void {
    module.module.cancel();
}

// ============================================================
// WASI configuration
// ============================================================

/// Opaque WASI configuration handle.
const page_alloc = std.heap.page_allocator;

const CApiWasiConfig = struct {
    argv: std.ArrayList([*:0]const u8) = .empty,
    env_keys: std.ArrayList([*]const u8) = .empty,
    env_vals: std.ArrayList([*]const u8) = .empty,
    env_key_lens: std.ArrayList(usize) = .empty,
    env_val_lens: std.ArrayList(usize) = .empty,
    preopen_host: std.ArrayList([*]const u8) = .empty,
    preopen_guest: std.ArrayList([*]const u8) = .empty,
    preopen_host_lens: std.ArrayList(usize) = .empty,
    preopen_guest_lens: std.ArrayList(usize) = .empty,
    // FD-based preopens
    preopen_fd_hosts: std.ArrayList(isize) = .empty,
    preopen_fd_guests: std.ArrayList([*]const u8) = .empty,
    preopen_fd_guest_lens: std.ArrayList(usize) = .empty,
    preopen_fd_kinds: std.ArrayList(u8) = .empty, // 0=file, 1=dir
    preopen_fd_ownerships: std.ArrayList(u8) = .empty, // 0=borrow, 1=own
    // Stdio overrides (isize for cross-platform: fd on POSIX, HANDLE cast on Windows)
    stdio_fds: [3]isize = .{ -1, -1, -1 }, // -1 = not set
    stdio_ownerships: [3]u8 = .{ 0, 0, 0 }, // 0=borrow, 1=own

    fn deinit(self: *CApiWasiConfig) void {
        self.argv.deinit(page_alloc);
        self.env_keys.deinit(page_alloc);
        self.env_vals.deinit(page_alloc);
        self.env_key_lens.deinit(page_alloc);
        self.env_val_lens.deinit(page_alloc);
        self.preopen_host.deinit(page_alloc);
        self.preopen_guest.deinit(page_alloc);
        self.preopen_host_lens.deinit(page_alloc);
        self.preopen_guest_lens.deinit(page_alloc);
        self.preopen_fd_hosts.deinit(page_alloc);
        self.preopen_fd_guests.deinit(page_alloc);
        self.preopen_fd_guest_lens.deinit(page_alloc);
        self.preopen_fd_kinds.deinit(page_alloc);
        self.preopen_fd_ownerships.deinit(page_alloc);
    }
};

pub const zwasm_wasi_config_t = CApiWasiConfig;

/// Create a new WASI configuration handle.
export fn zwasm_wasi_config_new() ?*zwasm_wasi_config_t {
    const config = page_alloc.create(CApiWasiConfig) catch return null;
    config.* = .{};
    return config;
}

/// Free a WASI configuration handle.
export fn zwasm_wasi_config_delete(config: *zwasm_wasi_config_t) void {
    config.deinit();
    page_alloc.destroy(config);
}

/// Set command-line arguments for WASI. argv entries are null-terminated C strings.
export fn zwasm_wasi_config_set_argv(config: *zwasm_wasi_config_t, argc: u32, argv: [*]const [*:0]const u8) void {
    config.argv.clearRetainingCapacity();
    for (0..argc) |i| {
        config.argv.append(page_alloc, argv[i]) catch {};
    }
}

/// Set environment variables for WASI. keys and vals are arrays of C strings.
export fn zwasm_wasi_config_set_env(
    config: *zwasm_wasi_config_t,
    count: u32,
    keys: [*]const [*]const u8,
    key_lens: [*]const usize,
    vals: [*]const [*]const u8,
    val_lens: [*]const usize,
) void {
    config.env_keys.clearRetainingCapacity();
    config.env_vals.clearRetainingCapacity();
    config.env_key_lens.clearRetainingCapacity();
    config.env_val_lens.clearRetainingCapacity();
    for (0..count) |i| {
        config.env_keys.append(page_alloc, keys[i]) catch {};
        config.env_vals.append(page_alloc, vals[i]) catch {};
        config.env_key_lens.append(page_alloc, key_lens[i]) catch {};
        config.env_val_lens.append(page_alloc, val_lens[i]) catch {};
    }
}

/// Add a preopened directory mapping for WASI.
export fn zwasm_wasi_config_preopen_dir(
    config: *zwasm_wasi_config_t,
    host_path: [*]const u8,
    host_path_len: usize,
    guest_path: [*]const u8,
    guest_path_len: usize,
) void {
    config.preopen_host.append(page_alloc, host_path) catch {};
    config.preopen_host_lens.append(page_alloc, host_path_len) catch {};
    config.preopen_guest.append(page_alloc, guest_path) catch {};
    config.preopen_guest_lens.append(page_alloc, guest_path_len) catch {};
}

/// Add a preopened entry from an existing host file descriptor.
/// kind: 0 = file, 1 = directory.
/// ownership: 0 = borrow (caller keeps fd), 1 = own (runtime closes fd).
export fn zwasm_wasi_config_preopen_fd(
    config: *zwasm_wasi_config_t,
    host_fd: isize,
    guest_path: [*]const u8,
    guest_path_len: usize,
    kind: u8,
    ownership: u8,
) void {
    config.preopen_fd_hosts.append(page_alloc, host_fd) catch {};
    config.preopen_fd_guests.append(page_alloc, guest_path) catch {};
    config.preopen_fd_guest_lens.append(page_alloc, guest_path_len) catch {};
    config.preopen_fd_kinds.append(page_alloc, kind) catch {};
    config.preopen_fd_ownerships.append(page_alloc, ownership) catch {};
}

/// Override a stdio file descriptor (0=stdin, 1=stdout, 2=stderr).
/// ownership: 0 = borrow (caller keeps fd), 1 = own (runtime closes fd).
export fn zwasm_wasi_config_set_stdio_fd(
    config: *zwasm_wasi_config_t,
    wasi_fd: u32,
    host_fd: isize,
    ownership: u8,
) void {
    if (wasi_fd < 3) {
        config.stdio_fds[wasi_fd] = host_fd;
        config.stdio_ownerships[wasi_fd] = ownership;
    }
}

/// Create a new WASI module with custom configuration.
/// Returns null on error.
export fn zwasm_module_new_wasi_configured(
    wasm_ptr: [*]const u8,
    len: usize,
    config: *zwasm_wasi_config_t,
) ?*zwasm_module_t {
    clearError();

    // Build WasiOptions from config
    // argv: slice of sentinel-terminated pointers — direct from config
    const argv_slice: []const [:0]const u8 = blk: {
        const items = config.argv.items;
        // Reinterpret [*:0]const u8 array as [:0]const u8 slice
        const ptr: [*]const [:0]const u8 = @ptrCast(items.ptr);
        break :blk ptr[0..items.len];
    };

    // env: build slices from stored pointers + lengths
    const alloc = page_alloc;
    const env_keys = alloc.alloc([]const u8, config.env_keys.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer alloc.free(env_keys);
    const env_vals = alloc.alloc([]const u8, config.env_vals.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer alloc.free(env_vals);
    for (config.env_keys.items, config.env_key_lens.items, 0..) |ptr, l, i| {
        env_keys[i] = ptr[0..l];
    }
    for (config.env_vals.items, config.env_val_lens.items, 0..) |ptr, l, i| {
        env_vals[i] = ptr[0..l];
    }

    // preopens: build slices
    const preopens = alloc.alloc([]const u8, config.preopen_host.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer alloc.free(preopens);
    for (config.preopen_host.items, config.preopen_host_lens.items, 0..) |ptr, l, i| {
        preopens[i] = ptr[0..l];
    }

    // FD-based preopens
    const wasi = @import("wasi.zig");
    const fd_count = config.preopen_fd_hosts.items.len;
    const preopen_fds = alloc.alloc(types.PreopenFd, fd_count) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer alloc.free(preopen_fds);
    for (0..fd_count) |i| {
        preopen_fds[i] = .{
            .host_fd = isizeToHandle(config.preopen_fd_hosts.items[i]),
            .guest_path = config.preopen_fd_guests.items[i][0..config.preopen_fd_guest_lens.items[i]],
            .kind = if (config.preopen_fd_kinds.items[i] == 1) .dir else .file,
            .ownership = if (config.preopen_fd_ownerships.items[i] == 1) .own else .borrow,
        };
    }

    // Stdio overrides
    var stdio_fds: [3]?std.fs.File.Handle = .{ null, null, null };
    var stdio_ownership: [3]wasi.Ownership = .{ .borrow, .borrow, .borrow };
    for (0..3) |idx| {
        if (config.stdio_fds[idx] >= 0) {
            stdio_fds[idx] = isizeToHandle(config.stdio_fds[idx]);
            stdio_ownership[idx] = if (config.stdio_ownerships[idx] == 1) .own else .borrow;
        }
    }

    const opts = WasiOptions{
        .args = argv_slice,
        .env_keys = env_keys,
        .env_vals = env_vals,
        .preopen_paths = preopens,
        .preopen_fds = preopen_fds,
        .stdio_fds = stdio_fds,
        .stdio_ownership = stdio_ownership,
    };

    return CApiModule.createWasiConfigured(wasm_ptr[0..len], opts, null) catch |err| {
        setError(err);
        return null;
    };
}

// ============================================================
// Host function imports
// ============================================================

/// Create a new import collection.
export fn zwasm_import_new() ?*zwasm_imports_t {
    const imports = page_alloc.create(CApiImports) catch return null;
    imports.* = .{ .alloc = page_alloc };
    return imports;
}

/// Free an import collection.
export fn zwasm_import_delete(imports: *zwasm_imports_t) void {
    imports.deinit();
    page_alloc.destroy(imports);
}

/// Register a host function in the import collection.
export fn zwasm_import_add_fn(
    imports: *zwasm_imports_t,
    module_name: [*:0]const u8,
    func_name: [*:0]const u8,
    callback: zwasm_host_fn_callback_t,
    env: ?*anyopaque,
    param_count: u32,
    result_count: u32,
) void {
    imports.entries.append(imports.alloc, .{
        .module_name = std.mem.sliceTo(module_name, 0),
        .func_name = std.mem.sliceTo(func_name, 0),
        .host_fn = .{
            .callback = callback,
            .env = env,
            .param_count = param_count,
            .result_count = result_count,
        },
    }) catch {};
}

/// Create a new module with host function imports.
/// Returns null on error.
export fn zwasm_module_new_with_imports(
    wasm_ptr: [*]const u8,
    len: usize,
    imports: *zwasm_imports_t,
) ?*zwasm_module_t {
    clearError();

    // Build ImportEntry array from CApiImports
    // Group entries by module_name
    const alloc = page_alloc;

    // Collect unique module names
    var module_names: std.ArrayList([]const u8) = .empty;
    defer module_names.deinit(alloc);
    for (imports.entries.items) |entry| {
        var found = false;
        for (module_names.items) |name| {
            if (std.mem.eql(u8, name, entry.module_name)) {
                found = true;
                break;
            }
        }
        if (!found) module_names.append(alloc, entry.module_name) catch {};
    }

    // Build HostFnEntry slices per module, registering trampolines
    var import_entries = alloc.alloc(types.ImportEntry, module_names.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer alloc.free(import_entries);

    for (module_names.items, 0..) |mod_name, mi| {
        // Count functions for this module
        var count: usize = 0;
        for (imports.entries.items) |entry| {
            if (std.mem.eql(u8, entry.module_name, mod_name)) count += 1;
        }

        const host_fns = alloc.alloc(types.HostFnEntry, count) catch {
            setError(error.OutOfMemory);
            return null;
        };

        var fi: usize = 0;
        for (imports.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.module_name, mod_name)) continue;
            // Register trampoline
            const trampoline_id = trampoline_registry.items.len;
            trampoline_registry.append(trampoline_alloc, entry.host_fn) catch {
                setError(error.OutOfMemory);
                return null;
            };
            host_fns[fi] = .{
                .name = entry.func_name,
                .callback = hostFnTrampoline,
                .context = trampoline_id,
            };
            fi += 1;
        }

        import_entries[mi] = .{
            .module = mod_name,
            .source = .{ .host_fns = host_fns },
        };
    }

    const result = CApiModule.createWithImports(wasm_ptr[0..len], import_entries, null) catch |err| {
        setError(err);
        return null;
    };

    // Free temporary HostFnEntry slices (module has copied what it needs)
    for (import_entries) |ie| {
        switch (ie.source) {
            .host_fns => |hfs| alloc.free(hfs),
            else => {},
        }
    }

    return result;
}

// ============================================================
// Memory access
// ============================================================

/// Return a direct pointer to linear memory (memory index 0).
/// Returns null if the module has no memory.
/// WARNING: Pointer is invalidated by memory growth (any call that may grow memory).
export fn zwasm_module_memory_data(module: *zwasm_module_t) ?[*]u8 {
    const mem = module.module.instance.getMemory(0) catch return null;
    const bytes = mem.memory();
    if (bytes.len == 0) return null;
    return bytes.ptr;
}

/// Return the current size of linear memory in bytes.
/// Returns 0 if the module has no memory.
export fn zwasm_module_memory_size(module: *zwasm_module_t) usize {
    const mem = module.module.instance.getMemory(0) catch return 0;
    return mem.memory().len;
}

/// Read bytes from linear memory into out_buf. Returns false on out-of-bounds.
export fn zwasm_module_memory_read(
    module: *zwasm_module_t,
    offset: u32,
    len: u32,
    out_buf: [*]u8,
) bool {
    clearError();
    const mem = module.module.instance.getMemory(0) catch |err| {
        setError(err);
        return false;
    };
    const bytes = mem.memory();
    const end = @as(u64, offset) + @as(u64, len);
    if (end > bytes.len) {
        setError(error.OutOfBoundsMemoryAccess);
        return false;
    }
    @memcpy(out_buf[0..len], bytes[offset..][0..len]);
    return true;
}

/// Write bytes from data into linear memory. Returns false on out-of-bounds.
export fn zwasm_module_memory_write(
    module: *zwasm_module_t,
    offset: u32,
    data: [*]const u8,
    len: u32,
) bool {
    clearError();
    const mem = module.module.instance.getMemory(0) catch |err| {
        setError(err);
        return false;
    };
    const bytes = mem.memory();
    const end = @as(u64, offset) + @as(u64, len);
    if (end > bytes.len) {
        setError(error.OutOfBoundsMemoryAccess);
        return false;
    }
    @memcpy(bytes[offset..][0..len], data[0..len]);
    return true;
}

/// Return the last error message as a null-terminated C string.
/// Returns an empty string if no error has occurred.
/// The pointer is valid until the next C API call on the same thread.
export fn zwasm_last_error_message() [*:0]const u8 {
    if (error_len == 0) return "";
    if (error_len < ERROR_BUF_SIZE) {
        error_buf[error_len] = 0;
        return @ptrCast(error_buf[0..error_len :0]);
    }
    error_buf[ERROR_BUF_SIZE - 1] = 0;
    return @ptrCast(error_buf[0 .. ERROR_BUF_SIZE - 1 :0]);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const MINIMAL_WASM = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

test "c_api: module_new with minimal wasm" {
    const module = zwasm_module_new(MINIMAL_WASM.ptr, MINIMAL_WASM.len);
    try testing.expect(module != null);
    zwasm_module_delete(module.?);
}

test "c_api: module_new with invalid bytes returns null" {
    const bad = &[_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const module = zwasm_module_new(bad.ptr, bad.len);
    try testing.expect(module == null);
    const msg = zwasm_last_error_message();
    try testing.expect(msg[0] != 0);
}

test "c_api: module_new_wasi with minimal wasm" {
    const module = zwasm_module_new_wasi(MINIMAL_WASM.ptr, MINIMAL_WASM.len);
    try testing.expect(module != null);
    zwasm_module_delete(module.?);
}

test "c_api: module_validate with valid wasm" {
    try testing.expect(zwasm_module_validate(MINIMAL_WASM.ptr, MINIMAL_WASM.len));
}

test "c_api: module_validate with invalid bytes" {
    const bad = &[_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try testing.expect(!zwasm_module_validate(bad.ptr, bad.len));
    const msg = zwasm_last_error_message();
    try testing.expect(msg[0] != 0);
}

// Module with exported function "f" returning i32 42: () -> i32
const RETURN42_WASM = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
    "\x01\x05\x01\x60\x00\x01\x7f" ++ // type: () -> i32
    "\x03\x02\x01\x00" ++ // func section
    "\x07\x05\x01\x01\x66\x00\x00" ++ // export "f" = func 0
    "\x0a\x06\x01\x04\x00\x41\x2a\x0b"; // code: i32.const 42, end

test "c_api: invoke exported function" {
    const module = zwasm_module_new(RETURN42_WASM.ptr, RETURN42_WASM.len).?;
    defer zwasm_module_delete(module);

    var results = [_]u64{0};
    try testing.expect(zwasm_module_invoke(module, "f", null, 0, &results, 1));
    try testing.expectEqual(@as(u64, 42), results[0]);
}

test "c_api: invoke nonexistent function returns false" {
    const module = zwasm_module_new(RETURN42_WASM.ptr, RETURN42_WASM.len).?;
    defer zwasm_module_delete(module);

    try testing.expect(!zwasm_module_invoke(module, "nonexistent", null, 0, null, 0));
    const msg = zwasm_last_error_message();
    try testing.expect(msg[0] != 0);
}

// Module with 1-page memory exported as "memory" + function "store42" that stores 42 at offset 0
const MEMORY_WASM = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
    "\x01\x04\x01\x60\x00\x00" ++ // type: () -> ()
    "\x03\x02\x01\x00" ++ // func section
    "\x05\x03\x01\x00\x01" ++ // memory: min=0, max=1
    "\x07\x09\x02\x01\x6d\x02\x00" ++ // export "m" = memory 0
    "\x01\x66\x00\x00" ++ // export "f" = func 0
    "\x0a\x0b\x01\x09\x00\x41\x00\x41\x2a\x36\x02\x00\x0b"; // code: i32.const 0, i32.const 42, i32.store, end

test "c_api: memory_data and memory_size" {
    const module = zwasm_module_new(MEMORY_WASM.ptr, MEMORY_WASM.len).?;
    defer zwasm_module_delete(module);

    const size = zwasm_module_memory_size(module);
    try testing.expect(size > 0); // At least 1 page = 65536 bytes

    const data = zwasm_module_memory_data(module);
    try testing.expect(data != null);
}

test "c_api: memory_write and memory_read" {
    const module = zwasm_module_new(MEMORY_WASM.ptr, MEMORY_WASM.len).?;
    defer zwasm_module_delete(module);

    // Write data
    const write_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try testing.expect(zwasm_module_memory_write(module, 0, &write_data, 4));

    // Read it back
    var read_buf: [4]u8 = undefined;
    try testing.expect(zwasm_module_memory_read(module, 0, 4, &read_buf));
    try testing.expectEqualSlices(u8, &write_data, &read_buf);
}

test "c_api: memory_read out of bounds" {
    const module = zwasm_module_new(MEMORY_WASM.ptr, MEMORY_WASM.len).?;
    defer zwasm_module_delete(module);

    var buf: [1]u8 = undefined;
    try testing.expect(!zwasm_module_memory_read(module, 0xFFFFFFFF, 1, &buf));
}

test "c_api: export introspection" {
    const module = zwasm_module_new(RETURN42_WASM.ptr, RETURN42_WASM.len).?;
    defer zwasm_module_delete(module);

    try testing.expectEqual(@as(u32, 1), zwasm_module_export_count(module));

    const name = zwasm_module_export_name(module, 0);
    try testing.expect(name != null);
    try testing.expectEqualStrings("f", std.mem.sliceTo(name.?, 0));

    try testing.expectEqual(@as(u32, 0), zwasm_module_export_param_count(module, 0));
    try testing.expectEqual(@as(u32, 1), zwasm_module_export_result_count(module, 0));

    // Out of range
    try testing.expect(zwasm_module_export_name(module, 99) == null);
}

test "c_api: wasi config lifecycle" {
    const config = zwasm_wasi_config_new();
    try testing.expect(config != null);
    zwasm_wasi_config_delete(config.?);
}

test "c_api: host function imports" {
    // Module that imports "env" "add" (i32, i32) -> i32
    // and exports "call_add" which calls add(3, 4) and returns result
    const IMPORT_WASM = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x07\x01\x60\x02\x7f\x7f\x01\x7f" ++ // type: (i32, i32) -> i32
        "\x02\x0b\x01\x03\x65\x6e\x76\x03\x61\x64\x64\x00\x00" ++ // import "env" "add" type 0
        "\x03\x02\x01\x00" ++ // func section: func 1 uses type 0
        "\x07\x0c\x01\x08\x63\x61\x6c\x6c\x5f\x61\x64\x64\x00\x01" ++ // export "call_add" = func 1
        "\x0a\x0a\x01\x08\x00\x41\x03\x41\x04\x10\x00\x0b"; // code: i32.const 3, i32.const 4, call 0, end

    const imports = zwasm_import_new().?;
    defer zwasm_import_delete(imports);

    const S = struct {
        fn addCallback(_: ?*anyopaque, args: [*]const u64, results: [*]u64) callconv(.c) bool {
            const a: i32 = @truncate(@as(i64, @bitCast(args[0])));
            const b: i32 = @truncate(@as(i64, @bitCast(args[1])));
            results[0] = @bitCast(@as(i64, a + b));
            return true;
        }
    };

    zwasm_import_add_fn(imports, "env", "add", S.addCallback, null, 2, 1);

    const module = zwasm_module_new_with_imports(IMPORT_WASM.ptr, IMPORT_WASM.len, imports);
    if (module == null) {
        const msg = zwasm_last_error_message();
        std.debug.print("Error: {s}\n", .{std.mem.sliceTo(msg, 0)});
    }
    try testing.expect(module != null);
    defer zwasm_module_delete(module.?);

    var results = [_]u64{0};
    try testing.expect(zwasm_module_invoke(module.?, "call_add", null, 0, &results, 1));
    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "c_api: import collection lifecycle" {
    const imports = zwasm_import_new();
    try testing.expect(imports != null);
    zwasm_import_delete(imports.?);
}

test "c_api: last_error_message is empty after success" {
    _ = zwasm_module_validate(MINIMAL_WASM.ptr, MINIMAL_WASM.len);
    const msg = zwasm_last_error_message();
    try testing.expect(msg[0] == 0);
}

test "c_api: config lifecycle" {
    const config = zwasm_config_new();
    try testing.expect(config != null);
    zwasm_config_delete(config.?);
}

test "c_api: module_new_configured with null config uses default allocator" {
    const module = zwasm_module_new_configured(RETURN42_WASM.ptr, RETURN42_WASM.len, null);
    try testing.expect(module != null);
    defer zwasm_module_delete(module.?);

    var results = [_]u64{0};
    try testing.expect(zwasm_module_invoke(module.?, "f", null, 0, &results, 1));
    try testing.expectEqual(@as(u64, 42), results[0]);
}

test "c_api: custom allocator — counting allocs" {
    const CountingCtx = struct {
        alloc_count: usize = 0,
        free_count: usize = 0,
    };

    const S = struct {
        fn allocFn(ctx: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?[*]u8 {
            const counting: *CountingCtx = @ptrCast(@alignCast(ctx));
            counting.alloc_count += 1;
            return std.heap.page_allocator.rawAlloc(std.heap.page_allocator.ptr, size, Alignment.fromByteUnits(alignment), @returnAddress());
        }

        fn freeFn(ctx: ?*anyopaque, buf: [*]u8, size: usize, alignment: usize) callconv(.c) void {
            const counting: *CountingCtx = @ptrCast(@alignCast(ctx));
            counting.free_count += 1;
            std.heap.page_allocator.rawFree(std.heap.page_allocator.ptr, buf[0..size], Alignment.fromByteUnits(alignment), @returnAddress());
        }
    };

    var counting_ctx = CountingCtx{};
    const config = zwasm_config_new().?;
    defer zwasm_config_delete(config);
    zwasm_config_set_allocator(config, S.allocFn, S.freeFn, &counting_ctx);

    const module = zwasm_module_new_configured(RETURN42_WASM.ptr, RETURN42_WASM.len, config);
    try testing.expect(module != null);

    // Verify allocations happened through our allocator
    try testing.expect(counting_ctx.alloc_count > 0);

    const alloc_before_delete = counting_ctx.alloc_count;
    _ = alloc_before_delete;
    zwasm_module_delete(module.?);

    // After delete, all allocations should be freed
    try testing.expectEqual(counting_ctx.alloc_count, counting_ctx.free_count);
}

test "c_api: module_new_wasi_configured2 with null config" {
    const wasi_config = zwasm_wasi_config_new().?;
    defer zwasm_wasi_config_delete(wasi_config);

    const module = zwasm_module_new_wasi_configured2(MINIMAL_WASM.ptr, MINIMAL_WASM.len, wasi_config, null);
    try testing.expect(module != null);
    zwasm_module_delete(module.?);
}

test "c_api: config set vm limits" {
    const config = zwasm_config_new().?;
    defer zwasm_config_delete(config);

    zwasm_config_set_fuel(config, 9999);
    zwasm_config_set_timeout(config, 1000);
    zwasm_config_set_max_memory(config, 65536);
    zwasm_config_set_force_interpreter(config, true);

    const module = zwasm_module_new_configured(MINIMAL_WASM.ptr, MINIMAL_WASM.len, config);
    try testing.expect(module != null);
    defer zwasm_module_delete(module.?);

    const mod = &module.?.module.*;
    try testing.expectEqual(@as(?u64, 9999), mod.vm.fuel);
    try testing.expectEqual(@as(?u64, 65536), mod.vm.max_memory_bytes);
    try testing.expectEqual(true, mod.vm.force_interpreter);
    try testing.expect(mod.vm.deadline_ns != null);
}
