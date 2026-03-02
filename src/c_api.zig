// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! C ABI export layer for zwasm.
//!
//! Provides a flat C-callable API wrapping WasmModule. All functions use
//! `callconv(.c)` for FFI compatibility. Opaque pointer types hide internal
//! layout. Error messages are stored in a thread-local buffer accessible
//! via `zwasm_last_error_message()`.
//!
//! Allocator strategy: Each CApiModule owns a GeneralPurposeAllocator,
//! heap-allocated via page_allocator so its address is stable. The GPA
//! provides the allocator for WasmModule and all its internal state.

const std = @import("std");
const types = @import("types.zig");
const WasmModule = types.WasmModule;
const WasiOptions = types.WasiOptions;

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
// Internal wrapper — GPA + WasmModule co-located
// ============================================================

const Gpa = std.heap.GeneralPurposeAllocator(.{});

/// Internal wrapper owning both the GPA and WasmModule.
/// Heap-allocated via page_allocator for address stability.
const CApiModule = struct {
    gpa: Gpa,
    module: *WasmModule,

    fn create(wasm_bytes: []const u8, wasi: bool) !*CApiModule {
        const self = try std.heap.page_allocator.create(CApiModule);
        errdefer std.heap.page_allocator.destroy(self);
        self.gpa = .{};
        const allocator = self.gpa.allocator();
        self.module = if (wasi)
            try WasmModule.loadWasi(allocator, wasm_bytes)
        else
            try WasmModule.load(allocator, wasm_bytes);
        return self;
    }

    fn createWasiConfigured(wasm_bytes: []const u8, opts: WasiOptions) !*CApiModule {
        const self = try std.heap.page_allocator.create(CApiModule);
        errdefer std.heap.page_allocator.destroy(self);
        self.gpa = .{};
        const allocator = self.gpa.allocator();
        self.module = try WasmModule.loadWasiWithOptions(allocator, wasm_bytes, opts);
        return self;
    }

    fn createWithImports(wasm_bytes: []const u8, imports: []const types.ImportEntry) !*CApiModule {
        const self = try std.heap.page_allocator.create(CApiModule);
        errdefer std.heap.page_allocator.destroy(self);
        self.gpa = .{};
        const allocator = self.gpa.allocator();
        self.module = try WasmModule.loadWithImports(allocator, wasm_bytes, imports);
        return self;
    }

    fn destroy(self: *CApiModule) void {
        self.module.deinit();
        _ = self.gpa.deinit();
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
    entries: std.ArrayList(ImportItem),

    const ImportItem = struct {
        module_name: []const u8,
        func_name: []const u8,
        host_fn: CHostFn,
    };

    fn init(alloc: std.mem.Allocator) CApiImports {
        return .{
            .alloc = alloc,
            .entries = std.ArrayList(ImportItem).init(alloc),
        };
    }

    fn deinit(self: *CApiImports) void {
        self.entries.deinit();
    }
};

pub const zwasm_imports_t = CApiImports;

/// Trampoline context stored per-import for bridging C callbacks to Zig HostFn.
/// These are stored in a global registry so the trampoline can look them up.
var trampoline_registry: std.ArrayList(CHostFn) = .empty;
var trampoline_registry_alloc: ?std.mem.Allocator = null;

fn ensureTrampolineRegistry(alloc: std.mem.Allocator) void {
    if (trampoline_registry_alloc == null) {
        trampoline_registry = std.ArrayList(CHostFn).init(alloc);
        trampoline_registry_alloc = alloc;
    }
}

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
// Module lifecycle
// ============================================================

/// Create a new Wasm module from binary bytes.
/// Returns null on error — call `zwasm_last_error_message()` for details.
export fn zwasm_module_new(wasm_ptr: [*]const u8, len: usize) ?*zwasm_module_t {
    clearError();
    return CApiModule.create(wasm_ptr[0..len], false) catch |err| {
        setError(err);
        return null;
    };
}

/// Create a new WASI module from binary bytes.
/// Returns null on error — call `zwasm_last_error_message()` for details.
export fn zwasm_module_new_wasi(wasm_ptr: [*]const u8, len: usize) ?*zwasm_module_t {
    clearError();
    return CApiModule.create(wasm_ptr[0..len], true) catch |err| {
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
    var gpa = Gpa{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
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
    args: ?[*]u64,
    nargs: u32,
    results: ?[*]u64,
    nresults: u32,
) bool {
    clearError();
    const name = std.mem.sliceTo(name_ptr, 0);
    const args_slice = if (args) |a| a[0..nargs] else &[_]u64{};
    const results_slice = if (results) |r| r[0..nresults] else &[_]u64{};
    module.module.invoke(name, args_slice, results_slice) catch |err| {
        setError(err);
        return false;
    };
    return true;
}

/// Invoke the _start function (WASI entry point). Returns false on error.
export fn zwasm_module_invoke_start(module: *zwasm_module_t) bool {
    clearError();
    module.module.invoke("_start", &[_]u64{}, &[_]u64{}) catch |err| {
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

// ============================================================
// WASI configuration
// ============================================================

/// Opaque WASI configuration handle.
const CApiWasiConfig = struct {
    argv: std.ArrayList([*:0]const u8),
    env_keys: std.ArrayList([*]const u8),
    env_vals: std.ArrayList([*]const u8),
    env_key_lens: std.ArrayList(usize),
    env_val_lens: std.ArrayList(usize),
    preopen_host: std.ArrayList([*]const u8),
    preopen_guest: std.ArrayList([*]const u8),
    preopen_host_lens: std.ArrayList(usize),
    preopen_guest_lens: std.ArrayList(usize),

    fn init() CApiWasiConfig {
        const alloc = std.heap.page_allocator;
        return .{
            .argv = std.ArrayList([*:0]const u8).init(alloc),
            .env_keys = std.ArrayList([*]const u8).init(alloc),
            .env_vals = std.ArrayList([*]const u8).init(alloc),
            .env_key_lens = std.ArrayList(usize).init(alloc),
            .env_val_lens = std.ArrayList(usize).init(alloc),
            .preopen_host = std.ArrayList([*]const u8).init(alloc),
            .preopen_guest = std.ArrayList([*]const u8).init(alloc),
            .preopen_host_lens = std.ArrayList(usize).init(alloc),
            .preopen_guest_lens = std.ArrayList(usize).init(alloc),
        };
    }

    fn deinit(self: *CApiWasiConfig) void {
        self.argv.deinit();
        self.env_keys.deinit();
        self.env_vals.deinit();
        self.env_key_lens.deinit();
        self.env_val_lens.deinit();
        self.preopen_host.deinit();
        self.preopen_guest.deinit();
        self.preopen_host_lens.deinit();
        self.preopen_guest_lens.deinit();
    }
};

pub const zwasm_wasi_config_t = CApiWasiConfig;

/// Create a new WASI configuration handle.
export fn zwasm_wasi_config_new() ?*zwasm_wasi_config_t {
    const config = std.heap.page_allocator.create(CApiWasiConfig) catch return null;
    config.* = CApiWasiConfig.init();
    return config;
}

/// Free a WASI configuration handle.
export fn zwasm_wasi_config_delete(config: *zwasm_wasi_config_t) void {
    config.deinit();
    std.heap.page_allocator.destroy(config);
}

/// Set command-line arguments for WASI. argv entries are null-terminated C strings.
export fn zwasm_wasi_config_set_argv(config: *zwasm_wasi_config_t, argc: u32, argv: [*]const [*:0]const u8) void {
    config.argv.clearRetainingCapacity();
    for (0..argc) |i| {
        config.argv.append(argv[i]) catch {};
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
        config.env_keys.append(keys[i]) catch {};
        config.env_vals.append(vals[i]) catch {};
        config.env_key_lens.append(key_lens[i]) catch {};
        config.env_val_lens.append(val_lens[i]) catch {};
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
    config.preopen_host.append(host_path) catch {};
    config.preopen_host_lens.append(host_path_len) catch {};
    config.preopen_guest.append(guest_path) catch {};
    config.preopen_guest_lens.append(guest_path_len) catch {};
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
    const gpa_alloc = std.heap.page_allocator;
    const env_keys = gpa_alloc.alloc([]const u8, config.env_keys.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer gpa_alloc.free(env_keys);
    const env_vals = gpa_alloc.alloc([]const u8, config.env_vals.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer gpa_alloc.free(env_vals);
    for (config.env_keys.items, config.env_key_lens.items, 0..) |ptr, l, i| {
        env_keys[i] = ptr[0..l];
    }
    for (config.env_vals.items, config.env_val_lens.items, 0..) |ptr, l, i| {
        env_vals[i] = ptr[0..l];
    }

    // preopens: build slices
    const preopens = gpa_alloc.alloc([]const u8, config.preopen_host.items.len) catch {
        setError(error.OutOfMemory);
        return null;
    };
    defer gpa_alloc.free(preopens);
    for (config.preopen_host.items, config.preopen_host_lens.items, 0..) |ptr, l, i| {
        preopens[i] = ptr[0..l];
    }

    const opts = WasiOptions{
        .args = argv_slice,
        .env_keys = env_keys,
        .env_vals = env_vals,
        .preopen_paths = preopens,
    };

    return CApiModule.createWasiConfigured(wasm_ptr[0..len], opts) catch |err| {
        setError(err);
        return null;
    };
}

// ============================================================
// Host function imports
// ============================================================

/// Create a new import collection.
export fn zwasm_import_new() ?*zwasm_imports_t {
    const alloc = std.heap.page_allocator;
    const imports = alloc.create(CApiImports) catch return null;
    imports.* = CApiImports.init(alloc);
    return imports;
}

/// Free an import collection.
export fn zwasm_import_delete(imports: *zwasm_imports_t) void {
    const alloc = imports.alloc;
    imports.deinit();
    alloc.destroy(imports);
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
    imports.entries.append(.{
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
    const alloc = std.heap.page_allocator;
    ensureTrampolineRegistry(alloc);

    // Collect unique module names
    var module_names = std.ArrayList([]const u8).init(alloc);
    defer module_names.deinit();
    for (imports.entries.items) |entry| {
        var found = false;
        for (module_names.items) |name| {
            if (std.mem.eql(u8, name, entry.module_name)) {
                found = true;
                break;
            }
        }
        if (!found) module_names.append(entry.module_name) catch {};
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
            trampoline_registry.append(entry.host_fn) catch {
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

    const result = CApiModule.createWithImports(wasm_ptr[0..len], import_entries) catch |err| {
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
    "\x07\x0d\x02\x01\x6d\x02\x00" ++ // export "m" = memory 0
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
