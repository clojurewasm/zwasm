//! `zwasm` CLI exe entry.
//!
//! Per ADR-0024 D-4: lives at `src/cli/main.zig` (not at the
//! top-level `src/main.zig`) so that the static-library root
//! `src/zwasm.zig` does not pull in `pub fn main` — that would
//! duplicate-define `_main` against C-host examples linking
//! against `libzwasm.a`.
//!
//! The `core` module (rooted at `src/zwasm.zig`) is injected via
//! build.zig as a named import (`addImport("zwasm", core)`); the
//! library symbols are reached as `zwasm.<zone>.<symbol>`.
//!
//! Subcommands:
//!   (none)                    Print version + build options.
//!   run <path.wasm>           Drive a WASI module's `_start` / `main`
//!                             export; exit with the guest's
//!                             `proc_exit` code.
//!   run --invoke <name>       Invoke the named func export (zero-args)
//!   run --engine <interp|jit> Engine: interp (default, full WASI) or jit
//!                             (ADR-0136; compute-only — SIMD/compute, no
//!                             WASI I/O yet). `--engine=jit` also accepted.
//!     <path.wasm>             instead of the default `_start` / `main`
//!                             selection. Phase 11 bench prerequisite
//!                             per §9.12-G; arg marshalling + result
//!                             printing remain Phase 11 scope.
//!   compile <path.wasm>       Produce a `.cwasm` v0.1 artifact (per
//!     -o <out.cwasm>          ADR-0039). Generator pipeline only —
//!                             Phase 12's loader executes the artifact.
//!
//! The surface is `run` + `compile` only (ADR-0159, §16.4): the
//! wasmtime/wazero-aligned あるべき論 shape for a runtime. Validation
//! is programmatic (C-API `wasm_module_validate` / Zig `Engine.compile`);
//! introspection + wat↔wasm conversion are `wasm-tools` / `wabt`'s job —
//! zwasm deliberately does NOT ship `validate`/`inspect`/`features`/
//! `wat`/`wasm` subcommands.

const std = @import("std");
const build_options = @import("build_options");
const zwasm = @import("zwasm");

const cli_run = zwasm.cli.run;
const cli_compile = zwasm.cli.compile;
const cli_dispatch = zwasm.cli.dispatch;
const diag_print = zwasm.cli.diag_print;
const diagnostic = zwasm.diagnostic;
const dbg = zwasm.support.dbg;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // D-009 refactor: Zone 0 dbg.zig has no env-read capability;
    // plumb `ZWASM_DEBUG` down from Zone 3 here. `Map.get`
    // returns null when the var is unset → dbg becomes a no-op.
    dbg.initFromEnv(init.environ_map.get("ZWASM_DEBUG"));

    // §9.8a / 8a.4 — `ZWASM_DIAG` runtime opt-in for the trace
    // ringbuffer drain + future bench/jit_exec channels. Pre-init
    // and `-Dtrace-ringbuffer=false` builds make this a no-op.
    diagnostic.trace.initFromEnv(init.environ_map.get("ZWASM_DIAG"));
    defer diagnostic.trace.drainPassesToStderr();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?; // executable name
    const subcmd_opt = arg_it.next();

    // Top-level verb routing (ADR-0159). help/version/unknown resolve
    // here; run/compile/banner fall through to the logic below (each
    // keeps its own arg parsing). An unrecognised first token is a
    // typo, not an implicit file-run — the surface is explicit.
    switch (cli_dispatch.classify(subcmd_opt)) {
        .help => {
            try printOut(io, cli_dispatch.usage);
            std.process.exit(0);
        },
        .version => {
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "zwasm v{s}\n", .{zwasm.version}) catch "zwasm\n";
            try printOut(io, line);
            std.process.exit(0);
        },
        .unknown => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zwasm: unknown subcommand '{s}' — run 'zwasm --help' for usage", .{subcmd_opt.?}) catch "zwasm: unknown subcommand";
            try printlnErr(io, msg);
            std.process.exit(2);
        },
        .banner, .run, .compile => {},
    }

    if (subcmd_opt) |subcmd| {
        if (std.mem.eql(u8, subcmd, "run")) {
            // Parse `--invoke <name>` ahead of the positional path. The
            // flag must precede the path so the trailing argv (= WASI
            // guest argv) is unambiguous.
            var invoke_name: ?[]const u8 = null;
            // D-273(1) — `--invoke NAME=ARGS`: the `=ARGS` tail (comma-
            // separated, parsed by the export's param types) is split off the
            // single token so the trailing WASI argv stays unambiguous. Null =
            // the zero-arg entry form (`--invoke NAME`).
            var invoke_args: ?[]const u8 = null;
            // ADR-0136 — `--engine=jit` routes the run through the JIT
            // executor (compute-only). Default = interp (the C-API path).
            var engine_jit = false;
            var preopen_list: std.ArrayList(cli_run.PreopenDir) = .empty;
            defer preopen_list.deinit(gpa);
            var next_arg = arg_it.next();
            while (next_arg) |a| {
                if (std.mem.eql(u8, a, "--invoke")) {
                    const spec = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --invoke <name>[=arg1,arg2,...] <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    if (std.mem.findScalar(u8, spec, '=')) |eq| {
                        invoke_name = spec[0..eq];
                        invoke_args = spec[eq + 1 ..];
                    } else {
                        invoke_name = spec;
                    }
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--engine") or std.mem.startsWith(u8, a, "--engine=")) {
                    // Accept both `--engine jit` and `--engine=jit`.
                    const eq = "--engine=";
                    const mode = if (std.mem.startsWith(u8, a, eq))
                        a[eq.len..]
                    else
                        arg_it.next() orelse {
                            try printlnErr(io, "usage: zwasm run --engine <interp|jit> <path.wasm> [args...]");
                            std.process.exit(2);
                        };
                    if (std.mem.eql(u8, mode, "jit")) {
                        engine_jit = true;
                    } else if (std.mem.eql(u8, mode, "interp")) {
                        engine_jit = false;
                    } else {
                        try printlnErr(io, "zwasm run: --engine must be 'interp' or 'jit'");
                        std.process.exit(2);
                    }
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--dir")) {
                    // `--dir <host>[:<guest>]` — preopen a host dir for the
                    // guest. Without a colon the guest path mirrors the host.
                    const spec = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --dir <host>[:<guest>] <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    const colon = std.mem.findScalar(u8, spec, ':');
                    const host_path = if (colon) |c| spec[0..c] else spec;
                    const guest_path = if (colon) |c| spec[c + 1 ..] else spec;
                    try preopen_list.append(gpa, .{ .host_path = host_path, .guest_path = guest_path });
                    next_arg = arg_it.next();
                } else break;
            }
            const path_arg = next_arg orelse {
                try printlnErr(io, "usage: zwasm run [--invoke <name>] [--engine <interp|jit>] [--dir <host>[:<guest>]] <path.wasm> [args...]");
                std.process.exit(2);
            };
            const path = try gpa.dupe(u8, path_arg);
            defer gpa.free(path);

            const cwd = std.Io.Dir.cwd();
            const bytes = cwd.readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "zwasm run: cannot read '{s}': {s}", .{ path, @errorName(err) }) catch "zwasm run: read failed";
                try printlnErr(io, msg);
                std.process.exit(1);
            };
            defer gpa.free(bytes);

            // §12.1 — a pre-compiled AOT artefact (CWAS magic) loads +
            // runs directly, no parse/compile. Compute-only (no WASI /
            // --dir); the entry resolves via the serialised export table.
            // D-273(1) — typed arg-passing + result printing is wired on the
            // interp path only; the JIT/AOT entry runners are zero-arg
            // compute-only. Reject `=ARGS` there rather than silently dropping.
            if (invoke_args != null and (engine_jit or (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "CWAS")))) {
                try printlnErr(io, "zwasm run: --invoke NAME=ARGS arg-passing requires the interp engine (JIT/.cwasm entry is zero-arg compute-only)");
                std.process.exit(2);
            }

            if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "CWAS")) {
                const code = cli_run.runCwasm(gpa, bytes, invoke_name) catch |err| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "zwasm run: cannot run '{s}': {s}", .{ path, @errorName(err) }) catch "zwasm run: .cwasm run failed";
                    try printlnErr(io, msg);
                    std.process.exit(1);
                };
                std.process.exit(code);
            }

            // Build argv for the WASI guest. Wasmtime's default is
            // argv[0] = wasm filename + any trailing args; mirror
            // that here so guests that print argv produce parity
            // bytes.
            var argv_list: std.ArrayList([]const u8) = .empty;
            defer argv_list.deinit(gpa);
            try argv_list.append(gpa, path);
            while (arg_it.next()) |a| try argv_list.append(gpa, a);

            // D-244 — `--engine=jit` now does real WASI (incl. `--dir` preopens).
            const code = (if (engine_jit)
                cli_run.runWasmJit(gpa, io, bytes, invoke_name, argv_list.items, preopen_list.items)
            else
                cli_run.runWasmCapturedOpts(gpa, io, bytes, argv_list.items, null, invoke_name, preopen_list.items, invoke_args)) catch |err| {
                // Per ADR-0016 phase 1: prefer the structured
                // diagnostic when one was set; fall back to the
                // legacy `@errorName` form for unwired sites.
                var stderr_buf: [1024]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
                const stderr = &stderr_writer.interface;
                const source: diag_print.Source = .{ .filename = path, .bytes = bytes };
                if (diagnostic.lastDiagnostic()) |diag| {
                    // EXEMPT-FALLBACK: ADR-0016 phase 1 — diagnostic render is last-resort stderr; re-entry on failure is meaningless.
                    diag_print.formatDiagnostic(diag, source, stderr) catch {};
                } else {
                    // EXEMPT-FALLBACK: ADR-0016 phase 1 — fallback render is last-resort stderr; re-entry on failure is meaningless.
                    diag_print.renderFallback(err, source, stderr) catch {};
                }
                // EXEMPT-FALLBACK: ADR-0016 phase 1 — flushing the same stderr that just rendered the diagnostic; failure here is unrecoverable.
                stderr.flush() catch {};
                std.process.exit(1);
            };
            std.process.exit(code);
        }
        if (std.mem.eql(u8, subcmd, "compile")) {
            const code = cli_compile.run(gpa, io, &arg_it) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "zwasm compile: {s}", .{@errorName(err)}) catch "zwasm compile: failed";
                // EXEMPT-FALLBACK: ADR-0016 phase 1 — compile-error stderr report is last-resort; the process exits 1 regardless.
                printlnErr(io, msg) catch {};
                std.process.exit(1);
            };
            std.process.exit(code);
        }
    }

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("zwasm v{s}\n", .{zwasm.version});
    try stdout.print(
        "  wasm-level: {s}, wasi-level: {s}, engine: {s}\n",
        .{
            @tagName(build_options.wasm_level),
            @tagName(build_options.wasi_level),
            @tagName(build_options.engine_mode),
        },
    );
    try stdout.flush();
}

fn printlnErr(io: std.Io, msg: []const u8) !void {
    var stderr_buf: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print("{s}\n", .{msg});
    try stderr.flush();
}

/// Write `msg` to stdout verbatim (no trailing newline added — callers
/// pass text that already terminates). Used by --help / --version.
fn printOut(io: std.Io, msg: []const u8) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}", .{msg});
    try stdout.flush();
}

test "version is non-empty" {
    try std.testing.expect(zwasm.version.len > 0);
}

test "build options are wired" {
    _ = build_options.wasm_level;
    _ = build_options.wasi_level;
    _ = build_options.engine_mode;
}
