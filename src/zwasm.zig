//! zwasm — WebAssembly runtime, library root.
//!
//! Per ADR-0024 D-1/D-2: this file is the `root_source_file` of
//! the `core` Module that build.zig shares across the static lib
//! (`libzwasm.a`), the future shared lib / wasm lib targets, and
//! every test runner. The CLI exe (`zwasm` binary) lives in a
//! separate module rooted at `src/cli/main.zig` that imports
//! this module by name.
//!
//! ## Self-import surface (Bun pattern, ADR-0024 D-3)
//!
//! `core.addImport("zwasm", core)` in build.zig wires the
//! self-import. Any leaf file inside `src/` can write
//! `@import("zwasm").<zone>.<symbol>` to reach the unified
//! re-export hub regardless of how nested it is. Cross-zone
//! refactorings then update one re-export line below instead
//! of touching every leaf's `@import("../<zone>/<file>.zig")`.
//!
//! ## Two-tier import rule (ADR-0024 D-3)
//!
//! - Within-zone sibling: `@import("value.zig")` (relative)
//! - Within-zone parent:  `@import("../runtime.zig")` (relative)
//! - Cross-zone reference: `@import("zwasm").<zone>` (named)
//! - stdlib / builtin / build_options: `@import("std")` etc.
//!
//! ## Library zone classification
//!
//! `src/zwasm.zig` itself sits at "library surface" level — it
//! re-exports Zone 1+ symbols only (no Zone 2/3 export
//! dependencies leak through the surface). zone_check.sh
//! treats it as Zone 1.

const std = @import("std");

pub const version = "0.0.0-pre";

// ============================================================
// Zig facade (ADR-0109 native API) — first-principles Engine +
// Module + Instance + Value surface. Engine + Module live in
// `src/zwasm/{engine,module}.zig`; Instance + Value stay here
// until J.3 lifts Instance onto the native surface. Closes I3
// of `.claude/rules/phase9_close_invariants.md`.
// ============================================================

const _api_instance = @import("api/instance.zig");
const _vec = @import("api/vec.zig");
const _trap_surface = @import("api/trap_surface.zig");

pub const Engine = @import("zwasm/engine.zig").Engine;
pub const Module = @import("zwasm/module.zig").Module;

/// Zig-idiomatic tagged-union mirror of `wasm_val_t`.
/// Wasm spec §4.2.2 — value representation at the host boundary
/// (i32 / i64 / f32 / f64 / v128 / funcref / externref).
pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: u32,
    f64: u64,
    v128: u128,
    funcref: ?u64,
    externref: ?u64,

    pub fn fromI32(v: i32) Value {
        return .{ .i32 = v };
    }
    pub fn fromI64(v: i64) Value {
        return .{ .i64 = v };
    }
    pub fn fromF32Bits(b: u32) Value {
        return .{ .f32 = b };
    }
    pub fn fromF64Bits(b: u64) Value {
        return .{ .f64 = b };
    }
};

fn valueToVal(v: Value) _api_instance.Val {
    return switch (v) {
        .i32 => |x| .{ .kind = .i32, .of = .{ .i32 = x } },
        .i64 => |x| .{ .kind = .i64, .of = .{ .i64 = x } },
        .f32 => |b| .{ .kind = .f32, .of = .{ .f32 = @bitCast(b) } },
        .f64 => |b| .{ .kind = .f64, .of = .{ .f64 = @bitCast(b) } },
        .v128 => .{ .kind = .i64, .of = .{ .i64 = 0 } }, // v128 not yet routed via Val (D-075 v0.2)
        .funcref => |r| .{ .kind = .funcref, .of = .{ .ref = if (r) |p| @ptrFromInt(p) else null } },
        .externref => |r| .{ .kind = .anyref, .of = .{ .ref = if (r) |p| @ptrFromInt(p) else null } },
    };
}

fn valFromApi(v: _api_instance.Val) Value {
    return switch (v.kind) {
        .i32 => .{ .i32 = v.of.i32 },
        .i64 => .{ .i64 = v.of.i64 },
        .f32 => .{ .f32 = @bitCast(v.of.f32) },
        .f64 => .{ .f64 = @bitCast(v.of.f64) },
        .funcref => .{ .funcref = if (v.of.ref) |p| @intFromPtr(p) else null },
        .anyref => .{ .externref = if (v.of.ref) |p| @intFromPtr(p) else null },
    };
}

/// Wasm spec §4.2.5 — instantiated Module Instance. Exposes
/// `invoke(name, args, results)` for the export-call golden path.
/// J.3 will replace this with the native Instance per ADR-0109 §3.5.
pub const Instance = struct {
    handle: *_api_instance.Instance,
    c_store: *_api_instance.Store,

    pub fn deinit(self: *Instance) void {
        _api_instance.wasm_instance_delete(self.handle);
    }

    pub const InvokeError = error{ ExportNotFound, NotAFunc, Trap, TooManyValues };

    /// Look up `name` in the instance's export list, call the
    /// resolved Func, and write results back. The `args` and
    /// `results` slices map 1:1 to the Wasm function signature.
    pub fn invoke(
        self: *Instance,
        name: []const u8,
        args: []const Value,
        results: []Value,
    ) InvokeError!void {
        if (args.len > 16 or results.len > 16) return InvokeError.TooManyValues;

        var exports_vec: _vec.ExternVec = .{ .size = 0, .data = null };
        _api_instance.wasm_instance_exports(self.handle, &exports_vec);
        defer _api_instance.wasm_extern_vec_delete(&exports_vec);

        const dp = exports_vec.data orelse return InvokeError.ExportNotFound;
        const exps = self.handle.exports_storage;
        var func: ?*_api_instance.Func = null;
        for (exps, 0..) |exp, idx| {
            if (idx >= exports_vec.size) break;
            if (!std.mem.eql(u8, exp.name, name)) continue;
            const ext = dp[idx] orelse return InvokeError.NotAFunc;
            func = _api_instance.wasm_extern_as_func(ext);
            break;
        }
        const fh = func orelse return InvokeError.ExportNotFound;

        var args_buf: [16]_api_instance.Val = undefined;
        for (args, 0..) |a, idx| args_buf[idx] = valueToVal(a);
        const args_vec: _vec.ValVec = .{
            .size = args.len,
            .data = if (args.len == 0) null else @ptrCast(&args_buf),
        };

        var results_buf: [16]_api_instance.Val = undefined;
        var results_vec: _vec.ValVec = .{
            .size = results.len,
            .data = if (results.len == 0) null else @ptrCast(&results_buf),
        };

        const trap = _api_instance.wasm_func_call(fh, &args_vec, &results_vec);
        if (trap != null) {
            _trap_surface.wasm_trap_delete(trap);
            return InvokeError.Trap;
        }
        for (results, 0..) |*r, idx| r.* = valFromApi(results_buf[idx]);
    }
};

// ============================================================
// Force-analyse the C-ABI binding files so their `pub export
// fn wasm_*` symbols land in `libzwasm.a` (per ADR-0024 D-2's
// note about subsuming the former `api/lib_export.zig` role).
// `pub const` re-exports below are not enough — Zig only emits
// `export` symbols from compilation units that the analysis
// pass actually visits, and a top-level `pub const` is lazily
// referenced from outside. This `comptime` block forces eager
// analysis at module-root semantics time, mirroring the
// pre-ADR-0023 `c_api_lib.zig` mechanism.
// ============================================================
comptime {
    _ = @import("api/wasm.zig");
    _ = @import("api/wasi.zig");
    _ = @import("api/trap_surface.zig");
    _ = @import("api/vec.zig");
    _ = @import("api/instance.zig");
    _ = @import("api/cross_module.zig");
}

// ============================================================
// Zone re-exports — the public surface for both the library
// archive and the self-import (`@import("zwasm")`) inside leaf
// files.
// ============================================================

// Zone 0
pub const support = struct {
    pub const dbg = @import("support/dbg.zig");
    pub const leb128 = @import("support/leb128.zig");
};
pub const platform = struct {
    pub const jit_mem = @import("platform/jit_mem.zig");
    pub const windows_traphandler = @import("platform/windows_traphandler.zig");
    pub const stack_limit = @import("platform/stack_limit.zig");
    // signal / fs / time are placeholders per ADR-0023 §3 P-H.
};

// Zone 1
pub const ir = struct {
    pub const zir = @import("ir/zir.zig");
    pub const dispatch_table = @import("ir/dispatch_table.zig");
    pub const dispatch_collector = @import("ir/dispatch_collector.zig");
    pub const feature_level_check = @import("ir/feature_level_check.zig");
    pub const wasm_byte_map = @import("ir/wasm_byte_map.zig");
    pub const lower = @import("ir/lower.zig");
    pub const verifier = @import("ir/verifier.zig");
    pub const analysis = struct {
        pub const loop_info = @import("ir/analysis/loop_info.zig");
        pub const liveness = @import("ir/analysis/liveness.zig");
        pub const const_prop = @import("ir/analysis/const_prop.zig");
    };
};
pub const parse = struct {
    pub const parser = @import("parse/parser.zig");
    pub const sections = @import("parse/sections.zig");
    pub const ctx = @import("parse/ctx.zig");
};
pub const validate = struct {
    pub const validator = @import("validate/validator.zig");
};
pub const runtime = @import("runtime/runtime.zig");
pub const diagnostic = @import("diagnostic/diagnostic.zig");
pub const feature = struct {
    pub const mvp = @import("feature/mvp/mod.zig");
    // Active feature register entries — placeholders until the
    // per-feature implementation lands per ROADMAP §11.
    pub const simd_128 = @import("feature/simd_128/register.zig");
    pub const gc = @import("feature/gc/register.zig");
    pub const exception_handling = @import("feature/exception_handling/register.zig");
    pub const tail_call = @import("feature/tail_call/register.zig");
    pub const function_references = @import("feature/function_references/register.zig");
    pub const memory64 = @import("feature/memory64/register.zig");
};

// Zone 2
pub const interp = struct {
    pub const mvp = @import("interp/mvp.zig");
    pub const dispatch = @import("interp/dispatch.zig");
    pub const trap_audit = @import("interp/trap_audit.zig");
};
pub const instruction = struct {
    pub const wasm_1_0 = struct {
        pub const numeric_int = @import("instruction/wasm_1_0/numeric_int.zig");
        pub const numeric_float = @import("instruction/wasm_1_0/numeric_float.zig");
        pub const numeric_conversion = @import("instruction/wasm_1_0/numeric_conversion.zig");
        pub const memory = @import("instruction/wasm_1_0/memory.zig");
        // control / parametric / variable are placeholder skeletons
        // per ADR-0023 §7 item 8 (full split deferred).
    };
    pub const wasm_2_0 = struct {
        pub const sign_extension = @import("instruction/wasm_2_0/sign_extension.zig");
        pub const nontrap_conversion = @import("instruction/wasm_2_0/nontrap_conversion.zig");
        pub const bulk_memory = @import("instruction/wasm_2_0/bulk_memory.zig");
        pub const reference_types = @import("instruction/wasm_2_0/reference_types.zig");
        pub const table_ops = @import("instruction/wasm_2_0/table_ops.zig");
    };
};
pub const engine = struct {
    pub const runner = @import("engine/runner.zig");
    pub const runner_validate = @import("engine/runner_validate.zig");
    pub const export_lookup = @import("engine/export_lookup.zig");
    pub const codegen = struct {
        pub const dispatch_collector = @import("engine/codegen/dispatch_collector.zig");
        pub const shared = struct {
            pub const reg_class = @import("engine/codegen/shared/reg_class.zig");
            pub const regalloc = @import("engine/codegen/shared/regalloc.zig");
            pub const linker = @import("engine/codegen/shared/linker.zig");
            pub const entry = @import("engine/codegen/shared/entry.zig");
            pub const entry_buffer_write = @import("engine/codegen/shared/entry_buffer_write.zig");
            pub const compile = @import("engine/codegen/shared/compile.zig");
            pub const jit_abi = @import("engine/codegen/shared/jit_abi.zig");
            pub const thunk = @import("engine/codegen/shared/thunk.zig");
            pub const canonical_type = @import("engine/codegen/shared/canonical_type.zig");
            pub const result_abi = @import("engine/codegen/shared/result_abi.zig");
            pub const wrapper_thunk = @import("engine/codegen/shared/wrapper_thunk.zig");
        };
        pub const arm64 = struct {
            pub const inst = @import("engine/codegen/arm64/inst.zig");
            pub const inst_neon = @import("engine/codegen/arm64/inst_neon.zig");
            pub const abi = @import("engine/codegen/arm64/abi.zig");
            pub const prologue = @import("engine/codegen/arm64/prologue.zig");
            pub const label = @import("engine/codegen/arm64/label.zig");
            pub const emit = @import("engine/codegen/arm64/emit.zig");
        };
        pub const aot = struct {
            pub const format = @import("engine/codegen/aot/format.zig");
            pub const serialise = @import("engine/codegen/aot/serialise.zig");
            pub const produce = @import("engine/codegen/aot/produce.zig");
        };
    };
};
pub const wasi = struct {
    pub const preview1 = @import("wasi/preview1.zig");
    pub const host = @import("wasi/host.zig");
    pub const fd = @import("wasi/fd.zig");
    pub const clocks = @import("wasi/clocks.zig");
    pub const proc = @import("wasi/proc.zig");
    pub const jit_dispatch = @import("wasi/jit_dispatch.zig");
};

// Zone 3
pub const api = struct {
    pub const wasm = @import("api/wasm.zig");
    pub const wasi_binding = @import("api/wasi.zig");
    pub const trap_surface = @import("api/trap_surface.zig");
    pub const vec = @import("api/vec.zig");
    pub const cross_module = @import("api/cross_module.zig");
    pub const instance = @import("api/instance.zig");
};
pub const cli = struct {
    pub const run = @import("cli/run.zig");
    pub const compile = @import("cli/compile.zig");
    pub const diag_print = @import("cli/diag_print.zig");
};

// ============================================================
// Test loader — pulled by every artifact that uses `core` as
// its `root_module` (lib / test runners). Keeps the unit-test
// surface in one place; mirrors what `src/main.zig` previously
// did but is decoupled from the CLI exe entry.
// ============================================================

test {
    _ = @import("support/leb128.zig");
    _ = @import("support/dbg.zig");
    _ = @import("diagnostic/diagnostic.zig");
    _ = @import("diagnostic/trace.zig");
    _ = @import("cli/diag_print.zig");
    _ = @import("ir/zir.zig");
    _ = @import("ir/dispatch_table.zig");
    _ = @import("ir/dispatch_collector.zig");
    _ = @import("engine/codegen/dispatch_collector.zig");
    _ = @import("ir/wasm_byte_map.zig");
    _ = @import("ir/hoist/pass.zig");
    _ = @import("ir/coalesce/pass.zig");
    _ = @import("engine/codegen/aot/format.zig");
    _ = @import("engine/codegen/aot/serialise.zig");
    _ = @import("engine/codegen/aot/produce.zig");
    _ = @import("cli/compile.zig");
    _ = @import("engine/codegen/shared/reg_class.zig");
    _ = @import("engine/codegen/shared/regalloc.zig");
    _ = @import("engine/codegen/arm64/inst.zig");
    _ = @import("engine/codegen/arm64/inst_neon.zig");
    _ = @import("engine/codegen/arm64/inst_neon_arith.zig");
    _ = @import("engine/codegen/arm64/inst_neon_lane_cmp.zig");
    _ = @import("engine/codegen/arm64/op_simd.zig");
    _ = @import("engine/codegen/arm64/op_simd_int_arith.zig");
    _ = @import("engine/codegen/arm64/op_simd_int_cmp_lane.zig");
    _ = @import("engine/codegen/arm64/op_simd_float.zig");
    _ = @import("engine/codegen/arm64/abi.zig");
    _ = @import("engine/codegen/arm64/emit.zig");
    _ = @import("engine/codegen/arm64/emit_test.zig");
    _ = @import("engine/codegen/x86_64/reg_class.zig");
    _ = @import("engine/codegen/x86_64/inst.zig");
    _ = @import("engine/codegen/x86_64/inst_sse.zig");
    _ = @import("engine/codegen/x86_64/inst_sse_packed.zig");
    _ = @import("engine/codegen/x86_64/inst_sse_scalar.zig");
    _ = @import("engine/codegen/x86_64/abi.zig");
    _ = @import("engine/codegen/x86_64/prologue.zig");
    _ = @import("engine/codegen/x86_64/types.zig");
    _ = @import("engine/codegen/x86_64/label.zig");
    _ = @import("engine/codegen/x86_64/op_alu_int.zig");
    _ = @import("engine/codegen/x86_64/op_alu_float.zig");
    _ = @import("engine/codegen/x86_64/op_simd.zig");
    _ = @import("engine/codegen/x86_64/op_simd_int_arith.zig");
    _ = @import("engine/codegen/x86_64/op_simd_int_cmp_lane.zig");
    _ = @import("engine/codegen/x86_64/op_simd_float.zig");
    _ = @import("engine/codegen/x86_64/op_simd_test.zig");
    _ = @import("engine/codegen/x86_64/op_simd_int_arith_test.zig");
    _ = @import("engine/codegen/x86_64/op_simd_int_cmp_lane_test.zig");
    _ = @import("engine/codegen/x86_64/op_simd_float_test.zig");
    _ = @import("engine/codegen/x86_64/emit.zig");
    _ = @import("engine/codegen/x86_64/emit_test.zig");
    _ = @import("platform/jit_mem.zig");
    _ = @import("platform/windows_traphandler.zig");
    _ = @import("platform/stack_limit.zig");
    _ = @import("engine/codegen/shared/linker.zig");
    _ = @import("engine/codegen/shared/entry.zig");
    _ = @import("engine/codegen/shared/entry_buffer_write.zig");
    _ = @import("engine/codegen/shared/result_abi.zig");
    _ = @import("engine/codegen/shared/wrapper_thunk.zig");
    _ = @import("engine/codegen/shared/jit_abi.zig");
    _ = @import("engine/codegen/shared/compile.zig");
    _ = @import("engine/codegen/shared/thunk.zig");
    _ = @import("engine/codegen/arm64/thunk.zig");
    _ = @import("engine/codegen/x86_64/thunk.zig");
    _ = @import("engine/runner.zig");
    _ = @import("ir/analysis/loop_info.zig");
    _ = @import("ir/analysis/liveness.zig");
    _ = @import("ir/verifier.zig");
    _ = @import("ir/analysis/const_prop.zig");
    _ = @import("parse/parser.zig");
    _ = @import("validate/validator.zig");
    _ = @import("validate/validator_tests.zig");
    _ = @import("ir/lower.zig");
    _ = @import("ir/lower_tests.zig");
    _ = @import("parse/ctx.zig");
    _ = @import("feature/mvp/mod.zig");
    _ = @import("parse/sections.zig");
    _ = @import("runtime/runtime.zig");
    _ = @import("runtime/value.zig");
    _ = @import("runtime/trap.zig");
    _ = @import("runtime/frame.zig");
    _ = @import("interp/dispatch.zig");
    _ = @import("interp/mvp.zig");
    _ = @import("instruction/wasm_1_0/memory.zig");
    _ = @import("interp/trap_audit.zig");
    _ = @import("instruction/wasm_2_0/sign_extension.zig");
    _ = @import("instruction/wasm_2_0/nontrap_conversion.zig");
    _ = @import("instruction/wasm_2_0/bulk_memory.zig");
    _ = @import("instruction/wasm_2_0/reference_types.zig");
    _ = @import("instruction/wasm_2_0/table_ops.zig");
    _ = @import("api/wasm.zig");
    _ = @import("wasi/preview1.zig");
    _ = @import("wasi/host.zig");
    _ = @import("wasi/proc.zig");
    _ = @import("wasi/fd.zig");
    _ = @import("wasi/clocks.zig");
    _ = @import("wasi/jit_dispatch.zig");
    _ = @import("cli/run.zig");
}

// ============================================================
// Zig facade tests (master plan §5.2 + I3 invariant)
// ============================================================

// (module (func (export "main") (result i32) i32.const 255 i32.extend8_s))
// i32.extend8_s is the Wasm 2.0 sign-extension proposal (opcode 0xC0).
// Sign-extending bits[0..8] of 255 (0xFF) yields -1.
const facade_extend8_s_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x01, 0x00, 0x00, 0x00, // version 1
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // function: 1 fn, type 0
    0x07, 0x08, 0x01, 0x04, 0x6D, 0x61, 0x69, 0x6E, 0x00, 0x00, // export "main" (func 0)
    // code section: id=0x0a, size=8 (count + entry_size + 6-byte entry),
    //   count=1, entry_size=6, body = locals_count(0) i32.const 255 (0x41 0xff 0x01)
    //   i32.extend8_s (0xC0) end (0x0B).
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0xff, 0x01, 0xC0, 0x0B,
};

test "zwasm facade Wasm 2.0 round-trip via Engine / Module / Instance / Value" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();

    var mod = try eng.compile(&facade_extend8_s_wasm);
    defer mod.deinit();

    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    var results: [1]Value = .{.{ .i32 = 0 }};
    try inst.invoke("main", &.{}, &results);

    // i32.extend8_s of 0xFF = -1.
    try std.testing.expectEqual(@as(i32, -1), results[0].i32);
}

// T1.1 — Engine + Module lifecycle, allocator strict-pass via a
// recording wrapper. ADR-0109 §4.1 requires the user allocator
// reach internal allocations; recording proves the path.
const RecordingAllocator = struct {
    inner: std.mem.Allocator,
    alloc_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *RecordingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_calls += 1;
        return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.resize(self.inner.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.remap(self.inner.ptr, memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *RecordingAllocator = @ptrCast(@alignCast(ctx));
        self.free_calls += 1;
        self.inner.vtable.free(self.inner.ptr, memory, alignment, ret_addr);
    }
};

test "zwasm facade T1.1: Engine + Module lifecycle — allocator strict-pass" {
    var rec: RecordingAllocator = .{ .inner = std.testing.allocator };

    var eng = try Engine.init(rec.allocator(), .{});
    defer eng.deinit();
    try std.testing.expect(rec.alloc_calls >= 1);

    var mod = try eng.compile(&facade_extend8_s_wasm);
    defer mod.deinit();
    // compile() invokes the native parser which allocates the
    // sections list through the user allocator.
    try std.testing.expect(rec.alloc_calls >= 2);
}

test "zwasm facade T1.2: Module.compile rejects invalid bytes" {
    var eng = try Engine.init(std.testing.allocator, .{});
    defer eng.deinit();

    // Truncated header (< 8 bytes) — native parser returns
    // `TruncatedHeader`, surfaced as `error.ParseFailed`.
    try std.testing.expectError(error.ParseFailed, eng.compile(&[_]u8{ 0x00, 0x61 }));

    // Bad magic — native parser returns `InvalidMagic`.
    const bad_magic = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.ParseFailed, eng.compile(&bad_magic));
}
