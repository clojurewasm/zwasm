//! JIT executable-memory primitives (sub-7.4a).
//!
//! Allocates a page-aligned region that JIT-emitted bytes are
//! written to, then flips its protection so the CPU can execute
//! the bytes. macOS aarch64 with hardened runtime requires the
//! MAP_JIT pattern + per-thread W^X toggle (`pthread_jit_write_
//! protect_np`) + I-cache invalidation; Linux + Windows variants
//! are not yet wired (the §9.7 / 7.4 gate exercises this only on
//! Mac aarch64; Linux x86_64 / Windows x86_64 hosts surface
//! `NotImplemented` and the test gates skip the JIT spec gate
//! there until Phase 8 / x86_64 emit lands).
//!
//! Zone 0 (`src/platform/`) — depends only on Zig stdlib.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    /// Page allocation failed (mmap / VirtualAlloc).
    AllocationFailed,
    /// Write→execute protection flip failed.
    ProtectionFailed,
    /// Host platform doesn't yet have a JIT-mem implementation.
    NotImplemented,
};

const page_size: usize = 16 * 1024; // macOS aarch64 default

/// A page-aligned RWX region holding JIT-emitted bytes. Lifetime
/// owned by the caller; pair `alloc` with `free`.
pub const JitBlock = struct {
    bytes: []align(page_size) u8,

    /// Cast the block's start to a function pointer of type `Fn`.
    /// Caller is responsible for matching the actual emitted
    /// signature; mismatch produces undefined behaviour.
    pub fn asFnPtr(self: JitBlock, comptime Fn: type) Fn {
        return @ptrCast(@alignCast(self.bytes.ptr));
    }
};

/// Allocate `size` bytes of JIT-capable RX memory, initially
/// writable on the current thread. Caller writes bytes into
/// `block.bytes`, then calls `setExecutable(block)` to publish.
pub fn alloc(size: usize) Error!JitBlock {
    if (size == 0) return Error.AllocationFailed;
    const rounded = (size + page_size - 1) & ~(page_size - 1);

    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) {
        const prot: std.c.vm_prot_t = .{ .READ = true, .WRITE = true, .EXEC = true };
        const flags: std.c.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true };
        const ptr = std.c.mmap(null, rounded, prot, flags, -1, 0);
        if (ptr == std.c.MAP_FAILED) return Error.AllocationFailed;
        const aligned: [*]align(page_size) u8 = @ptrCast(@alignCast(ptr));
        // MAP_JIT pages start in the W mode for the current thread
        // (per-thread W^X). Caller writes; setExecutable flips.
        return .{ .bytes = aligned[0..rounded] };
    }

    return Error.NotImplemented;
}

/// Free a block previously returned by `alloc`.
pub fn free(block: JitBlock) void {
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) {
        _ = std.c.munmap(@ptrCast(block.bytes.ptr), block.bytes.len);
        return;
    }
}

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: ?*anyopaque, len: usize) void;

/// Flip `block` from writable to executable for the current
/// thread + invalidate the I-cache so freshly-written bytes are
/// visible to the CPU's instruction fetch.
pub fn setExecutable(block: JitBlock) Error!void {
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) {
        pthread_jit_write_protect_np(1); // 1 = re-enable W^X (RX)
        sys_icache_invalidate(@ptrCast(block.bytes.ptr), block.bytes.len);
        return;
    }
    return Error.NotImplemented;
}

/// Flip `block` back to writable for the current thread, e.g. to
/// patch `call_fixups` after initial publish. Pair with
/// `setExecutable`.
pub fn setWritable(block: JitBlock) Error!void {
    _ = block;
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) {
        pthread_jit_write_protect_np(0); // 0 = disable W^X (RW)
        return;
    }
    return Error.NotImplemented;
}

const testing = std.testing;

test "JitBlock: emit MOVZ X0,#42 + RET, execute, returns 42" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        // Other hosts: the JIT spec gate is not yet wired; skip.
        return error.SkipZigTest;
    }
    const inst = @import("../engine/codegen/arm64/inst.zig");
    var block = try alloc(page_size);
    defer free(block);
    // The block starts writable (MAP_JIT + thread W^X disabled).
    // To be sure we're in W mode for this thread, request it:
    try setWritable(block);
    std.mem.writeInt(u32, block.bytes[0..4], inst.encMovzImm16(0, 42), .little);
    std.mem.writeInt(u32, block.bytes[4..8], inst.encRet(30), .little);

    try setExecutable(block);
    const Fn = *const fn () callconv(.c) u32;
    const f = block.asFnPtr(Fn);
    try testing.expectEqual(@as(u32, 42), f());
}

test "JitBlock: alloc(0) returns AllocationFailed" {
    try testing.expectError(Error.AllocationFailed, alloc(0));
}
