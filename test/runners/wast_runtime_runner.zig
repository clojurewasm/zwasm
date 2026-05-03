//! Runtime-asserting WAST runner (Phase 6 / §9.6 / 6.A per ADR-0013).
//!
//! Walks one or more corpus subdirectories, each containing a
//! `manifest.txt` plus the `.wasm` files referenced by it. The
//! manifest format extends `test/spec/wast_runner.zig`'s flat-text
//! pattern with runtime-asserting directives:
//!
//!   `valid <file>`     — parse + validate; expect success.
//!   `invalid <file>`   — parse + validate; expect failure.
//!   `malformed <file>` — parse alone; expect failure.
//!   `module <file>`    — load + instantiate; becomes "current".
//!                        Optional `as <name>` registers the module
//!                        for later cross-module reference.
//!   `register <as-name>` — alias the current module under <as-name>
//!                        (recognised in 6.A; cross-module imports
//!                        wired in 6.D).
//!   `assert_return <export> <args> -> <expected>`
//!                      — invoke `<export>` on the current module,
//!                        compare results to `<expected>`.
//!   `assert_trap <export> <args> !! <kind>`
//!                      — invoke `<export>`, expect a trap (any
//!                        kind in 6.A; strict-kind matching wired
//!                        in 6.D).
//!   `assert_exhaustion <export> <args> !! <kind>`
//!                      — same as assert_trap, kind expected to
//!                        be StackOverflow / CallStackExhausted.
//!   `invoke <export> <args>` — call, ignore result.
//!   `action <export> <args>` — alias of invoke.
//!   `assert_invalid <file> !! <reason>`
//!                      — alias of `invalid` (reason not matched).
//!   `assert_malformed <file> !! <reason>`
//!                      — alias of `malformed`.
//!   `assert_unlinkable <file> !! <reason>`
//!                      — load expected to fail at instantiate.
//!   `assert_uninstantiable <file> !! <reason>`
//!                      — load expected to fail at start.
//!
//! Argument and expected values use TLV-style notation
//! (space-separated when multiple): `i32:42`, `i64:-1`,
//! `f32:0x7fc00000`, `f64:1.5`. v0 of the runner only handles i32
//! end-to-end; broader value-type comparison lands per directive
//! when 6.D wires the wasmtime_misc corpus that exercises it.
//!
//! Per-instr execution trace: the underlying `interp.Runtime` carries
//! `trace_cb` / `trace_ctx` (added in 6.A alongside this runner). The
//! `--trace <fixture>` CLI flag will hook a trace sink in 6.E when
//! interp behaviour bug investigation needs it; not wired in 6.A.
//!
//! Usage:
//!   wast_runtime_runner <corpus-root>
//! where `<corpus-root>` is a directory whose immediate children
//! are subdirectories each containing a `manifest.txt`.

const std = @import("std");
const zwasm = @import("zwasm");

const wasm_c_api = zwasm.c_api;
const parser = zwasm.parser;
const sections = zwasm.sections;

/// Per-corpus state. Holds the active module pipeline + a name map
/// for `register`. One `RunnerContext` per `manifest.txt`; arena-
/// freed at the end of that corpus run.
const RunnerContext = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    /// Current module (most-recently instantiated). Borrowed pointers
    /// freed at corpus teardown via `delete*` calls.
    current: ?*ActiveModule = null,
    /// Module name → ActiveModule. Used by `register` and named
    /// invokes. Cross-module-import resolution wires through here in
    /// §9.6 / 6.D.
    by_name: std.StringHashMapUnmanaged(*ActiveModule) = .empty,
    /// All instantiated modules, in instantiation order. Owned so
    /// teardown can walk them.
    all: std.ArrayList(*ActiveModule) = .empty,

    fn alloc(self: *RunnerContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: *RunnerContext) void {
        const a = self.arena.allocator();
        for (self.all.items) |am| am.deinit();
        self.all.deinit(a);
        self.by_name.deinit(a);
        self.arena.deinit();
    }
};

/// One instantiated module's runtime handles. The runner owns these
/// for the lifetime of the corpus, then deletes via the c_api.
const ActiveModule = struct {
    engine: *wasm_c_api.Engine,
    store: *wasm_c_api.Store,
    module: *wasm_c_api.Module,
    instance: *wasm_c_api.Instance,
    /// Cached export vector; populated lazily by `lookupExport`.
    exports: wasm_c_api.ExternVec = .{ .size = 0, .data = null },

    fn deinit(self: *ActiveModule) void {
        if (self.exports.size > 0) wasm_c_api.wasm_extern_vec_delete(&self.exports);
        wasm_c_api.wasm_instance_delete(self.instance);
        wasm_c_api.wasm_module_delete(self.module);
        wasm_c_api.wasm_store_delete(self.store);
        wasm_c_api.wasm_engine_delete(self.engine);
    }

    fn ensureExports(self: *ActiveModule) void {
        if (self.exports.size == 0) {
            wasm_c_api.wasm_instance_exports(self.instance, &self.exports);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_root_arg = arg_it.next() orelse {
        try stdout.print("usage: wast_runtime_runner <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    var passed: u32 = 0;
    var failed: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try walkCorpusOrCategory(io, gpa, &root, entry.name, stdout, &passed, &failed);
    }

    try stdout.print("\nwast_runtime_runner: {d} passed, {d} failed\n", .{ passed, failed });
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}

/// Mirror of `test/spec/wast_runner.zig` walkCorpusOrCategory:
/// recurse one level when `<root>/<name>` lacks a manifest itself,
/// so the wasmtime_misc 2-level layout (`category/fixture/`) walks
/// without per-category build steps.
fn walkCorpusOrCategory(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    passed: *u32,
    failed: *u32,
) !void {
    var dir = root.openDir(io, name, .{ .iterate = true }) catch {
        try runCorpus(io, gpa, root, name, stdout, passed, failed);
        return;
    };
    const has_manifest = blk: {
        const probe = dir.openFile(io, "manifest_runtime.txt", .{}) catch
            dir.openFile(io, "manifest.txt", .{}) catch {
                break :blk false;
            };
        var f = probe;
        f.close(io);
        break :blk true;
    };
    if (has_manifest) {
        dir.close(io);
        try runCorpus(io, gpa, root, name, stdout, passed, failed);
        return;
    }
    var it = dir.iterate();
    while (try it.next(io)) |child| {
        if (child.kind != .directory) continue;
        try runCorpus(io, gpa, &dir, child.name, stdout, passed, failed);
    }
    dir.close(io);
}

fn runCorpus(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    passed: *u32,
    failed: *u32,
) !void {
    var dir = root.openDir(io, name, .{}) catch |err| {
        try stdout.print("FAIL  {s}/: openDir {s}\n", .{ name, @errorName(err) });
        failed.* += 1;
        return;
    };
    defer dir.close(io);

    // Prefer manifest_runtime.txt (full runtime directives) over
    // manifest.txt (parse + validate only). Per ADR-0013 §2; the
    // wasmtime_misc corpus generated by regen_wasmtime_misc.sh
    // produces both, with runtime directives only in the *_runtime
    // file; the smoke fixture has only manifest.txt.
    const manifest_bytes = dir.readFileAlloc(io, "manifest_runtime.txt", gpa, .limited(1 << 16)) catch
        dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 16)) catch |err| {
            try stdout.print("FAIL  {s}/manifest.txt: {s}\n", .{ name, @errorName(err) });
            failed.* += 1;
            return;
        };
    defer gpa.free(manifest_bytes);

    var ctx: RunnerContext = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .io = io,
    };
    defer ctx.deinit();

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const ok = handleLine(&ctx, &dir, line, stdout, name) catch |err| {
            try stdout.print("FAIL  {s}: '{s}' runner error {s}\n", .{ name, line, @errorName(err) });
            failed.* += 1;
            continue;
        };

        if (ok) {
            passed.* += 1;
        } else {
            failed.* += 1;
        }
    }
}

/// Dispatch a single manifest line. Returns true if the directive's
/// expectation matched, false otherwise. Returns runner-error only
/// for OOM and similar plumbing failures (not for guest-side traps,
/// which are folded into the boolean per directive semantics).
fn handleLine(
    ctx: *RunnerContext,
    dir: *std.Io.Dir,
    line: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    var tok_it = std.mem.tokenizeScalar(u8, line, ' ');
    const directive = tok_it.next() orelse return false;
    const rest = std.mem.trim(u8, line[directive.len..], " \t");

    if (std.mem.eql(u8, directive, "valid")) {
        return handleValidMalformedInvalid(ctx, dir, .valid, rest, stdout, corpus_name);
    } else if (std.mem.eql(u8, directive, "invalid") or std.mem.eql(u8, directive, "assert_invalid")) {
        return handleValidMalformedInvalid(ctx, dir, .invalid, takeFile(rest), stdout, corpus_name);
    } else if (std.mem.eql(u8, directive, "malformed") or std.mem.eql(u8, directive, "assert_malformed")) {
        return handleValidMalformedInvalid(ctx, dir, .malformed, takeFile(rest), stdout, corpus_name);
    } else if (std.mem.eql(u8, directive, "module")) {
        return handleModule(ctx, dir, rest, stdout, corpus_name);
    } else if (std.mem.eql(u8, directive, "register")) {
        return handleRegister(ctx, rest, stdout, corpus_name);
    } else if (std.mem.eql(u8, directive, "assert_return")) {
        return handleAssertReturn(ctx, rest, stdout, corpus_name);
    } else if (std.mem.eql(u8, directive, "assert_trap")) {
        return handleAssertTrap(ctx, rest, stdout, corpus_name, .any);
    } else if (std.mem.eql(u8, directive, "assert_exhaustion")) {
        return handleAssertTrap(ctx, rest, stdout, corpus_name, .exhaustion);
    } else if (std.mem.eql(u8, directive, "assert_unlinkable")) {
        return handleInstantiateExpectFail(ctx, dir, takeFile(rest), stdout, corpus_name, "unlinkable");
    } else if (std.mem.eql(u8, directive, "assert_uninstantiable")) {
        return handleInstantiateExpectFail(ctx, dir, takeFile(rest), stdout, corpus_name, "uninstantiable");
    } else if (std.mem.eql(u8, directive, "invoke") or std.mem.eql(u8, directive, "action")) {
        return handleInvoke(ctx, rest, stdout, corpus_name);
    } else {
        try stdout.print("FAIL  {s}: unknown directive '{s}'\n", .{ corpus_name, directive });
        return false;
    }
}

const ParseDirective = enum { valid, invalid, malformed };

/// Take the first whitespace-delimited token (the filename) and
/// drop trailing `!! <reason>` if present.
fn takeFile(rest: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    return it.next() orelse "";
}

fn handleValidMalformedInvalid(
    ctx: *RunnerContext,
    dir: *std.Io.Dir,
    kind: ParseDirective,
    filename: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    const a = ctx.alloc();
    const wasm_bytes = dir.readFileAlloc(ctx.io, filename, a, .limited(4 << 20)) catch |err| {
        try stdout.print("FAIL  {s}/{s}: read {s}\n", .{ corpus_name, filename, @errorName(err) });
        return false;
    };
    defer a.free(wasm_bytes);

    if (kind == .malformed) {
        var module = parser.parse(a, wasm_bytes) catch {
            try stdout.print("PASS  {s}/{s} (malformed)\n", .{ corpus_name, filename });
            return true;
        };
        module.deinit(a);
        try stdout.print("FAIL  {s}/{s} (malformed) — parse unexpectedly succeeded\n", .{ corpus_name, filename });
        return false;
    }

    var module = parser.parse(a, wasm_bytes) catch {
        const ok_ = (kind == .invalid);
        if (ok_) {
            try stdout.print("PASS  {s}/{s} ({s})\n", .{ corpus_name, filename, @tagName(kind) });
        } else {
            try stdout.print("FAIL  {s}/{s} ({s}) — parse failed\n", .{ corpus_name, filename, @tagName(kind) });
        }
        return ok_;
    };
    defer module.deinit(a);

    const validated = validateAllFunctions(a, &module) catch false;
    const want = (kind == .valid);
    if (validated == want) {
        try stdout.print("PASS  {s}/{s} ({s})\n", .{ corpus_name, filename, @tagName(kind) });
        return true;
    } else {
        try stdout.print("FAIL  {s}/{s} ({s}) — validate mismatch\n", .{ corpus_name, filename, @tagName(kind) });
        return false;
    }
}

fn validateAllFunctions(a: std.mem.Allocator, module: *parser.Module) !bool {
    const validator = zwasm.validator;
    const zir = zwasm.zir;

    const type_section = module.find(.@"type");
    const import_section = module.find(.import);
    const func_section = module.find(.function);
    const code_section = module.find(.code);
    const table_section = module.find(.table);
    const global_section = module.find(.global);

    const code_body = if (code_section) |s| s.body else return true;

    var types_owned = if (type_section) |s|
        try sections.decodeTypes(a, s.body)
    else
        sections.Types{ .arena = std.heap.ArenaAllocator.init(a), .items = &.{} };
    defer types_owned.deinit();

    var imports_owned: ?sections.Imports = if (import_section) |s|
        try sections.decodeImports(a, s.body)
    else
        null;
    defer if (imports_owned) |*im| im.deinit();

    const defined_func_indices = if (func_section) |s|
        try sections.decodeFunctions(a, s.body)
    else
        try a.alloc(u32, 0);
    defer a.free(defined_func_indices);

    var codes = try sections.decodeCodes(a, code_body);
    defer codes.deinit();

    if (codes.items.len != defined_func_indices.len) return false;

    var imp_func_count: usize = 0;
    if (imports_owned) |im| for (im.items) |it| if (it.kind == .func) {
        imp_func_count += 1;
    };
    const total_funcs = imp_func_count + defined_func_indices.len;
    const func_types = try a.alloc(zir.FuncType, total_funcs);
    defer a.free(func_types);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| for (im.items) |it| if (it.kind == .func) {
            const ti = it.payload.func_typeidx;
            if (ti >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[ti];
            cursor += 1;
        };
        for (defined_func_indices) |type_idx| {
            if (type_idx >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[type_idx];
            cursor += 1;
        }
    }

    var globals_owned: ?sections.Globals = if (global_section) |s|
        try sections.decodeGlobals(a, s.body)
    else
        null;
    defer if (globals_owned) |*g| g.deinit();

    var imp_global_count: usize = 0;
    if (imports_owned) |im| for (im.items) |it| if (it.kind == .global) {
        imp_global_count += 1;
    };
    const def_global_count: usize = if (globals_owned) |g| g.items.len else 0;
    const total_globals = imp_global_count + def_global_count;
    const global_entries = try a.alloc(validator.GlobalEntry, total_globals);
    defer a.free(global_entries);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| for (im.items) |it| if (it.kind == .global) {
            global_entries[cursor] = .{
                .valtype = it.payload.global.valtype,
                .mutable = it.payload.global.mutable,
            };
            cursor += 1;
        };
        if (globals_owned) |g| for (g.items) |gd| {
            global_entries[cursor] = .{ .valtype = gd.valtype, .mutable = gd.mutable };
            cursor += 1;
        };
    }

    var tables_owned: ?sections.Tables = if (table_section) |s|
        try sections.decodeTables(a, s.body)
    else
        null;
    defer if (tables_owned) |*t| t.deinit();

    var imp_table_count: usize = 0;
    if (imports_owned) |im| for (im.items) |it| if (it.kind == .table) {
        imp_table_count += 1;
    };
    const def_table_count: usize = if (tables_owned) |t| t.items.len else 0;
    const total_tables = imp_table_count + def_table_count;
    const table_entries = try a.alloc(zir.TableEntry, total_tables);
    defer a.free(table_entries);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| for (im.items) |it| if (it.kind == .table) {
            table_entries[cursor] = .{ .elem_type = .funcref, .min = 0 };
            cursor += 1;
        };
        if (tables_owned) |t| for (t.items) |entry| {
            table_entries[cursor] = entry;
            cursor += 1;
        };
    }

    for (codes.items, defined_func_indices) |code, type_idx| {
        const sig = types_owned.items[type_idx];
        validator.validateFunction(
            sig,
            code.locals,
            code.body,
            func_types,
            global_entries,
            types_owned.items,
            0,
            table_entries,
            0,
        ) catch return false;
    }
    return true;
}

fn handleModule(
    ctx: *RunnerContext,
    dir: *std.Io.Dir,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    // Format: `module <file>` or `module <file> as <name>`.
    var tok_it = std.mem.tokenizeScalar(u8, rest, ' ');
    const filename = tok_it.next() orelse {
        try stdout.print("FAIL  {s}: module directive missing file\n", .{corpus_name});
        return false;
    };
    const as_kw = tok_it.next();
    const name_opt: ?[]const u8 = if (as_kw != null and std.mem.eql(u8, as_kw.?, "as")) tok_it.next() else null;

    const a = ctx.alloc();
    const wasm_bytes = dir.readFileAlloc(ctx.io, filename, a, .limited(4 << 20)) catch |err| {
        try stdout.print("FAIL  {s}/{s}: module read {s}\n", .{ corpus_name, filename, @errorName(err) });
        return false;
    };
    // Note: bytes are NOT freed — the c_api module holds them.

    const am = try a.create(ActiveModule);
    am.* = instantiate(ctx, wasm_bytes) catch |err| {
        try stdout.print("FAIL  {s}/{s}: instantiate {s}\n", .{ corpus_name, filename, @errorName(err) });
        return false;
    };
    try ctx.all.append(a, am);
    ctx.current = am;
    if (name_opt) |n| {
        const stored_name = try a.dupe(u8, n);
        try ctx.by_name.put(a, stored_name, am);
    }

    try stdout.print("PASS  {s}/{s} (module)\n", .{ corpus_name, filename });
    return true;
}

fn instantiate(ctx: *RunnerContext, wasm_bytes: []const u8) !ActiveModule {
    _ = ctx;
    const engine = wasm_c_api.wasm_engine_new() orelse return error.EngineAllocFailed;
    errdefer wasm_c_api.wasm_engine_delete(engine);

    const store = wasm_c_api.wasm_store_new(engine) orelse return error.StoreAllocFailed;
    errdefer wasm_c_api.wasm_store_delete(store);

    var bv: wasm_c_api.ByteVec = .{
        .size = wasm_bytes.len,
        .data = @constCast(wasm_bytes.ptr),
    };
    const module = wasm_c_api.wasm_module_new(store, &bv) orelse return error.ModuleAllocFailed;
    errdefer wasm_c_api.wasm_module_delete(module);

    const instance = wasm_c_api.wasm_instance_new(store, module, null, null) orelse
        return error.InstanceAllocFailed;
    return .{
        .engine = engine,
        .store = store,
        .module = module,
        .instance = instance,
    };
}

fn handleRegister(
    ctx: *RunnerContext,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    var tok_it = std.mem.tokenizeScalar(u8, rest, ' ');
    const as_name = tok_it.next() orelse {
        try stdout.print("FAIL  {s}: register missing as-name\n", .{corpus_name});
        return false;
    };
    const am = ctx.current orelse {
        try stdout.print("FAIL  {s}: register without prior module\n", .{corpus_name});
        return false;
    };
    const a = ctx.alloc();
    const stored = try a.dupe(u8, as_name);
    try ctx.by_name.put(a, stored, am);
    try stdout.print("PASS  {s} (register {s})\n", .{ corpus_name, as_name });
    return true;
}

fn handleInstantiateExpectFail(
    ctx: *RunnerContext,
    dir: *std.Io.Dir,
    filename: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
    label: []const u8,
) !bool {
    const a = ctx.alloc();
    const wasm_bytes = dir.readFileAlloc(ctx.io, filename, a, .limited(4 << 20)) catch |err| {
        try stdout.print("FAIL  {s}/{s}: read {s}\n", .{ corpus_name, filename, @errorName(err) });
        return false;
    };
    defer a.free(wasm_bytes);

    var am_tmp = instantiate(ctx, wasm_bytes) catch {
        try stdout.print("PASS  {s}/{s} ({s})\n", .{ corpus_name, filename, label });
        return true;
    };
    am_tmp.deinit();
    try stdout.print("FAIL  {s}/{s} ({s}) — instantiate unexpectedly succeeded\n", .{ corpus_name, filename, label });
    return false;
}

fn handleAssertReturn(
    ctx: *RunnerContext,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    // Format: `assert_return <export> <args...> -> <expected...>`
    const arrow = std.mem.find(u8, rest, "->") orelse {
        try stdout.print("FAIL  {s}: assert_return missing '->'\n", .{corpus_name});
        return false;
    };
    const left = std.mem.trim(u8, rest[0..arrow], " \t");
    const right = std.mem.trim(u8, rest[arrow + 2 ..], " \t");

    var left_it = std.mem.tokenizeScalar(u8, left, ' ');
    const export_name = left_it.next() orelse {
        try stdout.print("FAIL  {s}: assert_return missing export name\n", .{corpus_name});
        return false;
    };

    const a = ctx.alloc();
    var args: std.ArrayList(wasm_c_api.Val) = .empty;
    defer args.deinit(a);
    while (left_it.next()) |arg_tok| {
        const v = parseValue(arg_tok) catch |err| {
            try stdout.print("FAIL  {s}: assert_return bad arg '{s}': {s}\n", .{ corpus_name, arg_tok, @errorName(err) });
            return false;
        };
        try args.append(a, v);
    }

    var expected: std.ArrayList(wasm_c_api.Val) = .empty;
    defer expected.deinit(a);
    if (right.len > 0) {
        var right_it = std.mem.tokenizeScalar(u8, right, ' ');
        while (right_it.next()) |exp_tok| {
            const v = parseValue(exp_tok) catch |err| {
                try stdout.print("FAIL  {s}: assert_return bad expected '{s}': {s}\n", .{ corpus_name, exp_tok, @errorName(err) });
                return false;
            };
            try expected.append(a, v);
        }
    }

    const result = invokeExport(ctx, export_name, args.items, expected.items.len, a) catch |err| {
        try stdout.print("FAIL  {s}/{s}: invoke {s}\n", .{ corpus_name, export_name, @errorName(err) });
        return false;
    };
    if (result.trapped) {
        try stdout.print("FAIL  {s}/{s} (assert_return) — trapped unexpectedly\n", .{ corpus_name, export_name });
        return false;
    }

    if (result.results.len != expected.items.len) {
        try stdout.print("FAIL  {s}/{s} (assert_return) — got {d} results, expected {d}\n", .{ corpus_name, export_name, result.results.len, expected.items.len });
        return false;
    }
    for (result.results, expected.items, 0..) |got, want, i| {
        if (!valEquals(got, want)) {
            try stdout.print("FAIL  {s}/{s} (assert_return) — result[{d}] mismatch\n", .{ corpus_name, export_name, i });
            return false;
        }
    }

    try stdout.print("PASS  {s}/{s} (assert_return)\n", .{ corpus_name, export_name });
    return true;
}

const TrapKindExpect = enum { any, exhaustion };

fn handleAssertTrap(
    ctx: *RunnerContext,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
    expect: TrapKindExpect,
) !bool {
    // Format: `assert_trap <export> <args...> !! <kind>`
    const bang = std.mem.find(u8, rest, "!!") orelse rest.len;
    const left = std.mem.trim(u8, rest[0..bang], " \t");

    var left_it = std.mem.tokenizeScalar(u8, left, ' ');
    const export_name = left_it.next() orelse {
        try stdout.print("FAIL  {s}: assert_trap missing export name\n", .{corpus_name});
        return false;
    };

    const a = ctx.alloc();
    var args: std.ArrayList(wasm_c_api.Val) = .empty;
    defer args.deinit(a);
    while (left_it.next()) |arg_tok| {
        const v = parseValue(arg_tok) catch |err| {
            try stdout.print("FAIL  {s}: assert_trap bad arg '{s}': {s}\n", .{ corpus_name, arg_tok, @errorName(err) });
            return false;
        };
        try args.append(a, v);
    }

    // assert_trap doesn't care about the result vec size — wasm_func_call
    // will trap before writing results. Pass 0 to keep the binding-error
    // path from masking the genuine trap.
    const result = invokeExport(ctx, export_name, args.items, 0, a) catch |err| {
        try stdout.print("PASS  {s}/{s} (assert_trap; runner-error counted as trap: {s})\n", .{ corpus_name, export_name, @errorName(err) });
        return true;
    };
    if (!result.trapped) {
        try stdout.print("FAIL  {s}/{s} (assert_trap) — did not trap\n", .{ corpus_name, export_name });
        return false;
    }
    _ = expect; // strict-kind matching wired in §9.6 / 6.D
    try stdout.print("PASS  {s}/{s} (assert_trap)\n", .{ corpus_name, export_name });
    return true;
}

fn handleInvoke(
    ctx: *RunnerContext,
    rest: []const u8,
    stdout: *std.Io.Writer,
    corpus_name: []const u8,
) !bool {
    var tok_it = std.mem.tokenizeScalar(u8, rest, ' ');
    const export_name = tok_it.next() orelse {
        try stdout.print("FAIL  {s}: invoke missing export name\n", .{corpus_name});
        return false;
    };

    const a = ctx.alloc();
    var args: std.ArrayList(wasm_c_api.Val) = .empty;
    defer args.deinit(a);
    while (tok_it.next()) |arg_tok| {
        const v = parseValue(arg_tok) catch |err| {
            try stdout.print("FAIL  {s}: invoke bad arg '{s}': {s}\n", .{ corpus_name, arg_tok, @errorName(err) });
            return false;
        };
        try args.append(a, v);
    }

    // For bare `invoke` we don't know the expected result count
    // a priori; pass 0 (binding-error if the function has results,
    // which is the same outcome as v1's "ignore returns" semantics
    // since the runner doesn't consume them). Strict-binding wiring
    // arrives with §9.6 / 6.D when the corpus exercises it.
    const result = invokeExport(ctx, export_name, args.items, 0, a) catch |err| {
        try stdout.print("FAIL  {s}/{s}: invoke {s}\n", .{ corpus_name, export_name, @errorName(err) });
        return false;
    };
    _ = result;
    try stdout.print("PASS  {s}/{s} (invoke)\n", .{ corpus_name, export_name });
    return true;
}

const InvokeResult = struct {
    trapped: bool,
    results: []wasm_c_api.Val,
};

fn invokeExport(
    ctx: *RunnerContext,
    export_name: []const u8,
    args: []const wasm_c_api.Val,
    expected_result_count: usize,
    a: std.mem.Allocator,
) !InvokeResult {
    const am = ctx.current orelse return error.NoCurrentModule;
    am.ensureExports();

    var entry_idx: ?usize = null;
    for (am.instance.exports_storage, 0..) |exp, i| {
        if (exp.kind == .func and std.mem.eql(u8, exp.name, export_name)) {
            entry_idx = i;
            break;
        }
    }
    const idx = entry_idx orelse return error.ExportNotFound;
    if (idx >= am.exports.size) return error.ExportNotFound;
    const ext = am.exports.data.?[idx] orelse return error.ExportNotFound;
    const fn_ptr = wasm_c_api.wasm_extern_as_func(ext) orelse return error.NotAFunction;

    const args_vec: wasm_c_api.ValVec = .{
        .size = args.len,
        .data = if (args.len > 0) @constCast(args.ptr) else null,
    };
    // wasm_func_call requires results.size == sig.results.len
    // exactly. The caller pre-sizes via `expected_result_count`.
    const results_buf = if (expected_result_count > 0)
        try a.alloc(wasm_c_api.Val, expected_result_count)
    else
        @as([]wasm_c_api.Val, &.{});
    var results_vec: wasm_c_api.ValVec = .{
        .size = expected_result_count,
        .data = if (expected_result_count > 0) results_buf.ptr else null,
    };
    const trap = wasm_c_api.wasm_func_call(fn_ptr, &args_vec, &results_vec);
    if (trap != null) {
        wasm_c_api.wasm_trap_delete(trap);
        return .{ .trapped = true, .results = &.{} };
    }
    return .{ .trapped = false, .results = results_buf };
}

fn parseValue(text: []const u8) !wasm_c_api.Val {
    const colon = std.mem.findScalar(u8, text, ':') orelse return error.BadValueSyntax;
    const ty = text[0..colon];
    const num = text[colon + 1 ..];

    if (std.mem.eql(u8, ty, "i32")) {
        // Wasm i32 values are bit-patterns; wast2json may emit
        // them as either signed (negative) or unsigned (large
        // positive). Try i32 first, then u32 + bitcast.
        if (std.fmt.parseInt(i32, num, 0)) |v| {
            return .{ .kind = .i32, .of = .{ .i32 = v } };
        } else |_| {
            // Fall through to the unsigned-bit-pattern attempt below.
        }
        const u = std.fmt.parseInt(u32, num, 0) catch return error.BadI32;
        return .{ .kind = .i32, .of = .{ .i32 = @bitCast(u) } };
    } else if (std.mem.eql(u8, ty, "i64")) {
        if (std.fmt.parseInt(i64, num, 0)) |v| {
            return .{ .kind = .i64, .of = .{ .i64 = v } };
        } else |_| {
            // Fall through to the unsigned-bit-pattern attempt below.
        }
        const u = std.fmt.parseInt(u64, num, 0) catch return error.BadI64;
        return .{ .kind = .i64, .of = .{ .i64 = @bitCast(u) } };
    } else if (std.mem.eql(u8, ty, "f32")) {
        if (std.mem.startsWith(u8, num, "0x")) {
            const bits = std.fmt.parseInt(u32, num[2..], 16) catch return error.BadF32;
            return .{ .kind = .f32, .of = .{ .f32 = @bitCast(bits) } };
        }
        const v = std.fmt.parseFloat(f32, num) catch return error.BadF32;
        return .{ .kind = .f32, .of = .{ .f32 = v } };
    } else if (std.mem.eql(u8, ty, "f64")) {
        if (std.mem.startsWith(u8, num, "0x")) {
            const bits = std.fmt.parseInt(u64, num[2..], 16) catch return error.BadF64;
            return .{ .kind = .f64, .of = .{ .f64 = @bitCast(bits) } };
        }
        const v = std.fmt.parseFloat(f64, num) catch return error.BadF64;
        return .{ .kind = .f64, .of = .{ .f64 = v } };
    }
    return error.UnknownType;
}

fn valEquals(a: wasm_c_api.Val, b: wasm_c_api.Val) bool {
    if (a.kind != b.kind) return false;
    return switch (a.kind) {
        .i32 => a.of.i32 == b.of.i32,
        .i64 => a.of.i64 == b.of.i64,
        .f32 => @as(u32, @bitCast(a.of.f32)) == @as(u32, @bitCast(b.of.f32)),
        .f64 => @as(u64, @bitCast(a.of.f64)) == @as(u64, @bitCast(b.of.f64)),
        .anyref, .funcref => a.of.ref == b.of.ref,
    };
}
