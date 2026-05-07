//! Realworld JIT compile-baseline runner (§9.7 / 7.9 chunk a).
//!
//! Walks `test/realworld/wasm/` and, for each `.wasm` fixture,
//! invokes `engine.runner.compileWasm` (= the JIT pipeline:
//! parse → validate → lower → liveness → regalloc → arm64/x86_64
//! emit → linker.link). Reports per-fixture compile outcome
//! categorised:
//!
//!   COMPILE-PASS    — `compileWasm` returned a `JitModule`.
//!                     Module body fully encoded by the host's
//!                     JIT backend. Does NOT run the entry yet
//!                     (chunks 7.9-c onward wire WASI host
//!                     dispatch + JitRuntime memory init).
//!   COMPILE-IMPORTS — `error.UnsupportedImports`. The wasm
//!                     module imports at least one host
//!                     function (typically WASI). The
//!                     compileWasm import-reject lifts in
//!                     chunk 7.9-b alongside the import-aware
//!                     linker / JitRuntime host-call dispatch.
//!   COMPILE-OP      — `error.UnsupportedOp`. Module compiles
//!                     past parse + validate but the JIT emit
//!                     pass rejects an op (typically memory.copy
//!                     / memory.fill / sign-extension /
//!                     i64-FP-globals — the residual ARM64 emit
//!                     gaps post-§9.7 / 7.7).
//!   COMPILE-VAL     — `error.ModuleAllocFailed` (validator
//!                     rejection — orthogonal to the JIT gate;
//!                     queued as a separate gap).
//!   FAIL-OTHER      — any other error class (real bug).
//!
//! The §9.7 / 7.9 exit criterion is "40+ realworld samples (out
//! of 50) run via ARM64 JIT". This chunk-a baseline measures
//! the COMPILE-side coverage; the chunks 7.9-b/c/d add the
//! infrastructure to convert COMPILE-PASS into RUN-PASS.
//!
//! Mirror of `test/realworld/run_runner.zig`'s shape (interp
//! mode); shares the corpus walk + categorisation idiom.
//!
//! Usage:
//!   zig build test-realworld-run-jit       # walks test/realworld/wasm/
//!   realworld_run_jit_runner_exe <corpus-dir>

const std = @import("std");

const zwasm = @import("zwasm");
const engine_runner = zwasm.engine.runner;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_dir_arg = arg_it.next() orelse {
        try stdout.print("usage: run_runner_jit <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    var total: u32 = 0;
    var compile_pass: u32 = 0;
    var compile_imports: u32 = 0;
    var compile_op: u32 = 0;
    var compile_val: u32 = 0;
    var fail_other: u32 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;
        total += 1;

        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(64 << 20)) catch |err| {
            try stdout.print("FAIL-OTHER  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            fail_other += 1;
            continue;
        };
        defer gpa.free(bytes);

        const result = engine_runner.compileWasm(gpa, bytes);
        if (result) |compiled_const| {
            var compiled = compiled_const;
            compiled.deinit(gpa);
            try stdout.print("COMPILE-PASS  {s}\n", .{entry.name});
            compile_pass += 1;
        } else |err| switch (err) {
            error.UnsupportedImports => {
                try stdout.print("COMPILE-IMPORTS  {s} (host imports — chunk 7.9-b will lift)\n", .{entry.name});
                compile_imports += 1;
            },
            error.UnsupportedOp, error.UnsupportedControlFlow => {
                try stdout.print("COMPILE-OP  {s}: {s}\n", .{ entry.name, @errorName(err) });
                compile_op += 1;
            },
            error.StackTypeMismatch, error.ArityMismatch, error.InvalidLocalIndex,
            error.StackUnderflow, error.InvalidFuncIndex, error.InvalidGlobalIndex,
            error.BadValType, error.UnsupportedEntrySignature,
            => {
                try stdout.print("COMPILE-VAL  {s}: {s}\n", .{ entry.name, @errorName(err) });
                compile_val += 1;
            },
            else => {
                try stdout.print("FAIL-OTHER  {s}: {s}\n", .{ entry.name, @errorName(err) });
                fail_other += 1;
            },
        }
    }

    try stdout.print(
        "\nrealworld_run_jit_runner: {d}/{d} compile-pass, {d} compile-imports, {d} compile-op, {d} compile-val, {d} fail-other\n",
        .{ compile_pass, total, compile_imports, compile_op, compile_val, fail_other },
    );
    try stdout.flush();

    // Chunk 7.9-a baseline gate: this runner exits 0 regardless
    // (compile categorisation is informational at baseline). The
    // §9.7 / 7.9 exit criterion (40+ run-pass) gates on the
    // chunks-b/c/d successor that turns COMPILE-PASS into RUN-
    // PASS. fail-other is a real bug; it does fail the gate.
    if (fail_other != 0) std.process.exit(1);
}
