//! D-245 RESULT-path regression probe (§15.5 / chunk 1).
//!
//! Companion to `scripts/check_jit_releasesafe.sh`, which only drives the
//! no-arg VOID path (`runVoidExport`). This probe drives the i32 RESULT path
//! (`runner.runI32Export` → `entry.invokeAndCheck`), which has its own
//! host→JIT seam: the JIT prologue MOV-installs the pinned callee-saved
//! cohort (arm64 X19/X24-X28; x86_64 RBX/R12-R15) from `rt` WITHOUT
//! stack-saving the caller's values, so a plain `@call` clobbers the host's
//! live callee-saved registers. In ReleaseSafe the optimized host keeps live
//! values there → heap-corruption SEGV; Debug keeps nothing live → no crash.
//!
//! To make the clobber observable, the probe ALLOCATES a slice and HOLDS it
//! live across the `runI32Export` call (mirroring how `runVoidExport`'s caller
//! SEGV'd in `compiled.deinit` after the call corrupted the heap-pointer it
//! kept in a callee-saved register). We touch the slice both before and after
//! the call; if the call clobbered the register holding the slice base, the
//! post-call free / readback corrupts the heap → SEGV / abort.
//!
//! Built ONLY via `zig build jit-result-probe-releasesafe`, which pins both
//! this module AND a fresh `core` module to `-OReleaseSafe` regardless of the
//! ambient `-Doptimize` (an exe's optimize does NOT propagate to an imported
//! pre-built `core`, so a normal run-artifact can't isolate ReleaseSafe).

const std = @import("std");
const zwasm = @import("zwasm");
const runner = zwasm.engine.runner;

// `(module (memory 1) (func (export "f") (result i32)
//    (i32.store (i32.const 0) (i32.const 42)) (i32.load (i32.const 0))))`
//
// The memory access is load-bearing: it makes the JIT body `uses_runtime_ptr`,
// so the prologue MOV-installs the pinned callee-saved cohort from `rt`. A
// bare `(i32.const 42)` body does NOT touch the runtime pointer → the prologue
// installs nothing → no clobber → the bug would NOT reproduce. Storing/loading
// `42` keeps the asserted result while forcing the vulnerable prologue.
const wasm_f_42 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01, //                    memory: min 1
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
    0x0a, 0x10, 0x01, 0x0e, 0x00, //                    code
    0x41, 0x00, 0x41, 0x2a, 0x36, 0x02, 0x00, //        i32.store (0) 42
    0x41, 0x00, 0x28, 0x02, 0x00, //                    i32.load (0)
    0x0b,
};

/// Hold a cohort's-worth of independent live pointers across the JIT call so
/// ReleaseSafe is forced to keep some of them in the callee-saved registers
/// the JIT prologue clobbers (arm64 X19/X24-X28; x86_64 RBX/R12-R15). Each
/// pointer is dereferenced BOTH before and after the call, and the result
/// feeds back into the assertion, so the optimizer cannot sink/hoist them out
/// of the live range. `.never_inline` gives this frame its own register
/// allocation around the call (mirrors the real embedder seam where the host
/// caller's frame straddles the JIT call).
fn probeOnce(alloc: std.mem.Allocator) !void {
    // Eight independent allocations — more than the cohort width on either
    // arch, maximizing the chance the allocator pins live bases in clobbered
    // regs across the call (this is what SEGV'd `compiled.deinit` on the void
    // path: a live heap pointer survived in a callee-saved reg).
    var slots: [8][]u64 = undefined;
    inline for (&slots, 0..) |*s, k| {
        s.* = try alloc.alloc(u64, 16);
        for (s.*, 0..) |*v, i| v.* = (0xA5A5_0000_0000_0000 | (@as(u64, k) << 32)) | @as(u64, i);
    }
    defer inline for (slots) |s| alloc.free(s);

    // Pre-call read to anchor the live range BEFORE the call.
    var pre: u64 = 0;
    inline for (slots) |s| pre +%= s[0] +% s[15];
    std.mem.doNotOptimizeAway(pre);

    const result = try runner.runI32Export(alloc, &wasm_f_42, "f");

    // Post-call: re-read every slot. If the call clobbered a callee-saved reg
    // holding one of these slice bases, this read hits corrupted heap state →
    // SEGV / allocator abort under ReleaseSafe.
    inline for (&slots, 0..) |*s, k| {
        for (s.*, 0..) |v, i| {
            const want = (0xA5A5_0000_0000_0000 | (@as(u64, k) << 32)) | @as(u64, i);
            if (v != want) {
                std.debug.print("[probe] slot[{d}][{d}] corrupted: {x} != {x}\n", .{ k, i, v, want });
                return error.SentinelCorrupted;
            }
        }
    }
    std.mem.doNotOptimizeAway(pre);

    if (result != 42) {
        std.debug.print("[probe] FAIL: runI32Export returned {d}, expected 42\n", .{result});
        return error.WrongResult;
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Repeat to reshuffle the heap and re-roll register allocation; the
    // clobber is deterministic per-codegen, but extra iterations harden
    // against an incidentally-safe allocation layout on one run.
    var n: u32 = 0;
    while (n < 64) : (n += 1) {
        try @call(.never_inline, probeOnce, .{alloc});
    }
    std.debug.print("[probe] OK: runI32Export == 42, sentinels intact x64 (D-245 result path)\n", .{});
}
