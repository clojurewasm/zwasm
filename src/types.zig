// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Wasm module and function types — the primary public API of zwasm.
//!
//! Provides WasmModule (load, invoke, memory access) and WasmFn (bound export)
//! types. All external interfaces use raw u64 values matching the Wasm spec.
//! Embedders wrap u64 in their own type system.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wit_parser = @import("wit_parser.zig");
const wit = @import("wit.zig");
const component = @import("component.zig");

// Internal Wasm runtime modules
const rt = struct {
    const store_mod = @import("store.zig");
    const module_mod = @import("module.zig");
    const instance_mod = @import("instance.zig");
    const vm_mod = @import("vm.zig");
    const wasi = @import("wasi.zig");
    const opcode = @import("opcode.zig");
    const wat = @import("wat.zig");
    const validate = @import("validate.zig");
};

// ============================================================
// Internal runtime types (for advanced embedders / test runners)
// ============================================================

/// Re-exports of internal runtime types for direct Store/Module/Instance access.
/// Used by the E2E test runner for shared-Store cross-module testing.
pub const runtime = struct {
    pub const Store = rt.store_mod.Store;
    pub const Module = rt.module_mod.Module;
    pub const Instance = rt.instance_mod.Instance;
    pub const VmImpl = rt.vm_mod.Vm;
};

// ============================================================
// Public types
// ============================================================

/// The Wasm virtual machine type. Exposed for host function callbacks.
/// The ctx_ptr in HostFn callbacks is a `*Vm` — recover via @ptrCast(@alignCast(ctx_ptr)).
/// Provides pushOperand/popOperand for stack access from host functions.
pub const Vm = rt.vm_mod.Vm;

/// WebAssembly value types exposed through the public API.
pub const WasmValType = enum {
    i32,
    i64,
    f32,
    f64,
    v128,
    funcref,
    externref,

    /// Convert an internal runtime ValType to a public WasmValType.
    pub fn fromRuntime(vt: rt.opcode.ValType) ?WasmValType {
        return switch (vt) {
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
            .v128 => .v128,
            .funcref => .funcref,
            .externref => .externref,
            else => null,
        };
    }
};

/// Metadata for an exported function, extracted from the Wasm binary at load time.
/// Use `WasmModule.getExportInfo()` to look up by name.
pub const ExportInfo = struct {
    /// The export name as declared in the Wasm binary.
    name: []const u8,
    /// Parameter types of the function signature.
    param_types: []const WasmValType,
    /// Result types of the function signature.
    result_types: []const WasmValType,
};

/// Host function callback type.
/// Called by the Wasm VM when an imported host function is invoked.
/// ctx_ptr: opaque pointer to the VM instance.
/// context_id: embedder-defined context for identifying the host function.
pub const HostFn = rt.store_mod.HostFn;

/// A single host function entry for import registration.
/// Used in `ImportSource.host_fns` to provide native callbacks to Wasm modules.
pub const HostFnEntry = struct {
    /// Function name matching the Wasm import declaration.
    name: []const u8,
    /// Native callback invoked when the Wasm module calls this import.
    callback: HostFn,
    /// Embedder-defined identifier passed to the callback for dispatch.
    context: usize,
};

/// Source of imported functions for a given module name.
pub const ImportSource = union(enum) {
    /// Import functions from another WasmModule's exports.
    wasm_module: *WasmModule,
    /// Import host (native) callback functions.
    host_fns: []const HostFnEntry,
};

/// Maps a Wasm import module name to a source of functions.
/// Pass a slice of these to `WasmModule.loadWithImports()`.
pub const ImportEntry = struct {
    /// The module name in the Wasm import declaration (e.g., "env", "math").
    module: []const u8,
    /// Where to resolve the imported functions from.
    source: ImportSource,
};

/// Metadata for an imported function, extracted from the Wasm binary's import section.
/// Returned by `inspectImportFunctions()` for embedder pre-analysis.
pub const ImportFuncInfo = struct {
    module: []const u8,
    name: []const u8,
    param_count: u32,
    result_count: u32,
};

/// Decode a Wasm binary and return metadata for all imported functions.
/// Useful for embedders that need param/result counts before instantiation
/// (e.g., to set up host function trampolines).
/// The returned slices reference `wasm_bytes` — caller must keep it alive.
pub fn inspectImportFunctions(allocator: Allocator, wasm_bytes: []const u8) ![]const ImportFuncInfo {
    var module = rt.module_mod.Module.init(allocator, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var count: usize = 0;
    for (module.imports.items) |imp| {
        if (imp.kind == .func) count += 1;
    }
    if (count == 0) return &[_]ImportFuncInfo{};

    const result = try allocator.alloc(ImportFuncInfo, count);
    var idx: usize = 0;
    for (module.imports.items) |imp| {
        if (imp.kind != .func) continue;
        const functype = module.getTypeFunc(imp.index) orelse continue;
        result[idx] = .{
            .module = imp.module,
            .name = imp.name,
            .param_count = @intCast(functype.params.len),
            .result_count = @intCast(functype.results.len),
        };
        idx += 1;
    }
    if (idx < count) return result[0..idx];
    return result;
}

/// WASI capability flags for deny-by-default security.
pub const Capabilities = rt.wasi.Capabilities;

/// Options for configuring WASI modules.
pub const WasiOptions = struct {
    /// Command-line arguments passed to the WASI module.
    args: []const [:0]const u8 = &.{},
    /// Environment variables as key-value string pairs.
    env_keys: []const []const u8 = &.{},
    env_vals: []const []const u8 = &.{},
    /// Preopened directories. Each entry maps a WASI fd to a host path.
    preopen_paths: []const []const u8 = &.{},
    /// WASI capability flags. Default: all capabilities granted.
    caps: rt.wasi.Capabilities = rt.wasi.Capabilities.all,
};

// ============================================================
// WasmModule — loaded and instantiated Wasm module
// ============================================================

/// A loaded and instantiated Wasm module.
/// Heap-allocated because Instance holds internal pointers — the
/// struct must not move after instantiation.
pub const WasmModule = struct {
    allocator: Allocator,
    store: rt.store_mod.Store,
    module: rt.module_mod.Module,
    instance: rt.instance_mod.Instance,
    wasi_ctx: ?rt.wasi.WasiContext = null,
    export_fns: []const ExportInfo = &[_]ExportInfo{},
    /// Pre-generated WasmFn instances for name lookup dispatch.
    cached_fns: []WasmFn = &[_]WasmFn{},
    /// WIT function signatures (set via setWitInfo).
    wit_funcs: []const wit_parser.WitFunc = &[_]wit_parser.WitFunc{},
    /// Cached VM instance — reused across invoke() calls to avoid stack reallocation.
    vm: *rt.vm_mod.Vm = undefined,
    /// Owned wasm bytes (from WAT conversion). Freed on deinit.
    owned_wasm_bytes: ?[]const u8 = null,

    /// Load a Wasm module from binary bytes, decode, and instantiate.
    pub fn load(allocator: Allocator, wasm_bytes: []const u8) !*WasmModule {
        return loadCore(allocator, wasm_bytes, false, null);
    }

    /// Load a module from WAT (WebAssembly Text Format) source.
    /// Requires `-Dwat=true` (default). Returns error.WatNotEnabled if disabled.
    pub fn loadFromWat(allocator: Allocator, wat_source: []const u8) !*WasmModule {
        const wasm_bytes = try rt.wat.watToWasm(allocator, wat_source);
        errdefer allocator.free(wasm_bytes);
        const self = try loadCore(allocator, wasm_bytes, false, null);
        self.owned_wasm_bytes = wasm_bytes;
        return self;
    }

    /// Load a WASI module — registers wasi_snapshot_preview1 imports.
    pub fn loadWasi(allocator: Allocator, wasm_bytes: []const u8) !*WasmModule {
        return loadCore(allocator, wasm_bytes, true, null);
    }

    /// Load a WASI module with custom args, env, and preopened directories.
    pub fn loadWasiWithOptions(allocator: Allocator, wasm_bytes: []const u8, opts: WasiOptions) !*WasmModule {
        const self = try loadCore(allocator, wasm_bytes, true, null);
        errdefer self.deinit();

        if (self.wasi_ctx) |*wc| {
            wc.caps = opts.caps;
            if (opts.args.len > 0) wc.setArgs(opts.args);

            const count = @min(opts.env_keys.len, opts.env_vals.len);
            for (0..count) |i| {
                try wc.addEnv(opts.env_keys[i], opts.env_vals[i]);
            }

            for (opts.preopen_paths, 0..) |path, i| {
                const fd: i32 = @intCast(3 + i);
                const host_fd = std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
                try wc.addPreopen(fd, path, host_fd);
            }
        }

        return self;
    }

    /// Load with imports from other modules or host functions.
    pub fn loadWithImports(allocator: Allocator, wasm_bytes: []const u8, imports: []const ImportEntry) !*WasmModule {
        return loadCore(allocator, wasm_bytes, false, imports);
    }

    /// Load with combined WASI + import support. Used by CLI for --link + WASI fallback.
    pub fn loadWasiWithImports(allocator: Allocator, wasm_bytes: []const u8, imports: ?[]const ImportEntry, opts: WasiOptions) !*WasmModule {
        const self = try loadCore(allocator, wasm_bytes, true, imports);
        errdefer self.deinit();

        if (self.wasi_ctx) |*wc| {
            wc.caps = opts.caps;
            if (opts.args.len > 0) wc.setArgs(opts.args);

            const count = @min(opts.env_keys.len, opts.env_vals.len);
            for (0..count) |i| {
                try wc.addEnv(opts.env_keys[i], opts.env_vals[i]);
            }

            for (opts.preopen_paths, 0..) |path, ii| {
                const fd: i32 = @intCast(3 + ii);
                const host_fd = std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
                try wc.addPreopen(fd, path, host_fd);
            }
        }

        return self;
    }

    fn loadCore(allocator: Allocator, wasm_bytes: []const u8, wasi: bool, imports: ?[]const ImportEntry) !*WasmModule {
        const self = try allocator.create(WasmModule);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.owned_wasm_bytes = null;
        self.store = rt.store_mod.Store.init(allocator);
        errdefer self.store.deinit();

        self.module = rt.module_mod.Module.init(allocator, wasm_bytes);
        errdefer self.module.deinit();
        try self.module.decode();

        if (wasi) {
            try rt.wasi.registerAll(&self.store, &self.module);
            self.wasi_ctx = rt.wasi.WasiContext.init(allocator);
            self.wasi_ctx.?.caps = rt.wasi.Capabilities.all;
        } else {
            self.wasi_ctx = null;
        }
        errdefer if (self.wasi_ctx) |*wc| wc.deinit();

        if (imports) |import_entries| {
            try registerImports(&self.store, &self.module, import_entries, allocator);
        }

        self.instance = rt.instance_mod.Instance.init(allocator, &self.store, &self.module);
        errdefer self.instance.deinit();
        if (self.wasi_ctx) |*wc| self.instance.wasi = wc;
        try self.instance.instantiate();

        self.export_fns = buildExportInfo(allocator, &self.module) catch &[_]ExportInfo{};
        self.cached_fns = buildCachedFns(allocator, self) catch &[_]WasmFn{};
        self.wit_funcs = &[_]wit_parser.WitFunc{};

        self.vm = try allocator.create(rt.vm_mod.Vm);
        self.vm.* = rt.vm_mod.Vm.init(allocator);

        // Execute start function if present
        if (self.module.start) |start_idx| {
            self.vm.reset();
            try self.vm.invokeByIndex(&self.instance, start_idx, &.{}, &.{});
        }

        return self;
    }

    /// Release all resources held by this module (VM, instance, store, WASI context).
    /// After calling deinit, the module pointer is invalid.
    pub fn deinit(self: *WasmModule) void {
        const allocator = self.allocator;
        if (self.cached_fns.len > 0) allocator.free(self.cached_fns);
        for (self.export_fns) |ei| {
            allocator.free(ei.param_types);
            allocator.free(ei.result_types);
        }
        if (self.export_fns.len > 0) allocator.free(self.export_fns);
        allocator.destroy(self.vm);
        self.instance.deinit();
        if (self.wasi_ctx) |*wc| wc.deinit();
        self.module.deinit();
        self.store.deinit();
        if (self.owned_wasm_bytes) |bytes| allocator.free(bytes);
        allocator.destroy(self);
    }

    /// Invoke an exported function by name.
    /// Args and results are passed as u64 arrays.
    pub fn invoke(self: *WasmModule, name: []const u8, args: []u64, results: []u64) !void {
        self.vm.reset();
        try self.vm.invoke(&self.instance, name, args, results);
    }

    /// Read bytes from linear memory at the given offset.
    /// The returned slice is owned by the caller and must be freed with `allocator`.
    pub fn memoryRead(self: *WasmModule, allocator: Allocator, offset: u32, length: u32) ![]const u8 {
        const mem = try self.instance.getMemory(0);
        const mem_bytes = mem.memory();
        const end = @as(u64, offset) + @as(u64, length);
        if (end > mem_bytes.len) return error.OutOfBoundsMemoryAccess;
        const result = try allocator.alloc(u8, length);
        @memcpy(result, mem_bytes[offset..][0..length]);
        return result;
    }

    /// Write bytes to linear memory at the given offset.
    pub fn memoryWrite(self: *WasmModule, offset: u32, data: []const u8) !void {
        const mem = try self.instance.getMemory(0);
        const mem_bytes = mem.memory();
        const end = @as(u64, offset) + @as(u64, data.len);
        if (end > mem_bytes.len) return error.OutOfBoundsMemoryAccess;
        @memcpy(mem_bytes[offset..][0..data.len], data);
    }

    /// Attach WIT info parsed from a .wit file.
    pub fn setWitInfo(self: *WasmModule, funcs: []const wit_parser.WitFunc) void {
        self.wit_funcs = funcs;
        for (self.cached_fns) |*cf| {
            for (funcs) |wf| {
                if (std.mem.eql(u8, cf.name, wf.name)) {
                    cf.wit_params = wf.params;
                    cf.wit_result = wf.result;
                    break;
                }
            }
        }
    }

    /// Get WIT function info by name.
    pub fn getWitFunc(self: *const WasmModule, name: []const u8) ?wit_parser.WitFunc {
        for (self.wit_funcs) |wf| {
            if (std.mem.eql(u8, wf.name, name)) return wf;
        }
        return null;
    }

    /// Lookup export function info by name.
    pub fn getExportInfo(self: *const WasmModule, name: []const u8) ?ExportInfo {
        for (self.export_fns) |ei| {
            if (std.mem.eql(u8, ei.name, name)) return ei;
        }
        return null;
    }

    /// Get the WASI exit code, if the module called proc_exit().
    /// Returns null if the module is not WASI or proc_exit was not called.
    pub fn getWasiExitCode(self: *const WasmModule) ?u32 {
        const wc = self.wasi_ctx orelse return null;
        return wc.exit_code;
    }

    /// Lookup a cached WasmFn by export name.
    pub fn getExportFn(self: *const WasmModule, name: []const u8) ?*const WasmFn {
        for (self.cached_fns) |*wf| {
            if (std.mem.eql(u8, wf.name, name)) return wf;
        }
        return null;
    }
};

// ============================================================
// WasmFn — bound Wasm function (module + export name + signature)
// ============================================================

/// A bound Wasm function — module ref + export name + signature.
/// Callable via the raw u64 invoke interface.
pub const WasmFn = struct {
    module: *WasmModule,
    name: []const u8,
    param_types: []const WasmValType,
    result_types: []const WasmValType,
    /// WIT-level parameter types (null = no WIT info, use raw core types).
    wit_params: ?[]const wit_parser.WitParam = null,
    /// WIT-level result type (null = no WIT info).
    wit_result: ?wit_parser.WitType = null,

    /// Invoke this function with raw u64 arguments.
    pub fn invokeRaw(self: *const WasmFn, args: []u64, results: []u64) !void {
        try self.module.invoke(self.name, args, results);
    }

    fn cabiRealloc(self: *const WasmFn, size: u32) !u32 {
        var realloc_args = [_]u64{ 0, 0, 1, size };
        var realloc_results = [_]u64{0};
        self.module.invoke("cabi_realloc", &realloc_args, &realloc_results) catch
            return error.WasmAllocError;
        return @truncate(realloc_results[0]);
    }
};

// ============================================================
// Import registration (struct-based API)
// ============================================================

/// Register all import entries (wasm module links + host functions).
fn registerImports(
    store: *rt.store_mod.Store,
    module: *const rt.module_mod.Module,
    imports: []const ImportEntry,
    allocator: Allocator,
) !void {
    _ = allocator;
    for (module.imports.items) |imp| {
        if (std.mem.eql(u8, imp.module, "wasi_snapshot_preview1")) continue;

        // Find the matching import entry
        const entry = findImportEntry(imports, imp.module) orelse continue;

        switch (entry.source) {
            .wasm_module => |src_module| {
                switch (imp.kind) {
                    .func => {
                        // Copy exported function from source module's store
                        const export_addr = src_module.instance.getExportFunc(imp.name) orelse
                            return error.ImportNotFound;

                        var src_func = src_module.store.getFunction(export_addr) catch
                            return error.ImportNotFound;
                        // Reset cached pointers to avoid double-free across stores
                        if (src_func.subtype == .wasm_function) {
                            src_func.subtype.wasm_function.branch_table = null;
                            src_func.subtype.wasm_function.ir = null;
                            src_func.subtype.wasm_function.ir_failed = false;
                            src_func.subtype.wasm_function.reg_ir = null;
                            src_func.subtype.wasm_function.reg_ir_failed = false;
                            src_func.subtype.wasm_function.jit_code = null;
                            src_func.subtype.wasm_function.jit_failed = false;
                            src_func.subtype.wasm_function.call_count = 0;
                        }
                        const addr = store.addFunction(src_func) catch
                            return error.WasmInstantiateError;
                        store.addExport(imp.module, imp.name, .func, addr) catch
                            return error.WasmInstantiateError;
                    },
                    .memory => {
                        // Share memory from source module (copy struct, mark as borrowed)
                        const src_addr = src_module.instance.getExportMemAddr(imp.name) orelse
                            return error.ImportNotFound;
                        var src_mem = (src_module.store.getMemory(src_addr) catch
                            return error.ImportNotFound).*;
                        src_mem.shared = true;
                        const addr = store.addExistingMemory(src_mem) catch
                            return error.WasmInstantiateError;
                        store.addExport(imp.module, imp.name, .memory, addr) catch
                            return error.WasmInstantiateError;
                    },
                    .table => {
                        // Share table from source module: copy struct and remap function refs
                        const src_addr = src_module.instance.getExportTableAddr(imp.name) orelse
                            return error.ImportNotFound;
                        const src_table_ptr = src_module.store.getTable(src_addr) catch
                            return error.ImportNotFound;
                        var src_table = src_table_ptr.*;
                        src_table.shared = true;
                        // Remap function references: copy referenced functions to target store
                        // Table entries use ?usize: null=empty, Some(addr)=valid func address
                        for (src_table.data.items) |*tbl_entry| {
                            if (tbl_entry.*) |src_func_ref| {
                                var func = src_module.store.getFunction(src_func_ref) catch continue;
                                if (func.subtype == .wasm_function) {
                                    func.subtype.wasm_function.branch_table = null;
                                    func.subtype.wasm_function.ir = null;
                                    func.subtype.wasm_function.ir_failed = false;
                                    func.subtype.wasm_function.reg_ir = null;
                                    func.subtype.wasm_function.reg_ir_failed = false;
                                    func.subtype.wasm_function.jit_code = null;
                                    func.subtype.wasm_function.jit_failed = false;
                                    func.subtype.wasm_function.call_count = 0;
                                }
                                const new_addr = store.addFunction(func) catch continue;
                                tbl_entry.* = new_addr;
                            }
                        }
                        const addr = store.addExistingTable(src_table) catch
                            return error.WasmInstantiateError;
                        store.addExport(imp.module, imp.name, .table, addr) catch
                            return error.WasmInstantiateError;
                    },
                    .global => {
                        // Copy global from source module
                        const src_addr = src_module.instance.getExportGlobalAddr(imp.name) orelse
                            return error.ImportNotFound;
                        var glob = (src_module.store.getGlobal(src_addr) catch
                            return error.ImportNotFound).*;
                        // Remap funcref values: copy referenced function to target store
                        if (glob.valtype == .funcref and glob.value > 0) {
                            const src_func_addr: usize = @intCast(glob.value - 1);
                            var func = src_module.store.getFunction(src_func_addr) catch
                                return error.ImportNotFound;
                            if (func.subtype == .wasm_function) {
                                func.subtype.wasm_function.branch_table = null;
                                func.subtype.wasm_function.ir = null;
                                func.subtype.wasm_function.ir_failed = false;
                                func.subtype.wasm_function.reg_ir = null;
                                func.subtype.wasm_function.reg_ir_failed = false;
                                func.subtype.wasm_function.jit_code = null;
                                func.subtype.wasm_function.jit_failed = false;
                                func.subtype.wasm_function.call_count = 0;
                            }
                            const new_func_addr = store.addFunction(func) catch
                                return error.WasmInstantiateError;
                            glob.value = @as(u128, @intCast(new_func_addr)) + 1;
                        }
                        const addr = store.addGlobal(glob) catch
                            return error.WasmInstantiateError;
                        store.addExport(imp.module, imp.name, .global, addr) catch
                            return error.WasmInstantiateError;
                    },
                    .tag => {
                        // Copy tag preserving its identity (tag_id) for cross-module matching
                        const src_addr = src_module.instance.getExportTagAddr(imp.name) orelse
                            return error.ImportNotFound;
                        const src_tag = src_module.store.tags.items[src_addr];
                        const addr = store.addTagWithId(src_tag.type_idx, src_tag.tag_id) catch
                            return error.WasmInstantiateError;
                        store.addExport(imp.module, imp.name, .tag, addr) catch
                            return error.WasmInstantiateError;
                    },
                }
            },
            .host_fns => |host_fns| {
                if (imp.kind != .func) continue;
                // Register host callback function
                const host_entry = findHostFn(host_fns, imp.name) orelse continue;

                const functype = module.getTypeFunc(imp.index) orelse continue;

                store.exposeHostFunction(
                    imp.module,
                    imp.name,
                    host_entry.callback,
                    host_entry.context,
                    functype.params,
                    functype.results,
                ) catch return error.WasmInstantiateError;
            },
        }
    }
}

fn findImportEntry(imports: []const ImportEntry, module_name: []const u8) ?ImportEntry {
    for (imports) |entry| {
        if (std.mem.eql(u8, entry.module, module_name)) return entry;
    }
    return null;
}

fn findHostFn(host_fns: []const HostFnEntry, func_name: []const u8) ?HostFnEntry {
    for (host_fns) |entry| {
        if (std.mem.eql(u8, entry.name, func_name)) return entry;
    }
    return null;
}

// ============================================================
// Internal helpers
// ============================================================

/// Build export function info by introspecting the Wasm binary's exports + types.
fn buildExportInfo(allocator: Allocator, module: *const rt.module_mod.Module) ![]const ExportInfo {
    var func_count: usize = 0;
    for (module.exports.items) |exp| {
        if (exp.kind == .func) func_count += 1;
    }
    if (func_count == 0) return &[_]ExportInfo{};

    const infos = try allocator.alloc(ExportInfo, func_count);
    errdefer allocator.free(infos);

    var idx: usize = 0;
    for (module.exports.items) |exp| {
        if (exp.kind != .func) continue;

        const functype = module.getFuncType(exp.index) orelse continue;

        const params = try allocator.alloc(WasmValType, functype.params.len);
        errdefer allocator.free(params);
        var valid = true;
        for (functype.params, 0..) |p, i| {
            params[i] = WasmValType.fromRuntime(p) orelse {
                valid = false;
                break;
            };
        }
        if (!valid) {
            allocator.free(params);
            continue;
        }

        const results = try allocator.alloc(WasmValType, functype.results.len);
        errdefer allocator.free(results);
        for (functype.results, 0..) |r, i| {
            results[i] = WasmValType.fromRuntime(r) orelse {
                valid = false;
                break;
            };
        }
        if (!valid) {
            allocator.free(params);
            allocator.free(results);
            continue;
        }

        infos[idx] = .{
            .name = exp.name,
            .param_types = params,
            .result_types = results,
        };
        idx += 1;
    }

    if (idx < func_count) {
        if (idx == 0) {
            allocator.free(infos);
            return &[_]ExportInfo{};
        }
        const trimmed = try allocator.alloc(ExportInfo, idx);
        @memcpy(trimmed, infos[0..idx]);
        allocator.free(infos);
        return trimmed;
    }

    return infos;
}

/// Pre-generate WasmFn instances for all exports.
fn buildCachedFns(allocator: Allocator, wasm_mod: *WasmModule) ![]WasmFn {
    const exports = wasm_mod.export_fns;
    if (exports.len == 0) return &[_]WasmFn{};

    const fns = try allocator.alloc(WasmFn, exports.len);
    for (exports, 0..) |ei, i| {
        fns[i] = .{
            .module = wasm_mod,
            .name = ei.name,
            .param_types = ei.param_types,
            .result_types = ei.result_types,
        };
    }
    return fns;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "smoke test — load and call add(3, 4)" {
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{ 3, 4 };
    var results = [_]u64{0};
    try wasm_mod.invoke("add", &args, &results);

    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "smoke test — fibonacci(10) = 55" {
    const wasm_bytes = @embedFile("testdata/02_fibonacci.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{10};
    var results = [_]u64{0};
    try wasm_mod.invoke("fib", &args, &results);

    try testing.expectEqual(@as(u64, 55), results[0]);
}

test "memory read/write round-trip" {
    const wasm_bytes = @embedFile("testdata/03_memory.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    try wasm_mod.memoryWrite(0, "Hello");
    const read_back = try wasm_mod.memoryRead(testing.allocator, 0, 5);
    defer testing.allocator.free(read_back);
    try testing.expectEqualStrings("Hello", read_back);

    try wasm_mod.memoryWrite(1024, "Wasm");
    const read2 = try wasm_mod.memoryRead(testing.allocator, 1024, 4);
    defer testing.allocator.free(read2);
    try testing.expectEqualStrings("Wasm", read2);
}

test "memory write then call store/load" {
    const wasm_bytes = @embedFile("testdata/03_memory.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var store_args = [_]u64{ 0, 42 };
    var store_results = [_]u64{};
    try wasm_mod.invoke("store", &store_args, &store_results);

    var load_args = [_]u64{0};
    var load_results = [_]u64{0};
    try wasm_mod.invoke("load", &load_args, &load_results);
    try testing.expectEqual(@as(u64, 42), load_results[0]);

    const raw = try wasm_mod.memoryRead(testing.allocator, 0, 4);
    defer testing.allocator.free(raw);
    const value = std.mem.readInt(u32, raw[0..4], .little);
    try testing.expectEqual(@as(u32, 42), value);
}

test "buildExportInfo — add module exports" {
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    try testing.expect(wasm_mod.export_fns.len > 0);
    const add_info = wasm_mod.getExportInfo("add");
    try testing.expect(add_info != null);
    const info = add_info.?;
    try testing.expectEqual(@as(usize, 2), info.param_types.len);
    try testing.expectEqual(WasmValType.i32, info.param_types[0]);
    try testing.expectEqual(WasmValType.i32, info.param_types[1]);
    try testing.expectEqual(@as(usize, 1), info.result_types.len);
    try testing.expectEqual(WasmValType.i32, info.result_types[0]);
}

test "buildExportInfo — fibonacci module exports" {
    const wasm_bytes = @embedFile("testdata/02_fibonacci.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    const fib_info = wasm_mod.getExportInfo("fib");
    try testing.expect(fib_info != null);
    const info = fib_info.?;
    try testing.expectEqual(@as(usize, 1), info.param_types.len);
    try testing.expectEqual(WasmValType.i32, info.param_types[0]);
    try testing.expectEqual(@as(usize, 1), info.result_types.len);
    try testing.expectEqual(WasmValType.i32, info.result_types[0]);
}

test "buildExportInfo — memory module exports" {
    const wasm_bytes = @embedFile("testdata/03_memory.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    const store_info = wasm_mod.getExportInfo("store");
    try testing.expect(store_info != null);
    try testing.expectEqual(@as(usize, 2), store_info.?.param_types.len);
    try testing.expectEqual(@as(usize, 0), store_info.?.result_types.len);

    const load_info = wasm_mod.getExportInfo("load");
    try testing.expect(load_info != null);
    try testing.expectEqual(@as(usize, 1), load_info.?.param_types.len);
    try testing.expectEqual(@as(usize, 1), load_info.?.result_types.len);
}

test "getExportInfo — nonexistent name returns null" {
    const wasm_bytes = @embedFile("testdata/01_add.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    try testing.expect(wasm_mod.getExportInfo("nonexistent") == null);
}

// Multi-module linking tests (using ImportEntry)

test "multi-module — two modules, function import" {
    // math_mod exports "add" and "mul"
    const math_bytes = @embedFile("testdata/20_math_export.wasm");
    var math_mod = try WasmModule.load(testing.allocator, math_bytes);
    defer math_mod.deinit();

    // Verify math module works standalone
    var add_args = [_]u64{ 3, 4 };
    var add_results = [_]u64{0};
    try math_mod.invoke("add", &add_args, &add_results);
    try testing.expectEqual(@as(u64, 7), add_results[0]);

    // app_mod imports "add" and "mul" from "math", exports "add_and_mul"
    const app_bytes = @embedFile("testdata/21_app_import.wasm");
    var app_mod = try WasmModule.loadWithImports(testing.allocator, app_bytes, &.{
        .{ .module = "math", .source = .{ .wasm_module = math_mod } },
    });
    defer app_mod.deinit();

    // add_and_mul(3, 4, 5) = (3 + 4) * 5 = 35
    var args = [_]u64{ 3, 4, 5 };
    var results = [_]u64{0};
    try app_mod.invoke("add_and_mul", &args, &results);
    try testing.expectEqual(@as(u64, 35), results[0]);
}

test "multi-module — three module chain" {
    // base exports "double"
    const base_bytes = @embedFile("testdata/22_base.wasm");
    var base_mod = try WasmModule.load(testing.allocator, base_bytes);
    defer base_mod.deinit();

    // mid imports "double" from "base", exports "quadruple"
    const mid_bytes = @embedFile("testdata/23_mid.wasm");
    var mid_mod = try WasmModule.loadWithImports(testing.allocator, mid_bytes, &.{
        .{ .module = "base", .source = .{ .wasm_module = base_mod } },
    });
    defer mid_mod.deinit();

    // Verify mid: quadruple(5) = 20
    var mid_args = [_]u64{5};
    var mid_results = [_]u64{0};
    try mid_mod.invoke("quadruple", &mid_args, &mid_results);
    try testing.expectEqual(@as(u64, 20), mid_results[0]);

    // top imports "quadruple" from "mid", exports "octuple"
    const top_bytes = @embedFile("testdata/24_top.wasm");
    var top_mod = try WasmModule.loadWithImports(testing.allocator, top_bytes, &.{
        .{ .module = "mid", .source = .{ .wasm_module = mid_mod } },
    });
    defer top_mod.deinit();

    // octuple(3) = 3 * 8 = 24
    var top_args = [_]u64{3};
    var top_results = [_]u64{0};
    try top_mod.invoke("octuple", &top_args, &top_results);
    try testing.expectEqual(@as(u64, 24), top_results[0]);
}

test "multi-module — memory import" {
    // provider exports memory with "hello" at offset 0
    const provider_bytes = @embedFile("testdata/26_mem_export.wasm");
    var provider = try WasmModule.load(testing.allocator, provider_bytes);
    defer provider.deinit();

    // consumer imports memory from "provider", exports read_byte(offset) -> u8
    const consumer_bytes = @embedFile("testdata/27_mem_import.wasm");
    var consumer = try WasmModule.loadWithImports(testing.allocator, consumer_bytes, &.{
        .{ .module = "provider", .source = .{ .wasm_module = provider } },
    });
    defer consumer.deinit();

    // read_byte(0) = 'h' = 104
    var args0 = [_]u64{0};
    var res0 = [_]u64{0};
    try consumer.invoke("read_byte", &args0, &res0);
    try testing.expectEqual(@as(u64, 104), res0[0]);

    // read_byte(4) = 'o' = 111
    var args4 = [_]u64{4};
    var res4 = [_]u64{0};
    try consumer.invoke("read_byte", &args4, &res4);
    try testing.expectEqual(@as(u64, 111), res4[0]);
}

test "nqueens(8) = 92 — regir only (JIT disabled)" {
    const wasm_bytes = @embedFile("testdata/25_nqueens.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    // Enable profiling to disable JIT (JIT is skipped when profile != null)
    var profile = rt.vm_mod.Profile.init();
    wasm_mod.vm.profile = &profile;

    var args = [_]u64{8};
    var results = [_]u64{0};
    try wasm_mod.invoke("nqueens", &args, &results);

    try testing.expectEqual(@as(u64, 92), results[0]);
}

test "nqueens(8) = 92 — with JIT" {
    const wasm_bytes = @embedFile("testdata/25_nqueens.wasm");
    var wasm_mod = try WasmModule.load(testing.allocator, wasm_bytes);
    defer wasm_mod.deinit();

    var args = [_]u64{8};
    var results = [_]u64{0};
    try wasm_mod.invoke("nqueens", &args, &results);

    try testing.expectEqual(@as(u64, 92), results[0]);
}

// ============================================================
// WAT round-trip tests
// ============================================================

test "WAT round-trip — i32.add" {
    var wasm_mod = try WasmModule.loadFromWat(testing.allocator,
        \\(module
        \\  (func $add (param i32 i32) (result i32)
        \\    local.get 0
        \\    local.get 1
        \\    i32.add
        \\  )
        \\  (export "add" (func $add))
        \\)
    );
    defer wasm_mod.deinit();

    var args = [_]u64{ 3, 4 };
    var results = [_]u64{0};
    try wasm_mod.invoke("add", &args, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "WAT round-trip — i32.const" {
    var wasm_mod = try WasmModule.loadFromWat(testing.allocator,
        \\(module
        \\  (func (export "forty_two") (result i32)
        \\    i32.const 42
        \\  )
        \\)
    );
    defer wasm_mod.deinit();

    var results = [_]u64{0};
    try wasm_mod.invoke("forty_two", &[_]u64{}, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);
}

test "WAT round-trip — if/else" {
    var wasm_mod = try WasmModule.loadFromWat(testing.allocator,
        \\(module
        \\  (func (export "abs") (param i32) (result i32)
        \\    (if (result i32) (i32.lt_s (local.get 0) (i32.const 0))
        \\      (then (i32.sub (i32.const 0) (local.get 0)))
        \\      (else (local.get 0))
        \\    )
        \\  )
        \\)
    );
    defer wasm_mod.deinit();

    var args1 = [_]u64{@bitCast(@as(i64, -5))};
    var results = [_]u64{0};
    try wasm_mod.invoke("abs", &args1, &results);
    try testing.expectEqual(@as(u64, 5), results[0]);

    var args2 = [_]u64{7};
    try wasm_mod.invoke("abs", &args2, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "WAT round-trip — loop (factorial)" {
    var wasm_mod = try WasmModule.loadFromWat(testing.allocator,
        \\(module
        \\  (func (export "fac") (param i32) (result i32)
        \\    (local i32)
        \\    (local.set 1 (i32.const 1))
        \\    (block $done
        \\      (loop $loop
        \\        (br_if $done (i32.eqz (local.get 0)))
        \\        (local.set 1 (i32.mul (local.get 1) (local.get 0)))
        \\        (local.set 0 (i32.sub (local.get 0) (i32.const 1)))
        \\        (br $loop)
        \\      )
        \\    )
        \\    (local.get 1)
        \\  )
        \\)
    );
    defer wasm_mod.deinit();

    var args = [_]u64{5};
    var results = [_]u64{0};
    try wasm_mod.invoke("fac", &args, &results);
    try testing.expectEqual(@as(u64, 120), results[0]);
}

test "WAT round-trip — named locals" {
    var wasm_mod = try WasmModule.loadFromWat(testing.allocator,
        \\(module
        \\  (func (export "swap_sub") (param $a i32) (param $b i32) (result i32)
        \\    (i32.sub (local.get $b) (local.get $a))
        \\  )
        \\)
    );
    defer wasm_mod.deinit();

    var args = [_]u64{ 3, 10 };
    var results = [_]u64{0};
    try wasm_mod.invoke("swap_sub", &args, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "WAT round-trip — named globals" {
    var wasm_mod = try WasmModule.loadFromWat(testing.allocator,
        \\(module
        \\  (global $counter (mut i32) (i32.const 0))
        \\  (func (export "inc") (result i32)
        \\    (global.set $counter (i32.add (global.get $counter) (i32.const 1)))
        \\    (global.get $counter)
        \\  )
        \\)
    );
    defer wasm_mod.deinit();

    var results = [_]u64{0};
    try wasm_mod.invoke("inc", &[_]u64{}, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);
    try wasm_mod.invoke("inc", &[_]u64{}, &results);
    try testing.expectEqual(@as(u64, 2), results[0]);
}

test "WAT round-trip — return_call simple" {
    var wasm_mod = try WasmModule.loadFromWat(testing.allocator,
        \\(module
        \\  (func $get42 (result i32)
        \\    i32.const 42
        \\  )
        \\  (func $call42 (result i32)
        \\    return_call $get42
        \\  )
        \\  (export "call42" (func $call42))
        \\)
    );
    defer wasm_mod.deinit();

    var results = [_]u64{0};
    try wasm_mod.invoke("call42", &[_]u64{}, &results);
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, 42))), results[0]);
}

test "WAT round-trip — return_call mutual recursion" {
    var wasm_mod = try WasmModule.loadFromWat(testing.allocator,
        \\(module
        \\  (func $even (param i32) (result i32)
        \\    local.get 0
        \\    i32.eqz
        \\    if (result i32)
        \\      i32.const 1
        \\    else
        \\      local.get 0
        \\      i32.const 1
        \\      i32.sub
        \\      return_call $odd
        \\    end
        \\  )
        \\  (func $odd (param i32) (result i32)
        \\    local.get 0
        \\    i32.eqz
        \\    if (result i32)
        \\      i32.const 0
        \\    else
        \\      local.get 0
        \\      i32.const 1
        \\      i32.sub
        \\      return_call $even
        \\    end
        \\  )
        \\  (export "even" (func $even))
        \\)
    );
    defer wasm_mod.deinit();

    var results = [_]u64{0};
    var args4 = [_]u64{4};
    try wasm_mod.invoke("even", &args4, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);
    var args5 = [_]u64{5};
    try wasm_mod.invoke("even", &args5, &results);
    try testing.expectEqual(@as(u64, 0), results[0]);
}
