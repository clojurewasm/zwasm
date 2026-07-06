//! ADR-0202 D2 isolation proof: a guard-region fault raised INSIDE
//! JIT-executable code is converted — by the production handler +
//! trap registry alone — into a PC-redirect to the registered stub,
//! and execution RESUMES there. Exercised BEFORE any bounds check is
//! elided (ADR-0202 implementation-order step 2), so the redirect
//! path is proven in isolation from the emitter.
//!
//! Shape: hand-emit `f(ptr) = load [ptr]; ret` plus a stub at a known
//! offset that returns the sentinel 6 (the oob_memory wire code).
//! Register the code region + a guarded reservation, then — in a
//! forked child, so the process-wide sigaction swap and the deliberate
//! fault cannot perturb the surrounding test harness — install the
//! production handler and call `f(guard_addr)`. The load faults, the
//! handler classifies + rewrites the PC to the stub, the stub returns
//! 6, and the child `_exit`s with it. fork/waitpid/_exit = ADR-0070
//! necessary (test-only), mirroring `signal.zig`'s fork test.
//!
//! Windows: fork is unavailable; the Rip-rewrite mechanism itself is
//! ADR-0103-proven (`windows_traphandler.zig`), and the VEH classify
//! branch is exercised end-to-end by the phase-3 oob corpus on the
//! windowsmini CI leg (ADR-0202 verification note).
//!
//! Zone 0 (`src/platform/`).

const std = @import("std");
const builtin = @import("builtin");
const jit_mem = @import("jit_mem.zig");
const guarded_mem = @import("guarded_mem.zig");
const trap_registry = @import("trap_registry.zig");
const signal = @import("signal.zig");

const testing = std.testing;

const enabled = guarded_mem.supported and
    builtin.os.tag != .windows and
    (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64);

test "fault_redirect: guard fault in JIT code resumes at the registered oob stub" {
    if (comptime !enabled) return; // comptime platform prune (ADR-0122 D3) — POSIX fork + supported JIT arch; Win64 via phase-3 corpus (ADR-0202)

    // f: load [arg0]; ret        stub: return 6
    var block = try jit_mem.alloc(4096); // jit_mem rounds to its own page size
    defer jit_mem.free(block);
    try jit_mem.setWritable(block);
    var stub_off: u32 = 0;
    switch (comptime builtin.cpu.arch) {
        .aarch64 => {
            // LDR W0,[X0] ; RET   | stub: MOVZ W0,#6 ; RET  (ARM ARM C6)
            const code = [_]u32{ 0xB9400000, 0xD65F03C0, 0x528000C0, 0xD65F03C0 };
            stub_off = 8;
            for (code, 0..) |inst, i| {
                std.mem.writeInt(u32, block.bytes[i * 4 ..][0..4], inst, .little);
            }
        },
        .x86_64 => {
            // mov eax,[rdi] ; ret | stub: mov eax,6 ; ret  (Intel SDM Vol 2)
            const code = [_]u8{ 0x8B, 0x07, 0xC3, 0xB8, 0x06, 0x00, 0x00, 0x00, 0xC3 };
            stub_off = 3;
            @memcpy(block.bytes[0..code.len], &code);
        },
        else => @compileError("unsupported arch"),
    }
    try jit_mem.setExecutable(block);

    const funcs = [_]trap_registry.FuncEntry{
        .{ .code_off = 0, .oob_stub_off = stub_off },
    };
    const code_start = @intFromPtr(block.bytes.ptr);
    try trap_registry.registerCodeRegion(code_start, code_start + block.bytes.len, &funcs);
    defer trap_registry.unregisterCodeRegion(code_start);

    var r = try guarded_mem.reserve(1 << 20); // auto-registers the guarded range
    defer guarded_mem.release(r);
    try guarded_mem.commit(&r, guarded_mem.page_size);
    const guard_addr = @intFromPtr(r.base) + r.committed; // first guard byte

    const pid = std.c.fork();
    try testing.expect(pid != -1);
    if (pid == 0) {
        signal.installInternalFaultHandler();
        const F = *const fn (usize) callconv(.c) u32;
        const f = block.asFnPtr(F);
        const ret = f(guard_addr); // faults → handler redirects PC → stub returns 6
        std.c._exit(@intCast(ret & 0xff));
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    try testing.expect(std.posix.W.IFEXITED(ustatus));
    try testing.expectEqual(@as(u32, 6), std.posix.W.EXITSTATUS(ustatus));
}

test "fault_redirect: an UNREGISTERED fault still takes the diagnostic exit (ADR-0166 preserved)" {
    if (comptime !enabled) return; // comptime platform prune (ADR-0122 D3) — POSIX fork; see test above

    const pid = std.c.fork();
    try testing.expect(pid != -1);
    if (pid == 0) {
        signal.installInternalFaultHandler();
        const p: *allowzero volatile u8 = @ptrFromInt(0); // null page: neither guarded nor JIT pc
        p.* = 0;
        std.c._exit(1); // unreachable — the diagnostic handler _exits(70)
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const ustatus: u32 = @bitCast(status);
    try testing.expect(std.posix.W.IFEXITED(ustatus));
    try testing.expectEqual(@as(u32, signal.INTERNAL_ERROR_EXIT_CODE), std.posix.W.EXITSTATUS(ustatus));
}
