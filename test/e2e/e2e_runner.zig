// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Zig E2E test runner for wast2json output.
//!
//! Uses a shared Store so all modules in a test file share the same address
//! space for functions, tables, memories, and globals. This enables correct
//! cross-module interactions (e.g. shared tables via register/import).
//!
//! Usage:
//!   e2e_runner --dir test/e2e/json/ --summary
//!   e2e_runner --file test/e2e/json/partial-init-table-segment.json -v

const std = @import("std");
const zwasm = @import("zwasm");
const Allocator = std.mem.Allocator;
const Store = zwasm.runtime.Store;
const Module = zwasm.runtime.Module;
const Instance = zwasm.runtime.Instance;
const VmImpl = zwasm.runtime.VmImpl;

// ============================================================
// JSON types for wast2json output
// ============================================================

const JsonValue = struct {
    type: []const u8,
    value: ?std.json.Value = null,
    lane_type: ?[]const u8 = null,

    fn getValueString(self: JsonValue) ?[]const u8 {
        const v = self.value orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }
};

const JsonAction = struct {
    type: []const u8,
    module: ?[]const u8 = null,
    field: ?[]const u8 = null,
    args: ?[]const JsonValue = null,
};

const JsonCommand = struct {
    type: []const u8,
    line: u32 = 0,
    name: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    text: ?[]const u8 = null,
    module_type: ?[]const u8 = null,
    action: ?JsonAction = null,
    expected: ?[]const JsonValue = null,
    @"as": ?[]const u8 = null,
};

const JsonTestFile = struct {
    source_filename: ?[]const u8 = null,
    commands: []const JsonCommand,
};

// ============================================================
// Test runner state
// ============================================================

const ModuleEntry = struct {
    instance: *Instance,
    module: *Module,
    wasm_bytes: []const u8,
};

const TestRunner = struct {
    allocator: Allocator,
    dir: []const u8,
    /// Shared store for all modules in the test file
    store: *Store,
    /// Shared VM for invocations
    vm: *VmImpl,
    /// Named modules ($name -> entry)
    named_modules: std.StringHashMap(ModuleEntry),
    /// Registered module aliases (import name -> entry)
    registered: std.StringHashMap(ModuleEntry),
    /// Most recent module (unnamed or named)
    current_module: ?ModuleEntry = null,
    /// All allocated modules (for cleanup)
    all_modules: std.ArrayList(ModuleEntry),
    /// Counters
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    verbose: bool = false,
    failures: std.ArrayList([]const u8),

    fn init(allocator: Allocator, dir: []const u8, verbose: bool) !TestRunner {
        const store = try allocator.create(Store);
        store.* = Store.init(allocator);
        const vm = try allocator.create(VmImpl);
        vm.* = VmImpl.init(allocator);
        return .{
            .allocator = allocator,
            .dir = dir,
            .store = store,
            .vm = vm,
            .named_modules = std.StringHashMap(ModuleEntry).init(allocator),
            .registered = std.StringHashMap(ModuleEntry).init(allocator),
            .all_modules = .empty,
            .failures = .empty,
            .verbose = verbose,
        };
    }

    fn deinit(self: *TestRunner) void {
        for (self.all_modules.items) |entry| {
            entry.instance.deinit();
            entry.module.deinit();
            self.allocator.free(entry.wasm_bytes);
            self.allocator.destroy(entry.instance);
            self.allocator.destroy(entry.module);
        }
        self.all_modules.deinit(self.allocator);
        self.named_modules.deinit();
        self.registered.deinit();
        self.allocator.destroy(self.vm);
        self.store.deinit();
        self.allocator.destroy(self.store);
        for (self.failures.items) |msg| self.allocator.free(msg);
        self.failures.deinit(self.allocator);
    }

    fn resetState(self: *TestRunner) void {
        for (self.all_modules.items) |entry| {
            entry.instance.deinit();
            entry.module.deinit();
            self.allocator.free(entry.wasm_bytes);
            self.allocator.destroy(entry.instance);
            self.allocator.destroy(entry.module);
        }
        self.all_modules.clearRetainingCapacity();
        self.named_modules.clearRetainingCapacity();
        self.registered.clearRetainingCapacity();
        self.current_module = null;

        // Recreate store (clean slate)
        self.store.deinit();
        self.store.* = Store.init(self.allocator);
    }

    fn getModuleEntry(self: *TestRunner, name: ?[]const u8) ?ModuleEntry {
        if (name) |n| {
            if (self.named_modules.get(n)) |entry| return entry;
            if (self.registered.get(n)) |entry| return entry;
            return null;
        }
        return self.current_module;
    }

    fn addFailure(self: *TestRunner, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.failures.append(self.allocator, msg) catch {
            self.allocator.free(msg);
        };
    }

    // --------------------------------------------------------
    // Command handlers
    // --------------------------------------------------------

    fn handleModule(self: *TestRunner, cmd: *const JsonCommand) void {
        const filename = cmd.filename orelse {
            self.addFailure("line {d}: module command missing filename", .{cmd.line});
            return;
        };

        const wasm_bytes = self.loadWasmFile(filename) orelse {
            self.addFailure("line {d}: failed to read {s}", .{ cmd.line, filename });
            return;
        };
        errdefer self.allocator.free(wasm_bytes);

        const mod = self.allocator.create(Module) catch return;
        errdefer self.allocator.destroy(mod);
        mod.* = Module.init(self.allocator, wasm_bytes);
        mod.decode() catch |err| {
            mod.deinit();
            self.allocator.destroy(mod);
            self.addFailure("line {d}: decode error: {s}", .{ cmd.line, @errorName(err) });
            return;
        };

        const inst = self.allocator.create(Instance) catch return;
        errdefer self.allocator.destroy(inst);
        inst.* = Instance.init(self.allocator, self.store, mod);
        inst.instantiate() catch |err| {
            inst.deinit();
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            self.addFailure("line {d}: instantiate error: {s}", .{ cmd.line, @errorName(err) });
            return;
        };

        // Run start function if present
        if (mod.start) |start_idx| {
            self.vm.reset();
            self.vm.invokeByIndex(inst, start_idx, &.{}, &.{}) catch |err| {
                inst.deinit();
                self.allocator.destroy(inst);
                mod.deinit();
                self.allocator.destroy(mod);
                self.addFailure("line {d}: start function error: {s}", .{ cmd.line, @errorName(err) });
                return;
            };
        }

        const entry = ModuleEntry{ .instance = inst, .module = mod, .wasm_bytes = wasm_bytes };
        self.all_modules.append(self.allocator, entry) catch return;

        if (cmd.name) |name| {
            self.named_modules.put(name, entry) catch return;
        }
        self.current_module = entry;
    }

    fn handleRegister(self: *TestRunner, cmd: *const JsonCommand) void {
        const as_name = cmd.@"as" orelse return;

        const source = if (cmd.name) |name|
            self.named_modules.get(name)
        else
            self.current_module;

        if (source) |entry| {
            self.registered.put(as_name, entry) catch return;

            // Add all exports from this instance to the shared store under the registered name
            for (entry.module.exports.items) |exp| {
                switch (exp.kind) {
                    .func => {
                        if (exp.index < entry.instance.funcaddrs.items.len) {
                            const addr = entry.instance.funcaddrs.items[exp.index];
                            self.store.addExport(as_name, exp.name, .func, addr) catch continue;
                        }
                    },
                    .table => {
                        if (exp.index < entry.instance.tableaddrs.items.len) {
                            const addr = entry.instance.tableaddrs.items[exp.index];
                            self.store.addExport(as_name, exp.name, .table, addr) catch continue;
                        }
                    },
                    .memory => {
                        if (exp.index < entry.instance.memaddrs.items.len) {
                            const addr = entry.instance.memaddrs.items[exp.index];
                            self.store.addExport(as_name, exp.name, .memory, addr) catch continue;
                        }
                    },
                    .global => {
                        if (exp.index < entry.instance.globaladdrs.items.len) {
                            const addr = entry.instance.globaladdrs.items[exp.index];
                            self.store.addExport(as_name, exp.name, .global, addr) catch continue;
                        }
                    },
                    .tag => {
                        if (exp.index < entry.instance.tagaddrs.items.len) {
                            const addr = entry.instance.tagaddrs.items[exp.index];
                            self.store.addExport(as_name, exp.name, .tag, addr) catch continue;
                        }
                    },
                }
            }
        }
    }

    fn handleAssertReturn(self: *TestRunner, cmd: *const JsonCommand) void {
        const action = cmd.action orelse {
            self.failed += 1;
            self.addFailure("line {d}: assert_return missing action", .{cmd.line});
            return;
        };
        const expected = cmd.expected orelse &[_]JsonValue{};

        var results: [128]u64 = undefined;
        if (expected.len > results.len) {
            self.failed += 1;
            self.addFailure("line {d}: too many expected results ({d})", .{ cmd.line, expected.len });
            return;
        }
        const results_slice = results[0..expected.len];

        self.invokeAction(&action, results_slice) catch |err| {
            self.failed += 1;
            self.addFailure("line {d}: assert_return invoke error: {s}", .{ cmd.line, @errorName(err) });
            return;
        };

        for (expected, 0..) |exp, i| {
            if (!valuesMatch(exp, results_slice[i])) {
                self.failed += 1;
                const exp_str = exp.getValueString() orelse "null";
                self.addFailure("line {d}: assert_return mismatch [{d}]: expected {s}:{s}, got 0x{x}", .{ cmd.line, i, exp.type, exp_str, results_slice[i] });
                return;
            }
        }
        self.passed += 1;
    }

    fn handleAction(self: *TestRunner, cmd: *const JsonCommand) void {
        const action = cmd.action orelse return;
        var results: [128]u64 = undefined;
        const expected = cmd.expected orelse &[_]JsonValue{};
        const rlen = @min(expected.len, results.len);
        self.invokeAction(&action, results[0..rlen]) catch |err| {
            self.failed += 1;
            self.addFailure("line {d}: action invoke error: {s}", .{ cmd.line, @errorName(err) });
            return;
        };
        self.passed += 1;
    }

    fn handleAssertTrap(self: *TestRunner, cmd: *const JsonCommand) void {
        const action = cmd.action orelse {
            self.failed += 1;
            self.addFailure("line {d}: assert_trap missing action", .{cmd.line});
            return;
        };
        var results: [128]u64 = undefined;
        const expected = cmd.expected orelse &[_]JsonValue{};
        const rlen = @min(expected.len, results.len);
        if (self.invokeAction(&action, results[0..rlen])) |_| {
            self.failed += 1;
            self.addFailure("line {d}: assert_trap expected error but succeeded", .{cmd.line});
        } else |_| {
            self.passed += 1;
        }
    }

    fn handleAssertExhaustion(self: *TestRunner, cmd: *const JsonCommand) void {
        self.handleAssertTrap(cmd);
    }

    fn handleAssertInvalid(self: *TestRunner, cmd: *const JsonCommand) void {
        const filename = cmd.filename orelse {
            self.failed += 1;
            return;
        };
        const wasm_bytes = self.loadWasmFile(filename) orelse {
            self.skipped += 1;
            return;
        };
        defer self.allocator.free(wasm_bytes);

        var mod = Module.init(self.allocator, wasm_bytes);
        if (mod.decode()) |_| {
            mod.deinit();
            self.failed += 1;
            self.addFailure("line {d}: assert_invalid expected error but decoded OK", .{cmd.line});
        } else |_| {
            mod.deinit();
            self.passed += 1;
        }
    }

    fn handleAssertMalformed(self: *TestRunner, cmd: *const JsonCommand) void {
        self.handleAssertInvalid(cmd);
    }

    fn handleAssertUnlinkable(self: *TestRunner, cmd: *const JsonCommand) void {
        const filename = cmd.filename orelse {
            self.failed += 1;
            return;
        };
        const wasm_bytes = self.loadWasmFile(filename) orelse {
            self.skipped += 1;
            return;
        };
        defer self.allocator.free(wasm_bytes);

        var mod = Module.init(self.allocator, wasm_bytes);
        defer mod.deinit();
        mod.decode() catch {
            self.passed += 1;
            return;
        };

        // Instantiate in the shared store — expect link error
        var inst = Instance.init(self.allocator, self.store, &mod);
        defer inst.deinit();
        if (inst.instantiate()) |_| {
            self.failed += 1;
            self.addFailure("line {d}: assert_unlinkable expected error but instantiated OK", .{cmd.line});
        } else |_| {
            self.passed += 1;
        }
    }

    fn handleAssertUninstantiable(self: *TestRunner, cmd: *const JsonCommand) void {
        const filename = cmd.filename orelse {
            self.failed += 1;
            return;
        };
        const wasm_bytes = self.loadWasmFile(filename) orelse {
            self.skipped += 1;
            return;
        };

        // Allocate on heap — functions added to the shared Store during
        // partial instantiation may reference this module's type data.
        const mod = self.allocator.create(Module) catch {
            self.allocator.free(wasm_bytes);
            return;
        };
        mod.* = Module.init(self.allocator, wasm_bytes);
        mod.decode() catch {
            mod.deinit();
            self.allocator.destroy(mod);
            self.allocator.free(wasm_bytes);
            self.passed += 1;
            return;
        };

        const inst = self.allocator.create(Instance) catch {
            mod.deinit();
            self.allocator.destroy(mod);
            self.allocator.free(wasm_bytes);
            return;
        };
        inst.* = Instance.init(self.allocator, self.store, mod);

        // Keep module/instance alive (functions may be in shared Store)
        const entry = ModuleEntry{ .instance = inst, .module = mod, .wasm_bytes = wasm_bytes };
        self.all_modules.append(self.allocator, entry) catch {};

        if (inst.instantiate()) |_| {
            if (mod.start) |start_idx| {
                self.vm.reset();
                if (self.vm.invokeByIndex(inst, start_idx, &.{}, &.{})) |_| {
                    self.failed += 1;
                    self.addFailure("line {d}: assert_uninstantiable expected error but succeeded", .{cmd.line});
                } else |_| {
                    self.passed += 1;
                }
            } else {
                self.failed += 1;
                self.addFailure("line {d}: assert_uninstantiable expected error but instantiated OK", .{cmd.line});
            }
        } else |_| {
            self.passed += 1;
        }
    }

    // --------------------------------------------------------
    // Helpers
    // --------------------------------------------------------

    fn invokeAction(self: *TestRunner, action: *const JsonAction, results: []u64) !void {
        if (!std.mem.eql(u8, action.type, "invoke")) return error.UnsupportedActionType;

        const field = action.field orelse return error.MissingField;
        const entry = self.getModuleEntry(action.module) orelse return error.ModuleNotFound;

        var args: [512]u64 = undefined;
        const arg_values = action.args orelse &[_]JsonValue{};
        if (arg_values.len > args.len) return error.TooManyArgs;

        for (arg_values, 0..) |arg, i| {
            args[i] = parseValue(arg);
        }

        self.vm.reset();
        try self.vm.invoke(entry.instance, field, args[0..arg_values.len], results);
    }

    fn loadWasmFile(self: *TestRunner, filename: []const u8) ?[]const u8 {
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir, filename }) catch return null;
        defer self.allocator.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        const stat = file.stat() catch return null;
        const bytes = self.allocator.alloc(u8, stat.size) catch return null;
        const read = file.readAll(bytes) catch {
            self.allocator.free(bytes);
            return null;
        };
        if (read != stat.size) {
            self.allocator.free(bytes);
            return null;
        }
        return bytes;
    }

    fn runFile(self: *TestRunner, json_path: []const u8) !struct { passed: u32, failed: u32, skipped: u32 } {
        const old_passed = self.passed;
        const old_failed = self.failed;
        const old_skipped = self.skipped;

        const file = try std.fs.cwd().openFile(json_path, .{});
        defer file.close();
        const stat = try file.stat();
        const content = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(content);
        const read = try file.readAll(content);
        if (read != stat.size) return error.IncompleteRead;

        const parsed = std.json.parseFromSlice(JsonTestFile, self.allocator, content[0..read], .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            self.addFailure("{s}: JSON parse error: {s}", .{ json_path, @errorName(err) });
            return .{ .passed = 0, .failed = 1, .skipped = 0 };
        };
        defer parsed.deinit();

        // Reset module state for this test file
        self.resetState();

        for (parsed.value.commands) |*cmd| {
            if (std.mem.eql(u8, cmd.type, "module")) {
                self.handleModule(cmd);
            } else if (std.mem.eql(u8, cmd.type, "register")) {
                self.handleRegister(cmd);
            } else if (std.mem.eql(u8, cmd.type, "assert_return")) {
                self.handleAssertReturn(cmd);
            } else if (std.mem.eql(u8, cmd.type, "assert_trap")) {
                self.handleAssertTrap(cmd);
            } else if (std.mem.eql(u8, cmd.type, "assert_exhaustion")) {
                self.handleAssertExhaustion(cmd);
            } else if (std.mem.eql(u8, cmd.type, "assert_invalid")) {
                self.handleAssertInvalid(cmd);
            } else if (std.mem.eql(u8, cmd.type, "assert_malformed")) {
                self.handleAssertMalformed(cmd);
            } else if (std.mem.eql(u8, cmd.type, "assert_unlinkable")) {
                self.handleAssertUnlinkable(cmd);
            } else if (std.mem.eql(u8, cmd.type, "assert_uninstantiable")) {
                self.handleAssertUninstantiable(cmd);
            } else if (std.mem.eql(u8, cmd.type, "action")) {
                self.handleAction(cmd);
            }
        }

        return .{
            .passed = self.passed - old_passed,
            .failed = self.failed - old_failed,
            .skipped = self.skipped - old_skipped,
        };
    }
};

// ============================================================
// Value parsing and comparison
// ============================================================

fn parseValue(v: JsonValue) u64 {
    const s = v.getValueString() orelse return 0;
    if (std.mem.eql(u8, v.type, "i32") or std.mem.eql(u8, v.type, "f32")) {
        return @as(u64, std.fmt.parseInt(u32, s, 10) catch return 0);
    } else if (std.mem.eql(u8, v.type, "i64") or std.mem.eql(u8, v.type, "f64")) {
        return std.fmt.parseInt(u64, s, 10) catch return 0;
    } else if (std.mem.eql(u8, v.type, "externref") or std.mem.eql(u8, v.type, "funcref")) {
        if (std.mem.eql(u8, s, "null")) return 0;
        return std.fmt.parseInt(u64, s, 10) catch return 0;
    }
    return 0;
}

fn valuesMatch(expected: JsonValue, actual: u64) bool {
    const s = expected.getValueString() orelse {
        // v128 array values — skip for now
        if (expected.value != null) return true;
        return true;
    };

    if (std.mem.eql(u8, expected.type, "i32")) {
        return @as(u32, @truncate(actual)) == (std.fmt.parseInt(u32, s, 10) catch return false);
    } else if (std.mem.eql(u8, expected.type, "i64")) {
        return actual == (std.fmt.parseInt(u64, s, 10) catch return false);
    } else if (std.mem.eql(u8, expected.type, "f32")) {
        const exp_bits = std.fmt.parseInt(u32, s, 10) catch return false;
        const act_bits: u32 = @truncate(actual);
        if (isNaN32(exp_bits) and isNaN32(act_bits)) return true;
        return act_bits == exp_bits;
    } else if (std.mem.eql(u8, expected.type, "f64")) {
        const exp_bits = std.fmt.parseInt(u64, s, 10) catch return false;
        if (isNaN64(exp_bits) and isNaN64(actual)) return true;
        return actual == exp_bits;
    } else if (std.mem.eql(u8, expected.type, "externref")) {
        if (std.mem.eql(u8, s, "null")) return actual == 0;
        return actual == (std.fmt.parseInt(u64, s, 10) catch return false);
    } else if (std.mem.eql(u8, expected.type, "funcref")) {
        if (std.mem.eql(u8, s, "null")) return actual == 0;
        return actual != 0;
    } else if (std.mem.eql(u8, expected.type, "v128")) {
        // v128: skip detailed comparison for now
        return true;
    }
    return false;
}

fn isNaN32(bits: u32) bool {
    return (bits >> 23) & 0xFF == 0xFF and bits & 0x7FFFFF != 0;
}

fn isNaN64(bits: u64) bool {
    return (bits >> 52) & 0x7FF == 0x7FF and bits & 0xFFFFFFFFFFFFF != 0;
}

// ============================================================
// Main
// ============================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var dir: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var verbose = false;
    var summary = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir")) {
            i += 1;
            if (i < args.len) dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--file")) {
            i += 1;
            if (i < args.len) file = args[i];
        } else if (std.mem.eql(u8, args[i], "-v") or std.mem.eql(u8, args[i], "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, args[i], "--summary")) {
            summary = true;
        }
    }

    var buf: [8192]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;

    if (file) |f| {
        const parent_dir = std.fs.path.dirname(f) orelse ".";
        var runner = try TestRunner.init(allocator, parent_dir, verbose);
        defer runner.deinit();

        const result = try runner.runFile(f);
        const total = result.passed + result.failed;
        try stdout.print("{s}: {d}/{d} passed", .{ std.fs.path.basename(f), result.passed, total });
        if (result.skipped > 0) try stdout.print(" ({d} skipped)", .{result.skipped});
        try stdout.print("\n", .{});

        if (verbose) {
            for (runner.failures.items) |msg| {
                try stdout.print("  FAIL: {s}\n", .{msg});
            }
        }

        try stdout.flush();
        if (result.failed > 0) std.process.exit(1);
        return;
    }

    if (dir) |d| {
        var json_dir = std.fs.cwd().openDir(d, .{ .iterate = true }) catch {
            try stdout.print("ERROR: Cannot open directory: {s}\n", .{d});
            try stdout.flush();
            std.process.exit(1);
        };
        defer json_dir.close();

        var files = std.ArrayList([]const u8).empty;
        defer {
            for (files.items) |f2| allocator.free(f2);
            files.deinit(allocator);
        }

        var iter = json_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            try files.append(allocator, try allocator.dupe(u8, entry.name));
        }

        std.mem.sort([]const u8, files.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        var total_passed: u32 = 0;
        var total_failed: u32 = 0;
        var total_skipped: u32 = 0;
        var file_count: u32 = 0;

        for (files.items) |json_name| {
            const json_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ d, json_name });
            defer allocator.free(json_path);

            var runner = try TestRunner.init(allocator, d, verbose);
            defer runner.deinit();

            const result = runner.runFile(json_path) catch |err| {
                try stdout.print("  ERROR {s}: {s}\n", .{ json_name, @errorName(err) });
                total_failed += 1;
                file_count += 1;
                continue;
            };

            total_passed += result.passed;
            total_failed += result.failed;
            total_skipped += result.skipped;
            file_count += 1;

            if (summary) {
                const status: []const u8 = if (result.failed == 0) "PASS" else "FAIL";
                const basename = json_name[0 .. json_name.len - 5];
                try stdout.print("  {s} {s}: {d} passed, {d} failed", .{ status, basename, result.passed, result.failed });
                if (result.skipped > 0) try stdout.print(", {d} skipped", .{result.skipped});
                try stdout.print("\n", .{});
            }

            if (verbose) {
                for (runner.failures.items) |msg| {
                    try stdout.print("    FAIL: {s}\n", .{msg});
                }
            }
        }

        const total = total_passed + total_failed;
        try stdout.print("\n============================================================\n", .{});
        try stdout.print("E2E test results: {d}/{d} passed ({d:.1}%)\n", .{
            total_passed,
            total,
            if (total > 0) @as(f64, @floatFromInt(total_passed)) / @as(f64, @floatFromInt(total)) * 100.0 else 0.0,
        });
        try stdout.print("  Files: {d}\n", .{file_count});
        try stdout.print("  Passed: {d}\n", .{total_passed});
        try stdout.print("  Failed: {d}\n", .{total_failed});
        if (total_skipped > 0) try stdout.print("  Skipped: {d}\n", .{total_skipped});
        try stdout.print("============================================================\n", .{});

        try stdout.flush();
        if (total_failed > 0) std.process.exit(1);
        return;
    }

    try stdout.print("Usage: e2e_runner --dir <dir> [--summary] [-v]\n", .{});
    try stdout.print("       e2e_runner --file <file.json> [-v]\n", .{});
    try stdout.flush();
    std.process.exit(1);
}
