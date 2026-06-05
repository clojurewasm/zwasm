//! End-to-end JIT trap-KIND tests (ADR-0164 workstream A / D-292). Split from
//! `runner_test.zig` (P1 spec-defined sub-language — Wasm trap kinds — + P3
//! independent change cadence: the trap-kind widening kept pushing
//! `runner_test.zig` toward the 2000-line hard cap, mirroring the
//! `runner_gc_test.zig` split). Each test compiles a `_start` that traps a
//! specific way, runs it through the JIT void-export path, and asserts the
//! precise `JitRuntime.trap_kind` code the codegen recorded maps to the
//! interp-parity `TrapKind`. Discovered via `src/zwasm.zig`'s `test {}` block.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const skip = @import("../test_support/skip.zig");

const runner = @import("runner.zig");
const entry = @import("codegen/shared/entry.zig");
const trap_surface = @import("../api/trap_surface.zig");

// `(module (func (export "_start") unreachable))` — the JIT lowers `unreachable`
// to an unconditional branch into a dedicated trap stub recording trap-kind 5.
const unreachable_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x05,
    0x01, 0x03, 0x00, 0x00, 0x0b,
};

test "runVoidExportWasi: a JIT `unreachable` surfaces the precise trap-kind code 5 (ADR-0164 A / D-292)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var trap_code: u32 = 99; // sentinel: must be overwritten by the trap path
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &unreachable_start_wasm, "_start", null, &trap_code));
    // D-292 widening: `unreachable` now records the PRECISE code 5 on BOTH arches
    // (was the arch-divergent generic bucket — arm64 1, x86_64 0). 5 maps to
    // TrapKind.unreachable_ via trap_surface.jitTrapCode, reaching interp-parity.
    try testing.expectEqual(@as(u32, 5), trap_code);
    try testing.expectEqual(trap_surface.TrapKind.unreachable_, trap_surface.jitTrapCode(trap_code).?);
}

// `(module (func (export "_start") i32.const 1 i32.const 0 i32.div_s drop))` —
// the div-by-zero check traps before the IDIV/SDIV (ADR-0164 A2 / D-292: code 7).
const divzero_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0a,
    0x01, 0x08, 0x00, 0x41, 0x01, 0x41, 0x00, 0x6d,
    0x1a, 0x0b,
};

// `(module (func (export "_start") i32.const INT_MIN i32.const -1 i32.div_s drop))` —
// signed-overflow check traps on INT_MIN / -1 (ADR-0164 A2 / D-292: code 8).
const div_overflow_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73,
    0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a, 0x0e,
    0x01, 0x0c, 0x00, 0x41, 0x80, 0x80, 0x80, 0x80,
    0x78, 0x41, 0x7f, 0x6d, 0x1a, 0x0b,
};

test "runVoidExportWasi: JIT div-by-zero → precise code 7; div_s overflow → code 8 (ADR-0164 A2 / D-292)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var dz: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &divzero_start_wasm, "_start", null, &dz));
    try testing.expectEqual(@as(u32, 7), dz);
    try testing.expectEqual(trap_surface.TrapKind.div_by_zero, trap_surface.jitTrapCode(dz).?);
    var ov: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &div_overflow_start_wasm, "_start", null, &ov));
    try testing.expectEqual(@as(u32, 8), ov);
    try testing.expectEqual(trap_surface.TrapKind.int_overflow, trap_surface.jitTrapCode(ov).?);
}

// `(module (memory 1) (func (export "_start") i32.const 65536 i32.load drop))` —
// the load at ea=65536 (1-page memory = indices 0..65535) is out of bounds
// (ADR-0164 A3 / D-292: oob_memory code 6).
const oob_load_start_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07,
    0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72,
    0x74, 0x00, 0x00, 0x0a, 0x0c, 0x01, 0x0a, 0x00,
    0x41, 0x80, 0x80, 0x04, 0x28, 0x02, 0x00, 0x1a,
    0x0b,
};

test "runVoidExportWasi: JIT out-of-bounds load → precise oob_memory code 6 (ADR-0164 A3 / D-292)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var oob: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &oob_load_start_wasm, "_start", null, &oob));
    try testing.expectEqual(@as(u32, 6), oob);
    try testing.expectEqual(trap_surface.TrapKind.oob_memory, trap_surface.jitTrapCode(oob).?);
}

// `(module (table 1 funcref) (func (export "_start") i32.const 5 table.get 0 drop))` —
// table.get index 5 on a 1-element table is out of bounds (D-293: oob_table, code 2,
// now unified across arm64+x86_64 — x86_64 previously reported the generic bucket).
const table_get_oob_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x04, 0x04, 0x01, 0x70, 0x00, 0x01,
    0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61,
    0x72, 0x74, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07,
    0x00, 0x41, 0x05, 0x25, 0x00, 0x1a, 0x0b,
};

test "runVoidExportWasi: JIT table.get out-of-bounds → precise oob_table code 2 (D-293)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var oob: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &table_get_oob_wasm, "_start", null, &oob));
    try testing.expectEqual(@as(u32, 2), oob);
    try testing.expectEqual(trap_surface.TrapKind.oob_table, trap_surface.jitTrapCode(oob).?);
}

// `(module (type $t0 (func)) (type $t1 (func (param i32))) (table 1 funcref)
//  (func $f (type $t0)) (elem (i32.const 0) $f)
//  (func (export "_start") i32.const 0 i32.const 0 call_indirect (type $t1)))` —
// table[0] holds $f : ()->() but call_indirect expects $t1 : (i32)->(), a
// SIGNATURE mismatch (index 0 is IN bounds). D-293 slice-2: indirect_call_mismatch
// code 3, now UNIFIED across arm64+x86_64 (x86_64 previously reported the generic
// bucket — its inline sig `JNE` appended to `bounds_fixups`). Bytes generated via
// `wasm-tools parse` (name section stripped to the 66-byte module proper).
const cind_sig_mismatch_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x01,
    0x7f, 0x00, 0x03, 0x03, 0x02, 0x00, 0x00, 0x04,
    0x04, 0x01, 0x70, 0x00, 0x01, 0x07, 0x0a, 0x01,
    0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00,
    0x01, 0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b,
    0x01, 0x00, 0x0a, 0x0e, 0x02, 0x02, 0x00, 0x0b,
    0x09, 0x00, 0x41, 0x00, 0x41, 0x00, 0x11, 0x01,
    0x00, 0x0b,
};

test "runVoidExportWasi: JIT call_indirect signature mismatch → precise indirect_call_mismatch code 3 (D-293 slice-2)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    var sig: u32 = 99;
    try testing.expectError(entry.Error.Trap, runner.runVoidExportWasi(testing.allocator, &cind_sig_mismatch_wasm, "_start", null, &sig));
    try testing.expectEqual(@as(u32, 3), sig);
    try testing.expectEqual(trap_surface.TrapKind.indirect_call_mismatch, trap_surface.jitTrapCode(sig).?);
}
