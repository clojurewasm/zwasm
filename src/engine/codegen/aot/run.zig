//! Standalone runner for a loaded `.cwasm` image.
//!
//! Bridges `load.LoadedModule` → execution WITHOUT the original
//! `CompiledWasm` / `.wasm` bytes (the point of AOT: skip parse +
//! compile). The loaded entry is a `callconv(.c) fn(*JitRuntime)…`, so
//! the only missing piece is a `JitRuntime` — which, for a STATELESS
//! entry (no memory / globals / tables / imports), is minimal: the
//! prologue loads the base pointers but never dereferences them and
//! only writes `jit_executed_flag` into the rt struct itself.
//!
//! **Scope (MVP)**: stateless void / i32-result entries. Stateful
//! `.cwasm` (memory / globals / imports) needs format sections the v0.2
//! container does not carry yet — tracked under ADR-0139.
//! Non-void/i32 results (i64 / f32 / f64 / v128 / multi-result) are
//! also deferred; `runEntry` rejects them with `UnsupportedEntrySignature`.
//!
//! Zone 2 (`src/engine/codegen/aot/`): owns the JIT-ABI minimal-runtime
//! construction so Zone-3 callers (`cli/run.zig`) stay ABI-agnostic.

const std = @import("std");

const load = @import("load.zig");
const entry = @import("../shared/entry.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const sections = @import("../../../parse/sections.zig");
// D-251 (AOT-WASI): reuse the JIT's WASI name→handler manifest (`lookup`) so
// the standalone AOT runner shares ONE syscall implementation with the JIT
// path (`jit_dispatch.zig`), no second 46-syscall table.
const jit_dispatch = @import("../../../wasi/jit_dispatch.zig");

const JitRuntime = jit_abi.JitRuntime;

pub const Error = entry.Error || error{
    /// The entry's result type is outside the stateless-MVP subset
    /// (void / i32). i64 / f32 / f64 / v128 / multi-result are later
    /// scope; surfaced loudly rather than reading a garbage register.
    UnsupportedEntrySignature,
    /// A data segment's `[offset, offset+len)` runs past the declared
    /// linear memory (a malformed `.cwasm`; the producer validates valid
    /// modules, so this only fires on corruption).
    MemoryInitOutOfBounds,
    OutOfMemory,
};

/// Backing for the minimal runtime's base pointers. A stateless entry
/// never dereferences these (it has no memory / global / table / import
/// ops); the prologue only LOADs the pointer values + writes
/// `jit_executed_flag` into the rt struct itself. Static lifetime, never
/// written — so aliasing every typed base at it is safe.
var zero_pad: [16]u8 align(16) = [_]u8{0} ** 16;

/// A minimal `JitRuntime` for a stateless entry: zero counts/limits,
/// base pointers aliasing `zero_pad`. `stack_limit` + `trap_flag` are
/// populated per call by `entry.invokeAndCheck` (ADR-0105 D1), so they
/// are left at their struct defaults here.
fn minimalRuntime() JitRuntime {
    return .{
        .vm_base = &zero_pad,
        .mem_limit = 0,
        .funcptr_base = @ptrCast(@alignCast(&zero_pad)),
        .table_size = 0,
        .typeidx_base = @ptrCast(@alignCast(&zero_pad)),
        .trap_flag = 0,
        .globals_base = @ptrCast(@alignCast(&zero_pad)),
        .globals_count = 0,
        .host_dispatch_base = @ptrCast(@alignCast(&zero_pad)),
        .host_dispatch_count = 0,
    };
}

/// Default host-import trap trampoline (D-251 AOT-WASI, mirrors
/// `setup.hostDispatchTrap`). Planted in every `host_dispatch_base[i]`
/// slot a WASI handler did not claim; sets `rt.trap_flag = 1` and returns
/// the 0 sentinel. The entry shim's post-return `trap_flag` read
/// distinguishes this from a genuine 0 result. C-ABI; reads only arg0
/// (`rt`) — extra Wasm args passed by the caller are ignored, which is
/// safe on AAPCS64 / SysV / Win64.
fn hostDispatchTrap(rt: *JitRuntime) callconv(.c) u64 {
    rt.trap_flag = 1;
    return 0;
}

/// WASI wiring for `runEntryWasi`: the opaque `*wasi.host.Host` plus the
/// populated func-import-indexed host-dispatch table (WASI syscall
/// fn-ptrs). `runEntryInner` installs both onto the JitRuntime.
const WasiWiring = struct {
    host: *anyopaque,
    dispatch: []const usize,
};

/// Run defined function `idx` of a loaded `.cwasm` with a minimal
/// stateless runtime; returns the result widened to u64 (0 for a void
/// entry). Propagates `Error.Trap`; rejects out-of-subset result types.
/// COMPUTE-ONLY — a `.cwasm` that imports WASI traps on the first import
/// call (use `runEntryWasi` to attach a host).
pub fn runEntry(loaded: *const load.LoadedModule, idx: usize) Error!u64 {
    return runEntryInner(loaded, idx, null, null);
}

/// Like `runEntry` but attaches a WASI host (`host` = `*wasi.host.Host`)
/// so a `.cwasm` importing `wasi_snapshot_preview1` does REAL I/O —
/// `fd_write`→stdout, clock / random / args / preopen file ops, and
/// `proc_exit(N)` recording the exit code — by rebuilding
/// `host_dispatch_base` from the v0.4 imports section and pointing
/// `rt.wasi_host` at `host`. The dispatch handlers are the JIT path's
/// (`jit_dispatch.zig`), so AOT + JIT share one WASI implementation. A
/// `proc_exit` surfaces as `Error.Trap` with the code on the host (the
/// caller reads `host.exit_code`).
/// `trap_code_out` (ADR-0164 workstream A): mirrors `runner.runVoidExportWasi` —
/// on a trap, receives `JitRuntime.trap_kind` so the CLI surfaces a per-kind
/// message. `proc_exit` also unwinds via `Error.Trap`; the caller reads
/// `host.exit_code` FIRST and only surfaces the trap-kind when none is set.
pub fn runEntryWasi(loaded: *const load.LoadedModule, idx: usize, host: *anyopaque, trap_code_out: ?*u32) Error!u64 {
    // Size the dispatch table to the FUNCTION-import count (the wasm
    // function-index space — table/memory/global/tag imports occupy no
    // dispatch slot). populateDispatch / the JIT body index it by func idx.
    var n_func_imports: usize = 0;
    for (loaded.imports) |imp| {
        if (imp.kind == @intFromEnum(sections.ImportKind.func)) n_func_imports += 1;
    }
    const dispatch = try loaded.allocator.alloc(usize, n_func_imports);
    defer loaded.allocator.free(dispatch);
    for (dispatch) |*slot| slot.* = @intFromPtr(&hostDispatchTrap);

    // Resolve each WASI func import to its handler via the shared manifest;
    // non-WASI / unknown imports keep the trap trampoline. The func-import
    // index increments only on func imports (mirrors jit_dispatch.populateDispatch).
    var fi: usize = 0;
    for (loaded.imports) |imp| {
        if (imp.kind != @intFromEnum(sections.ImportKind.func)) continue;
        if (jit_dispatch.lookup(imp.module, imp.name)) |ptr| dispatch[fi] = ptr;
        fi += 1;
    }

    return runEntryInner(loaded, idx, .{ .host = host, .dispatch = dispatch }, trap_code_out);
}

fn runEntryInner(loaded: *const load.LoadedModule, idx: usize, wasi: ?WasiWiring, trap_code_out: ?*u32) Error!u64 {
    var rt = minimalRuntime();
    // Wire the reconstructed globals. `LoadedModule.globals` is
    // `[]u128` = the runtime's `[]Value` (extern union, 16 B, 16-align) bit
    // pattern, so a pointer cast suffices (no copy). A `global.set` during
    // the run mutates this owned buffer in place — fine for a single call.
    if (loaded.globals.len > 0) {
        rt.globals_base = @ptrCast(loaded.globals.ptr);
        rt.globals_count = @intCast(loaded.globals.len);
    }

    // Reconstruct linear memory (alloc min_pages×64KB,
    // memcpy active data segments). Freed after the call — unlike globals
    // it is not aliased from `loaded`.
    var memory: []u8 = &.{};
    defer if (memory.len > 0) loaded.allocator.free(memory);
    if (loaded.has_memory and loaded.mem_min_pages > 0) {
        memory = try loaded.allocator.alloc(u8, @as(usize, loaded.mem_min_pages) * 65536);
        @memset(memory, 0);
        for (loaded.mem_data) |seg| {
            if (@as(u64, seg.mem_offset) + seg.bytes.len > memory.len) return Error.MemoryInitOutOfBounds;
            @memcpy(memory[seg.mem_offset..][0..seg.bytes.len], seg.bytes);
        }
        rt.vm_base = memory.ptr;
        rt.mem_limit = memory.len;
    }

    // Wire table 0 (call_indirect fast path reads these
    // scalars). Aliased from `loaded` (built at load, no per-call copy).
    if (loaded.table_size > 0) {
        rt.funcptr_base = loaded.funcptr_base.ptr;
        rt.table_size = loaded.table_size;
        rt.typeidx_base = loaded.typeidx_base.ptr;
    }

    // D-251: install the WASI host + dispatch table so import calls in the
    // JIT body route through the real handlers (else the compute-only path's
    // trap trampoline fires on the first import call).
    if (wasi) |w| {
        rt.host_dispatch_base = w.dispatch.ptr;
        rt.host_dispatch_count = @intCast(w.dispatch.len);
        rt.wasi_host = w.host;
    }

    const VoidFn = *const fn (*const JitRuntime) callconv(.c) void;
    const I32Fn = *const fn (*const JitRuntime) callconv(.c) u32;
    return runDispatch(loaded, idx, &rt, VoidFn, I32Fn) catch |err| {
        if (err == Error.Trap) {
            if (trap_code_out) |p| p.* = rt.trap_kind;
        }
        return err;
    };
}

fn runDispatch(loaded: *const load.LoadedModule, idx: usize, rt: *JitRuntime, comptime VoidFn: type, comptime I32Fn: type) Error!u64 {
    return switch (loaded.resultKind(idx)) {
        .void_ => blk: {
            try entry.callVoidNoArgsPtr(loaded.entry(idx, VoidFn), rt);
            break :blk 0;
        },
        .i32_ => @as(u64, try entry.callI32NoArgsPtr(loaded.entry(idx, I32Fn), rt)),
        .i64_, .f32_, .f64_, .unsupported => Error.UnsupportedEntrySignature,
    };
}

// =====================================================================
// Tests
// =====================================================================

const builtin = @import("builtin");
const testing = std.testing;
const serialise = @import("serialise.zig");
const format = @import("format.zig");
const skip = @import("../../../test_support/skip.zig");

test "runEntry: stateless () -> i32 const executes via the minimal runtime, returns 7" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);

    const arch_tag: u32 = switch (builtin.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => @compileError("unsupported arch for AOT standalone-run test"),
    };
    // `() -> i32` returning 7 (ignores the rt arg). arm64: MOVZ X0,#7 ; RET.
    // x86_64: mov eax,7 ; ret.
    const fn_bytes: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => &[_]u8{ 0xE0, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6 },
        .x86_64 => &[_]u8{ 0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3 },
        else => unreachable,
    };
    // Real types section so `resultKind` parses i32: one FuncType,
    // 0 params, 1 result, valtype byte 0 (= i32 tag).
    const types_serialised = [_]u8{ 0x00, 0x01, 0x00 };

    const cwasm = try serialise.produceCwasm(testing.allocator, .{
        .arch = arch_tag,
        .bytes_per_func = &.{fn_bytes},
        .n_slots_per_func = &.{1},
        .sig_idx_per_func = &.{0},
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &types_serialised,
        .n_imports = 0,
        .n_types = 1,
        .exports = &.{.{ .name = "f", .func_idx = 0 }},
    });
    defer testing.allocator.free(cwasm);

    var mod = try load.load(testing.allocator, cwasm);
    defer mod.deinit();

    const idx = mod.resolveEntry("f").?;
    try testing.expectEqual(load.ResultKind.i32_, mod.resultKind(idx));
    try testing.expectEqual(@as(u64, 7), try runEntry(&mod, idx));
}

test "runEntry: rejects an out-of-subset (f64) result with UnsupportedEntrySignature" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);

    const arch_tag: u32 = switch (builtin.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => return,
    };
    // Body is never executed (rejected before the call). f64 result =
    // valtype tag 3.
    const fn_bytes: []const u8 = &[_]u8{ 0xC0, 0x03, 0x5F, 0xD6 };
    const types_serialised = [_]u8{ 0x00, 0x01, 0x03 };

    const cwasm = try serialise.produceCwasm(testing.allocator, .{
        .arch = arch_tag,
        .bytes_per_func = &.{fn_bytes},
        .n_slots_per_func = &.{0},
        .sig_idx_per_func = &.{0},
        .relocs = &.{},
        .func_idx_for_reloc = &.{},
        .types_serialised = &types_serialised,
        .n_imports = 0,
        .n_types = 1,
        .exports = &.{.{ .name = "f", .func_idx = 0 }},
    });
    defer testing.allocator.free(cwasm);

    var mod = try load.load(testing.allocator, cwasm);
    defer mod.deinit();

    try testing.expectError(Error.UnsupportedEntrySignature, runEntry(&mod, mod.resolveEntry("f").?));
}
