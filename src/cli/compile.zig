//! `zwasm compile <input.wasm> -o <output.cwasm>` subcommand
//! handler (§9.8b / 8b.3-d per ADR-0039).
//!
//! Reads a `.wasm` file, runs it through the JIT pipeline
//! (`engine.runner.compileWasm`), then wraps the per-func
//! emit outputs into a `.cwasm` v0.1 artifact via
//! `engine.codegen.aot.produce.produceFromCompiledWasm`,
//! and writes the artifact to disk.
//!
//! Generator side of the `.cwasm` pipeline; `zwasm run <file.cwasm>`
//! executes the artifact through the full-fidelity deserializer + the
//! normal JIT setup path (ADR-0203 stage 3 — same flow as a `.wasm`).
//!
//! Zone 3 (`src/cli/`).

const std = @import("std");

const zwasm = @import("zwasm");
const runner = zwasm.engine.runner;
const aot_produce = zwasm.engine.codegen.aot.produce;

const Allocator = std.mem.Allocator;

pub const Error = error{
    UsageError,
    ReadInputFailed,
    WriteOutputFailed,
} || runner.Error || aot_produce.Error;

/// Drive the compile subcommand. `arg_it` is positioned past
/// the leading `compile` token; the handler consumes
/// `<input.wasm>` and `-o <output.cwasm>` (in either order).
/// Returns the exit code: 0 on success, non-zero on usage /
/// runtime failure (caller surfaces stderr separately).
pub fn run(
    gpa: Allocator,
    io: std.Io,
    arg_it: anytype,
) Error!u8 {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = arg_it.next() orelse return Error.UsageError;
        } else if (input_path == null) {
            input_path = arg;
        } else {
            return Error.UsageError;
        }
    }

    const in = input_path orelse return Error.UsageError;
    const out = output_path orelse return Error.UsageError;

    const cwd = std.Io.Dir.cwd();
    const wasm_bytes = cwd.readFileAlloc(io, in, gpa, .limited(64 * 1024 * 1024)) catch {
        return Error.ReadInputFailed;
    };
    defer gpa.free(wasm_bytes);

    // ADR-0203 stage 4 — the compile honours the ambient bounds mode
    // (default `.auto` → elided on qualifying memories); the artifact
    // records `flag_bounds_elided` and the loader upholds the ADR-0202
    // guarded-binding invariant.
    var compiled = try runner.compileWasmForAot(gpa, wasm_bytes);
    defer compiled.deinit(gpa);

    const cwasm_bytes = try aot_produce.produceFromCompiledWasm(gpa, &compiled, wasm_bytes);
    defer gpa.free(cwasm_bytes);

    cwd.writeFile(io, .{ .sub_path = out, .data = cwasm_bytes }) catch {
        return Error.WriteOutputFailed;
    };

    return 0;
}
