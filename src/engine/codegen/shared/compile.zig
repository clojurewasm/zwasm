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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const zir = @import("../../../ir/zir.zig");
const ZirFunc = zir.ZirFunc;
const FuncType = zir.FuncType;
const lowerer = @import("../../../ir/lower.zig");
const liveness = @import("../../../ir/analysis/liveness.zig");
const regalloc = @import("regalloc.zig");

/// 7.5-close-d042 / 7.8 prep: comptime arch dispatch. ARM64 hosts
/// (Mac) use `arm64/emit.zig`; x86_64 hosts (Linux + Windows) use
/// `x86_64/emit.zig`. Both expose the same `compile() / deinit() /
/// EmitOutput / Error / CallFixup` surface so the dispatch is a
/// pure import switch.
const emit = switch (builtin.target.cpu.arch) {
    .aarch64 => @import("../arm64/emit.zig"),
    .x86_64 => @import("../x86_64/emit.zig"),
    else => @compileError("unsupported host arch — JIT requires aarch64 or x86_64"),
};

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
/// `func_sigs` = sigs of all module functions (for `call N`),
///               wasm-space (imports first, defined after).
/// `num_imports` = leading wasm-space indices that name function
///                 imports (chunk 7.9-b foundation). The emit pass
///                 routes a `call N` with `N < num_imports` to the
///                 function-local trap stub instead of a body-
///                 relative BL/CALL — host-call dispatch lands at
///                 chunk 7.9-c.
pub fn compileOne(
    allocator: Allocator,
    func_idx: u32,
    sig: FuncType,
    body: []const u8,
    locals: []const zir.ValType,
    module_types: []const FuncType,
    func_sigs: []const FuncType,
    num_imports: u32,
) Error!FuncResult {
    var func = ZirFunc.init(func_idx, sig, locals);
    errdefer func.deinit(allocator);

    try lowerer.lowerFunctionBody(allocator, body, &func, module_types);

    // §9.8 / 8.4-d INTEGRATION DEFERRED — the local-set/local-get
    // rewrite hoist (`src/ir/hoist/pass.zig`) compiles + unit-
    // tests cleanly but realworld_run_jit regressed 52/55+15 →
    // 42/55+8 with new UnsupportedOp source unidentified after
    // the first diagnostic round. D-053 carries the redesign
    // forward; the module is preserved as code (helpers,
    // synthetic_locals slot, hoisted_constants struct fields all
    // staged in zir.zig + 4 emit consumer sites migrated to
    // `func.totalLocalCount()` / `func.localValType(idx)`
    // helpers) so a future cycle can wire it once the
    // UnsupportedOp source is localised.
    const lv = try liveness.compute(allocator, &func, func_sigs, module_types);
    func.liveness = lv;
    // ZirFunc.deinit does NOT walk into the (optional) liveness
    // slot — that slot is owned by the FuncResult, freed via
    // `deinitFuncResult`. If regalloc / emit errors below, the
    // FuncResult is never constructed and the errdefer chain
    // would leak `lv.ranges`. Mirror deinitFuncResult's free
    // here so the unwind path is symmetric.
    errdefer if (lv.ranges.len != 0) allocator.free(lv.ranges);

    var alloc = try regalloc.compute(allocator, &func);
    errdefer regalloc.deinit(allocator, alloc);
    // D-045 chunk 13b: override per-arch class boundaries so that
    // slot ids past the host's pool size resolve to `.spill` (not
    // a null `slotToReg` the way the arm64-tuned defaults would
    // do at slot 4..7 on x86_64). The defaults in
    // `Allocation` (max_reg_slots_gpr=8, max_reg_slots_fp=13) match
    // arm64; x86_64 has 4 GPRs / 6 XMMs in its pool post-13b.
    // `emit.allocatable_gprs.len` / `emit.allocatable_xmms.len`
    // is the canonical source.
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            const x86_abi = @import("../x86_64/abi.zig");
            alloc.max_reg_slots_gpr = x86_abi.allocatable_gprs.len;
            alloc.max_reg_slots_fp = x86_abi.allocatable_xmms.len;
        },
        .aarch64 => {
            // Defaults already match arm64 pool sizes.
        },
        else => @compileError("unsupported host arch"),
    }

    const out = try emit.compile(allocator, &func, alloc, func_sigs, module_types, num_imports);
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
    const sig: FuncType = .{ .params = &.{}, .results = &.{.i32} };

    var r = try compileOne(testing.allocator, 0, sig, &body, &.{}, &.{}, &.{sig}, 0);
    defer deinitFuncResult(testing.allocator, &r);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = r.out.bytes, .call_fixups = r.out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: entry.JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const result = try entry.callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 7), result);
}
