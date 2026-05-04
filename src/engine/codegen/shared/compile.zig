//! Single-function JIT pipeline driver (Step 4 / sub-7.5a).
//!
//! Lowers a Wasm function-body byte stream through the full
//! frontend → IR → regalloc → emit chain into a flat
//! `EmitOutput` ready for `jit/linker` to splice into a
//! JitModule.
//!
//! Pipeline:
//!   raw wasm code-section body
//!     → frontend.lowerer.lowerFunctionBody → ZirFunc
//!     → ir.liveness.compute                → Liveness
//!     → jit.regalloc.compute               → Allocation
//!     → jit_arm64.emit.compile             → EmitOutput
//!
//! This module is the integration point — each individual stage
//! has its own tests; this driver verifies they compose into a
//! callable function. The §9.7 / 7.5 spec gate consumes this for
//! every spec testsuite assertion.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const zir = @import("../../../ir/zir.zig");
const ZirFunc = zir.ZirFunc;
const FuncType = zir.FuncType;
const lowerer = @import("../../../ir/lower.zig");
const liveness = @import("../../../ir/analysis/liveness.zig");
const regalloc = @import("regalloc.zig");
const emit = @import("../arm64/emit.zig");

pub const Error = lowerer.Error || liveness.Error || regalloc.Error || emit.Error || Allocator.Error;

/// One function's compilation result. `func` retains lowered
/// ZIR + liveness for downstream consumers (debug dump,
/// regalloc.verify, etc.); `out` carries the emitted bytes +
/// call_fixups for `jit/linker.link`. Caller owns both —
/// pair with `deinitFuncResult` to free.
pub const FuncResult = struct {
    func: ZirFunc,
    alloc_result: regalloc.Allocation,
    out: emit.EmitOutput,
};

pub fn deinitFuncResult(allocator: Allocator, r: *FuncResult) void {
    emit.deinit(allocator, r.out);
    regalloc.deinit(allocator, r.alloc_result);
    if (r.func.liveness) |lv| if (lv.ranges.len != 0) allocator.free(lv.ranges);
    r.func.deinit(allocator);
}

/// Drive a single function body through the pipeline.
///
/// `func_idx` = wasm function index (passed through to ZirFunc).
/// `sig` = the function's FuncType.
/// `body` = the raw wasm code-section body for THIS function
///          (locals prefix + instructions, ending in `end`).
/// `locals` = the function's local-types list (post-decode).
/// `module_types` = the module's type table (for typeidx blocks).
/// `func_sigs` = sigs of all module functions (for `call N`).
pub fn compileOne(
    allocator: Allocator,
    func_idx: u32,
    sig: FuncType,
    body: []const u8,
    locals: []const zir.ValType,
    module_types: []const FuncType,
    func_sigs: []const FuncType,
) Error!FuncResult {
    var func = ZirFunc.init(func_idx, sig, locals);
    errdefer func.deinit(allocator);

    try lowerer.lowerFunctionBody(allocator, body, &func, module_types);

    const lv = try liveness.compute(allocator, &func, func_sigs, module_types);
    func.liveness = lv;

    const alloc = try regalloc.compute(allocator, &func);
    errdefer regalloc.deinit(allocator, alloc);

    const out = try emit.compile(allocator, &func, alloc, func_sigs, module_types);
    errdefer emit.deinit(allocator, out);

    return .{
        .func = func,
        .alloc_result = alloc,
        .out = out,
    };
}

// ============================================================
// Tests
// ============================================================

const builtin = @import("builtin");
const testing = std.testing;
const linker = @import("linker.zig");
const entry = @import("entry.zig");

test "compileOne: tiny straight-line module — (func (result i32) i32.const 7 end) returns 7" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // Pure instruction bytes (locals prefix is consumed by
    // sections.decodeCodes before this function): `i32.const 7`
    // (0x41 0x07) + `end` (0x0B).
    const body = [_]u8{ 0x41, 0x07, 0x0B };
    const sig: FuncType = .{ .params = &.{}, .results = &.{ .i32 } };

    var r = try compileOne(testing.allocator, 0, sig, &body, &.{}, &.{}, &.{sig});
    defer deinitFuncResult(testing.allocator, &r);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = r.out.bytes, .call_fixups = r.out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: entry.JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
    };
    const result = try entry.callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 7), result);
}
