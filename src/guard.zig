// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Virtual memory guard pages for JIT bounds check elimination.
//!
//! Provides mmap-based memory allocation with guard pages (PROT_NONE) after the
//! accessible region. When JIT code accesses memory beyond the valid range but
//! within the guard region, a hardware fault (SIGBUS on macOS, SIGSEGV on Linux)
//! is caught by the signal handler and converted to a Wasm OOB trap.
//!
//! This eliminates explicit compare-and-branch bounds checks in JIT code for
//! 32-bit Wasm memory accesses when offset + access_size < guard_size.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const PROT = std.c.PROT;

/// Guard region size: 4 GiB + 64 KiB.
/// This ensures any 32-bit index (0..0xFFFFFFFF) + small offset (up to 64 KiB)
/// falls within the mapped region (data + guard).
pub const GUARD_SIZE: usize = 4 * 1024 * 1024 * 1024 + 64 * 1024;

/// Total virtual reservation: data capacity + guard.
/// Data capacity matches Wasm max 4 GiB. Guard provides PROT_NONE safety zone.
pub const TOTAL_RESERVATION: usize = 8 * 1024 * 1024 * 1024 + 64 * 1024;

/// Recovery information for signal handler.
/// Set before calling JIT code, cleared after.
pub const RecoveryInfo = struct {
    /// Address of the OOB error return stub in the JIT code buffer.
    /// Signal handler sets PC to this address to convert fault → Wasm trap.
    oob_exit_pc: usize = 0,
    /// Start of the JIT code buffer (for validating faulting PC is in JIT code).
    jit_code_start: usize = 0,
    /// End of the JIT code buffer (jit_code_start + code_len).
    jit_code_end: usize = 0,
    /// Active flag: true when JIT code is executing.
    active: bool = false,
};

/// Thread-local recovery point for signal handler.
threadlocal var recovery: RecoveryInfo = .{};

/// Memory region backed by mmap with guard pages.
pub const GuardedMem = struct {
    /// Full mmap'd region (TOTAL_RESERVATION bytes).
    base: [*]align(std.heap.page_size_min) u8,
    /// Current accessible size (actual Wasm memory size).
    accessible: usize,

    /// Allocate a guarded memory region. Initially all pages are PROT_NONE.
    /// Call `makeAccessible` to enable read/write for the data portion.
    pub fn init() !GuardedMem {
        const buf = posix.mmap(
            null,
            TOTAL_RESERVATION,
            PROT.NONE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.MmapFailed;
        return .{
            .base = @alignCast(buf.ptr),
            .accessible = 0,
        };
    }

    /// Make the first `size` bytes readable and writable.
    /// Must be page-aligned (or will round up to page boundary).
    pub fn makeAccessible(self: *GuardedMem, size: usize) !void {
        if (size == 0) {
            self.accessible = 0;
            return;
        }
        if (size > TOTAL_RESERVATION - GUARD_SIZE) return error.ExceedsCapacity;
        // Round up to page boundary
        const page_size = std.heap.page_size_min;
        const aligned = (size + page_size - 1) & ~(page_size - 1);
        const region: []align(std.heap.page_size_min) u8 = @alignCast(self.base[0..aligned]);
        posix.mprotect(region, PROT.READ | PROT.WRITE) catch return error.MprotectFailed;
        self.accessible = size;
    }

    /// Grow accessible region by `delta` bytes. Returns old accessible size.
    /// New pages are zero-filled by the OS (mmap anonymous guarantee).
    pub fn grow(self: *GuardedMem, delta: usize) !usize {
        const old = self.accessible;
        const new_size = old + delta;
        if (new_size > TOTAL_RESERVATION - GUARD_SIZE) return error.ExceedsCapacity;
        // Only need to mprotect the newly added pages
        const page_size = std.heap.page_size_min;
        const old_aligned = (old + page_size - 1) & ~(page_size - 1);
        const new_aligned = (new_size + page_size - 1) & ~(page_size - 1);
        if (new_aligned > old_aligned) {
            const region: []align(std.heap.page_size_min) u8 = @alignCast(self.base[old_aligned..new_aligned]);
            posix.mprotect(region, PROT.READ | PROT.WRITE) catch return error.MprotectFailed;
        }
        self.accessible = new_size;
        return old;
    }

    /// Get a slice of the accessible region.
    pub fn slice(self: *const GuardedMem) []u8 {
        return self.base[0..self.accessible];
    }

    /// Release the entire mmap'd region.
    pub fn deinit(self: *GuardedMem) void {
        const region: []align(std.heap.page_size_min) u8 = @alignCast(self.base[0..TOTAL_RESERVATION]);
        posix.munmap(region);
        self.base = undefined;
        self.accessible = 0;
    }
};

/// Set recovery point before entering JIT code.
pub fn setRecovery(info: RecoveryInfo) void {
    recovery = info;
}

/// Clear recovery point after JIT code returns normally.
pub fn clearRecovery() void {
    recovery.active = false;
}

/// Get current recovery info (for signal handler).
pub fn getRecovery() *RecoveryInfo {
    return &recovery;
}

/// Install the signal handler for guard page faults.
/// Must be called once at startup.
pub fn installSignalHandler() void {
    const handler_fn = struct {
        fn handler(_: i32, info: *const posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
            const rec = getRecovery();
            if (!rec.active) {
                // Not in JIT code — re-raise with default handler
                resetAndReraise();
                return;
            }
            // Get faulting address
            const fault_addr = getFaultAddress(info);
            _ = fault_addr; // We trust that if we're in JIT code, the fault is from guard pages

            // Verify faulting PC is within JIT code buffer
            // Kernel may place ucontext at non-16-byte-aligned address.
            const ctx: *align(1) posix.ucontext_t = @ptrCast(ctx_ptr.?);
            const faulting_pc = getPc(ctx);
            if (faulting_pc < rec.jit_code_start or faulting_pc >= rec.jit_code_end) {
                // PC not in JIT code — not our fault
                resetAndReraise();
                return;
            }

            // Redirect execution to OOB error return
            setPc(ctx, rec.oob_exit_pc);
            // Set x0/rax to 6 (OutOfBoundsMemoryAccess error code)
            setReturnReg(ctx, 6);
            rec.active = false;
        }
    }.handler;

    const act = posix.Sigaction{
        .handler = .{ .sigaction = handler_fn },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios)
            @as(c_uint, 0x40) // SA_SIGINFO on macOS
        else
            @as(c_uint, 4), // SA_SIGINFO on Linux
    };

    // Install for SIGBUS (macOS mmap faults) and SIGSEGV (Linux mmap faults)
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
        posix.sigaction(posix.SIG.BUS, &act, null);
    } else {
        posix.sigaction(posix.SIG.SEGV, &act, null);
    }
}

fn resetAndReraise() void {
    // Reset to default handler and re-raise — this will crash as expected
    const default_act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
        posix.sigaction(posix.SIG.BUS, &default_act, null);
    } else {
        posix.sigaction(posix.SIG.SEGV, &default_act, null);
    }
}

fn getFaultAddress(info: *const posix.siginfo_t) usize {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
        return @intFromPtr(info.addr);
    } else {
        // Linux: siginfo_t.fields.sigfault.addr
        return @intFromPtr(info.fields.sigfault.addr);
    }
}

fn getPc(ctx: *align(1) posix.ucontext_t) usize {
    if (comptime builtin.cpu.arch == .aarch64) {
        if (comptime builtin.os.tag == .macos) {
            return ctx.mcontext.ss.pc;
        } else {
            return ctx.mcontext.pc;
        }
    } else if (comptime builtin.cpu.arch == .x86_64) {
        if (comptime builtin.os.tag == .macos) {
            return ctx.mcontext.ss.rip;
        } else {
            return ctx.mcontext.gregs[16]; // REG_RIP on Linux
        }
    } else {
        @compileError("unsupported arch for guard pages");
    }
}

fn setPc(ctx: *align(1) posix.ucontext_t, pc: usize) void {
    if (comptime builtin.cpu.arch == .aarch64) {
        if (comptime builtin.os.tag == .macos) {
            ctx.mcontext.ss.pc = pc;
        } else {
            ctx.mcontext.pc = pc;
        }
    } else if (comptime builtin.cpu.arch == .x86_64) {
        if (comptime builtin.os.tag == .macos) {
            ctx.mcontext.ss.rip = pc;
        } else {
            ctx.mcontext.gregs[16] = pc; // REG_RIP on Linux
        }
    }
}

fn setReturnReg(ctx: *align(1) posix.ucontext_t, value: u64) void {
    if (comptime builtin.cpu.arch == .aarch64) {
        if (comptime builtin.os.tag == .macos) {
            ctx.mcontext.ss.regs[0] = value; // x0
        } else {
            ctx.mcontext.regs[0] = value; // x0
        }
    } else if (comptime builtin.cpu.arch == .x86_64) {
        if (comptime builtin.os.tag == .macos) {
            ctx.mcontext.ss.rax = value;
        } else {
            ctx.mcontext.gregs[13] = value; // RAX on Linux
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "GuardedMem — init and deinit" {
    var gm = try GuardedMem.init();
    defer gm.deinit();

    try testing.expectEqual(@as(usize, 0), gm.accessible);
}

test "GuardedMem — make accessible and read/write" {
    var gm = try GuardedMem.init();
    defer gm.deinit();

    // Make 64 KiB accessible (one Wasm page)
    try gm.makeAccessible(64 * 1024);
    try testing.expectEqual(@as(usize, 64 * 1024), gm.accessible);

    // Write and read back
    const data = gm.slice();
    data[0] = 42;
    data[64 * 1024 - 1] = 99;
    try testing.expectEqual(@as(u8, 42), data[0]);
    try testing.expectEqual(@as(u8, 99), data[64 * 1024 - 1]);
}

test "GuardedMem — grow" {
    var gm = try GuardedMem.init();
    defer gm.deinit();

    try gm.makeAccessible(64 * 1024);
    const old = try gm.grow(64 * 1024);
    try testing.expectEqual(@as(usize, 64 * 1024), old);
    try testing.expectEqual(@as(usize, 128 * 1024), gm.accessible);

    // New region is zero-filled (OS guarantee for anonymous mmap)
    const data = gm.slice();
    try testing.expectEqual(@as(u8, 0), data[64 * 1024]);
    try testing.expectEqual(@as(u8, 0), data[128 * 1024 - 1]);
}

test "GuardedMem — slice" {
    var gm = try GuardedMem.init();
    defer gm.deinit();

    try gm.makeAccessible(4096);
    const s = gm.slice();
    try testing.expectEqual(@as(usize, 4096), s.len);
}
