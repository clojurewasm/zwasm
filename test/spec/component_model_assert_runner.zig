//! Component Model spec corpus runner (E1 — ADR-0170 campaign).
//!
//! Parallels `spec_assert_runner.zig` (core-wasm) but drives the
//! Component Model host API (`zwasm.component.host`): decode +
//! instantiate a real component, then assert on its lifted exports.
//! Built against a `-Dcomponent=true` `zwasm` module (see build.zig).
//!
//! Walks subdirectories of a corpus root; each subdir has a
//! `manifest.txt` with directives:
//!
//!   `component <path>`                     — decode (classify==component) + instantiate single component
//!   `graph <path>`                         — instantiate a multi-component graph (cross-module link)
//!   `assert_string <export> <arg> -> <s>`  — invokeStringExport; compare UTF-8 result (<s> may contain spaces)
//!   `assert_flat_i32 <export> <a..> -> <v>`— invokeFlat (i32 args); compare results[0].i32
//!   `skip-impl <reason>`                   — implementation gap; counts toward the `skip-impl == 0` gate
//!   `skip-adr-<id> <reason>`               — design-deferred per the named skip-ADR; waived from gate
//!
//! Unlike `spec_assert_runner`, fixture paths are resolved relative to
//! the repo-root cwd (`zig build` runs there), NOT the corpus subdir.
//! This lets a manifest REUSE the single committed fixture under
//! `test/component/` instead of duplicating it into the corpus tree.
//!
//! Per ADR-0174 (win-harden-I lesson): a MISSING corpus root is a hard
//! `exit(1)`, never a silent "0 manifests" skip.
//!
//! Usage: component_model_assert_runner <corpus-root>
//! Exits non-zero if any assertion failed OR the corpus root is absent.
//!
//! Zone: test/ (outside the src/ zone hierarchy per ADR-0023 §A1).

const std = @import("std");

const zwasm = @import("zwasm");
const host = zwasm.feature.component.host;
const Value = zwasm.Value;

const Current = union(enum) {
    none,
    single: host.ComponentInstance,
    graph: host.ComponentGraph,
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
        try stdout.print("usage: component_model_assert_runner <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;
    var skipped_adr: u32 = 0;

    var engine = try zwasm.Engine.init(gpa, .{});
    defer engine.deinit();

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        // ADR-0174: a missing corpus root is a hard failure, not a
        // silent skip (the windowsmini "0 manifests" exit-0 anomaly).
        try stdout.print("error: cannot open corpus root '{s}': {s}\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        runCorpus(io, gpa, &engine, &root, dir_entry.name, stdout, &passed, &failed, &skipped, &skipped_adr) catch |err| {
            try stdout.print("FAIL  {s}: corpus error {s}\n", .{ dir_entry.name, @errorName(err) });
            failed += 1;
        };
    }

    try stdout.print("\ncomponent_model_assert_runner: {d} passed, {d} failed, {d} skipped (= {d} skip-impl + {d} skip-adr)\n", .{ passed, failed, skipped + skipped_adr, skipped, skipped_adr });
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}

fn runCorpus(
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: *zwasm.Engine,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    skipped_adr: *u32,
) !void {
    var dir = try root.openDir(io, name, .{});
    defer dir.close(io);

    const manifest_bytes = try dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 16));
    defer gpa.free(manifest_bytes);

    const cwd = std.Io.Dir.cwd();
    var current: Current = .none;
    var current_bytes: ?[]u8 = null;
    defer {
        switch (current) {
            .none => {},
            .single => |*ci| ci.deinit(),
            .graph => |*g| g.deinit(),
        }
        if (current_bytes) |b| gpa.free(b);
    }

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "skip-impl ")) {
            skipped.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "skip-adr-")) {
            skipped_adr.* += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "component ") or std.mem.startsWith(u8, line, "graph ")) {
            const is_graph = line[0] == 'g';
            const path = std.mem.trim(u8, line[if (is_graph) 6 else 10..], " ");
            // Reset prior fixture state before loading the next one.
            switch (current) {
                .none => {},
                .single => |*ci| ci.deinit(),
                .graph => |*g| g.deinit(),
            }
            current = .none;
            if (current_bytes) |b| gpa.free(b);
            current_bytes = null;

            const bytes = cwd.readFileAlloc(io, path, gpa, .limited(8 << 20)) catch |err| {
                try stdout.print("FAIL  {s}: read '{s}': {s}\n", .{ name, path, @errorName(err) });
                failed.* += 1;
                continue;
            };
            current_bytes = bytes;

            if (is_graph) {
                const g = host.instantiateGraph(engine, gpa, bytes) catch |err| {
                    try stdout.print("FAIL  {s}: instantiateGraph '{s}': {s}\n", .{ name, path, @errorName(err) });
                    failed.* += 1;
                    continue;
                };
                current = .{ .graph = g };
            } else {
                const ci = host.instantiate(engine, gpa, bytes) catch |err| {
                    try stdout.print("FAIL  {s}: instantiate '{s}': {s}\n", .{ name, path, @errorName(err) });
                    failed.* += 1;
                    continue;
                };
                current = .{ .single = ci };
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_string ")) {
            if (runAssertString(gpa, &current, line["assert_string ".len..])) |ok| {
                if (ok) {
                    passed.* += 1;
                    try stdout.print("PASS  {s}: {s}\n", .{ name, line });
                } else {
                    failed.* += 1;
                    try stdout.print("FAIL  {s}: {s} (mismatch)\n", .{ name, line });
                }
            } else |err| {
                failed.* += 1;
                try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_flat_i32 ")) {
            if (runAssertFlatI32(&current, line["assert_flat_i32 ".len..])) |ok| {
                if (ok) {
                    passed.* += 1;
                    try stdout.print("PASS  {s}: {s}\n", .{ name, line });
                } else {
                    failed.* += 1;
                    try stdout.print("FAIL  {s}: {s} (mismatch)\n", .{ name, line });
                }
            } else |err| {
                failed.* += 1;
                try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
            }
            continue;
        }

        try stdout.print("FAIL  {s}: unrecognised directive: {s}\n", .{ name, line });
        failed.* += 1;
    }
}

/// `assert_string <export> <arg> -> <expected>` — `<expected>` may
/// contain spaces (e.g. "Hello, zwasm!"); `<arg>` is a single token.
fn runAssertString(gpa: std.mem.Allocator, current: *Current, rest: []const u8) !bool {
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = std.mem.trim(u8, rest[0..arrow], " ");
    const expected = rest[arrow + 4 ..];
    const sp = std.mem.findScalar(u8, lhs, ' ') orelse return error.BadDirective;
    const export_name = lhs[0..sp];
    const arg = std.mem.trim(u8, lhs[sp + 1 ..], " ");

    const ci = switch (current.*) {
        .single => |*c| c,
        else => return error.NoComponent,
    };
    const result = try ci.invokeStringExport(export_name, arg, gpa);
    defer gpa.free(result);
    return std.mem.eql(u8, result, expected);
}

/// `assert_flat_i32 <export> <i32-arg>* -> <i32>` — invoke a flat
/// export with i32 args and compare `results[0].i32`.
fn runAssertFlatI32(current: *Current, rest: []const u8) !bool {
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = std.mem.trim(u8, rest[0..arrow], " ");
    const expected = try std.fmt.parseInt(i32, std.mem.trim(u8, rest[arrow + 4 ..], " "), 10);

    var arg_it = std.mem.tokenizeScalar(u8, lhs, ' ');
    const export_name = arg_it.next() orelse return error.BadDirective;
    var args: [host.MAX_FLAT_PARAMS]Value = undefined;
    var n: usize = 0;
    while (arg_it.next()) |tok| : (n += 1) {
        if (n >= args.len) return error.TooManyArgs;
        args[n] = .{ .i32 = try std.fmt.parseInt(i32, tok, 10) };
    }

    var results = [_]Value{.{ .i32 = 0 }};
    switch (current.*) {
        // A graph re-exports the linked child's flat func; a single
        // component exposes the lowered core export directly.
        .graph => |*g| try g.invokeFlat(export_name, args[0..n], results[0..1]),
        .single => |*c| try c.invokeCore(export_name, args[0..n], results[0..1]),
        else => return error.NoComponent,
    }
    return results[0].i32 == expected;
}
