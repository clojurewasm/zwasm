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
//!   run --engine <interp|jit> Engine: interp (default) or jit — BOTH do full
//!                             WASI (D-244); jit additionally executes SIMD
//!                             (the interp does not). `--engine=jit` accepted.
//!     <path.wasm>             instead of the default `_start` / `main`
//!                             selection. Typed `--invoke NAME=a,b,...`
//!                             arg marshalling + result printing are
//!                             handled in `cli/invoke_args.zig` (D-273).
//!   compile <path.wasm>       Produce a `.cwasm` v0.1 artifact (per
//!     -o <out.cwasm>          ADR-0039). Generator side; `run
//!                             <file.cwasm>` loads + executes it.
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
    // ADR-0166 (D-292 B-core): install the diagnostic-only internal-fault
    // handler FIRST, so any later internal SIGSEGV/crash surfaces a distinct
    // "internal error" + exit 70 instead of a silent signal-death. v2 has no
    // signal-based wasm traps, so any fatal signal here is a zwasm bug.
    zwasm.platform.signal.installInternalFaultHandler();

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

    // ADR-0166 hidden test affordance (D-292 B-core): deliberately trigger an
    // internal fault so the handler installed above is exercised end-to-end (→
    // "internal error" line + exit 70). Used by the `test-internal-fault` build
    // step to verify the handler on each host. Not advertised in `--help`.
    if (subcmd_opt) |sc| {
        if (std.mem.eql(u8, sc, "--__selftest-crash")) {
            const p: *allowzero volatile u8 = @ptrFromInt(0);
            p.* = 0;
            unreachable; // the fault handler exits(70) before control returns here
        }
    }

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
            var buf: [192]u8 = undefined;
            const line = cli_dispatch.versionLine(&buf, zwasm.version, @tagName(build_options.wasm_level), @tagName(build_options.wasi_level), @tagName(build_options.engine_mode));
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
            // ADR-0136 — `--engine=jit` routes the run through the JIT executor
            // (full WASI via D-244 + SIMD). Default = interp (the C-API path).
            var engine_jit = false;
            var preopen_list: std.ArrayList(cli_run.PreopenDir) = .empty;
            defer preopen_list.deinit(gpa);
            // D-295 P0 — `--env KEY=VAL`: WASI environ injected into the guest
            // via the host's setEnvs (parallel keys/vals slices).
            var env_keys: std.ArrayList([]const u8) = .empty;
            defer env_keys.deinit(gpa);
            var env_vals: std.ArrayList([]const u8) = .empty;
            defer env_vals.deinit(gpa);
            // ADR-0179 #3a-4 / D-314 — `--fuel` / `--timeout` / `--max-memory`.
            var limits: cli_run.Limits = .{};
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
                        // D-496 `.auto`→JIT flip: the default captured path now prefers
                        // JIT, so an EXPLICIT `--engine interp` must force interp.
                        limits.engine = .interp;
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
                } else if (std.mem.eql(u8, a, "--env")) {
                    // `--env KEY=VAL` — inject a WASI environment variable. A
                    // bare `--env KEY` (no '=') sets an empty value, matching
                    // wasmtime's permissive parse.
                    const spec = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --env KEY=VAL <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    if (std.mem.findScalar(u8, spec, '=')) |eq| {
                        try env_keys.append(gpa, spec[0..eq]);
                        try env_vals.append(gpa, spec[eq + 1 ..]);
                    } else {
                        try env_keys.append(gpa, spec);
                        try env_vals.append(gpa, spec[spec.len..]);
                    }
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--fuel")) {
                    const v = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --fuel <N> <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    limits.fuel = std.fmt.parseInt(u64, v, 10) catch {
                        try printlnErr(io, "zwasm run: --fuel expects a non-negative integer");
                        std.process.exit(2);
                    };
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--timeout")) {
                    const v = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --timeout <ms> <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    limits.timeout_ms = std.fmt.parseInt(u64, v, 10) catch {
                        try printlnErr(io, "zwasm run: --timeout expects milliseconds as a non-negative integer");
                        std.process.exit(2);
                    };
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--max-memory")) {
                    const v = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --max-memory <bytes> <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    limits.max_memory_bytes = std.fmt.parseInt(u64, v, 10) catch {
                        try printlnErr(io, "zwasm run: --max-memory expects bytes as a non-negative integer");
                        std.process.exit(2);
                    };
                    next_arg = arg_it.next();
                } else if (std.mem.eql(u8, a, "--max-table-elements")) {
                    const v = arg_it.next() orelse {
                        try printlnErr(io, "usage: zwasm run --max-table-elements <N> <path.wasm> [args...]");
                        std.process.exit(2);
                    };
                    limits.max_table_elements = std.fmt.parseInt(u64, v, 10) catch {
                        try printlnErr(io, "zwasm run: --max-table-elements expects a non-negative integer");
                        std.process.exit(2);
                    };
                    next_arg = arg_it.next();
                } else break;
            }
            const path_arg = next_arg orelse {
                try printlnErr(io, "usage: zwasm run [--invoke <name>] [--engine <interp|jit>] [--dir <host>[:<guest>]] [--env KEY=VAL] [--fuel <N>] [--timeout <ms>] [--max-memory <bytes>] [--max-table-elements <N>] <path.wasm> [args...]");
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

            // D-273(1) / D-477 — typed arg-passing now runs on BOTH the interp
            // AND the JIT engine (D-477 buffer-write thunk). The AOT (.cwasm)
            // entry runner is still zero-arg, so reject `=ARGS` only there.
            if (invoke_args != null and bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "CWAS")) {
                try printlnErr(io, "zwasm run: --invoke NAME=ARGS arg-passing is not wired for .cwasm AOT artifacts (run the .wasm form)");
                std.process.exit(2);
            }

            // Build argv for the WASI guest. Wasmtime's default is
            // argv[0] = wasm filename + any trailing args; mirror
            // that here so guests that print argv produce parity
            // bytes. Both the `.cwasm` and `.wasm` paths consume it.
            var argv_list: std.ArrayList([]const u8) = .empty;
            defer argv_list.deinit(gpa);
            try argv_list.append(gpa, path);
            while (arg_it.next()) |a| try argv_list.append(gpa, a);

            // §12.1 / D-251 — a pre-compiled AOT artefact (CWAS magic) loads +
            // runs directly (no parse/compile) and now does REAL WASI: argv +
            // `--dir` preopens are threaded into a host, so a WASI-importing
            // `.cwasm` prints / exits / sees args like the `.wasm` path.
            if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "CWAS")) {
                // ADR-0179 #3a-4 — refuse loudly rather than silently running
                // an UNSANDBOXED .cwasm when the user asked for limits (the
                // AOT runner's limit threading is a follow-up; no_workaround).
                if (limits.any()) {
                    try printlnErr(io, "zwasm run: --fuel/--timeout/--max-memory are not wired for .cwasm artifacts yet (run the .wasm form, or drop the flag)");
                    std.process.exit(2);
                }
                const code = cli_run.runCwasmWasi(gpa, io, bytes, invoke_name, argv_list.items, preopen_list.items, env_keys.items, env_vals.items, null) catch |err| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "zwasm run: cannot run '{s}': {s}", .{ path, @errorName(err) }) catch "zwasm run: .cwasm run failed";
                    try printlnErr(io, msg);
                    std.process.exit(1);
                };
                std.process.exit(code);
            }

            // CM campaign D1-2 / D-306 — a component-layer module (preamble
            // version 0x0d, layer byte = 0x01) routes to the component host
            // (`runWasiP2Main`), not the core-module runner. stdio subset.
            if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..4], "\x00asm") and bytes[6] == 0x01) {
                if (comptime !@import("build_options").enable_component) {
                    try printlnErr(io, "zwasm run: component support not compiled in (rebuild with -Dwasi=p2 or higher)");
                    std.process.exit(2);
                }
                // ADR-0179 #3a-4 — same loud refusal for the component host.
                if (limits.any()) {
                    try printlnErr(io, "zwasm run: --fuel/--timeout/--max-memory are not wired for components yet (core modules only)");
                    std.process.exit(2);
                }
                const code = cli_run.runComponentWasi(gpa, io, bytes, argv_list.items, preopen_list.items) catch |err| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "zwasm run: cannot run component '{s}': {s}", .{ path, @errorName(err) }) catch "zwasm run: component run failed";
                    try printlnErr(io, msg);
                    std.process.exit(1);
                };
                std.process.exit(code);
            }

            // D-244 — `--engine=jit` now does real WASI (incl. `--dir` preopens).
            // D-477 — typed `--invoke NAME=ARGS` now also runs on the JIT engine
            // (marshalled through the generalized buffer-write thunk).
            const code = (if (engine_jit)
                cli_run.runWasmJitCaptured(gpa, io, bytes, invoke_name, argv_list.items, preopen_list.items, env_keys.items, env_vals.items, limits, null, invoke_args)
            else
                cli_run.runWasmCapturedOpts(gpa, io, bytes, argv_list.items, null, invoke_name, preopen_list.items, env_keys.items, env_vals.items, invoke_args, limits)) catch |err| {
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
