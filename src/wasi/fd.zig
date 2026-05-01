//! WASI 0.1 fd_* handlers (Phase 4 / §9.4 / 4.4).
//!
//! Stdio-only first pass — fds 0 / 1 / 2. Arbitrary file fds
//! land alongside `path_open` in §9.4 / 4.5; this chunk wires
//! the dispatch shape and the gather/scatter ciovec / iovec
//! mechanics so 4.5 only adds the per-fd backing.
//!
//! Scope:
//! - `fd_write(fd, ciovec_ptr, ciovec_count, *nwritten)` — only
//!   fds 1 (stdout) and 2 (stderr) succeed; fd 0 returns `notsup`,
//!   fds 3+ return `badf` (no preopens openable yet).
//! - `fd_read(fd, iovec_ptr, iovec_count, *nread)` — only fd 0
//!   (stdin) succeeds; others return `notsup`.
//! - `fd_close(fd)` — stdio fds return `success` (noop, matches
//!   wasmtime); other valid fds flip the slot to `.closed`;
//!   out-of-range returns `badf`.
//! - `fd_seek(fd, offset, whence, *new_pos)` — stdio returns
//!   `spipe` (illegal seek on a pipe).
//! - `fd_tell(fd, *pos)` — same.
//!
//! Output for fd 1 / fd 2 routes through `host.stdout_buffer` /
//! `host.stderr_buffer` when those are set (test capture path);
//! when null, this layer treats the write as a no-op success
//! (production wiring lives in §9.4 / 4.7 / 4.8 — the binding's
//! import-resolution code installs the host's real stdout /
//! stderr writers at instance setup).
//!
//! Zone 2 (`src/wasi/`) — siblings: p1.zig, host.zig, proc.zig.

const std = @import("std");

const p1 = @import("p1.zig");
const host_mod = @import("host.zig");

const Host = host_mod.Host;

// ============================================================
// Memory access helpers (bounds-checked)
// ============================================================

fn readU32LE(mem: []const u8, offset: u32) ?u32 {
    if (@as(usize, offset) + 4 > mem.len) return null;
    return std.mem.readInt(u32, mem[offset..][0..4], .little);
}

fn writeU32LE(mem: []u8, offset: u32, value: u32) p1.Errno {
    if (@as(usize, offset) + 4 > mem.len) return .fault;
    std.mem.writeInt(u32, mem[offset..][0..4], value, .little);
    return .success;
}

// Slice into guest memory bounded by guest buf+len. Returns
// null on out-of-bounds; callers translate to `Errno.fault`.
fn sliceMem(mem: []u8, buf: u32, buf_len: u32) ?[]u8 {
    const end = @as(usize, buf) + @as(usize, buf_len);
    if (end > mem.len) return null;
    return mem[buf..end];
}

fn sliceMemConst(mem: []const u8, buf: u32, buf_len: u32) ?[]const u8 {
    const end = @as(usize, buf) + @as(usize, buf_len);
    if (end > mem.len) return null;
    return mem[buf..end];
}

// ============================================================
// fd_write
// ============================================================

/// `fd_write(fd, ciovec_ptr, ciovec_count, *nwritten_out) → errno`
/// — gather write of `ciovec_count` Ciovec entries into the host
/// fd. Each Ciovec is `{ buf: u32, buf_len: u32 }` (8 bytes,
/// little-endian) at `ciovec_ptr + i * 8`. The total bytes
/// successfully written is reported in `*nwritten_out`.
pub fn fdWrite(
    host: *Host,
    mem: []u8,
    fd: p1.Fd,
    ciovec_ptr: u32,
    ciovec_count: u32,
    nwritten_ptr: u32,
) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    if (slot.kind == .closed) return .badf;

    const buffer: ?*std.ArrayList(u8) = switch (slot.kind) {
        .stdout => host.stdout_buffer,
        .stderr => host.stderr_buffer,
        .stdin => return .notsup,
        .file, .dir => return .notsup, // §9.4 / 4.5 will wire fd-backed writes
        .closed => return .badf,
    };

    var total: u32 = 0;
    var i: u32 = 0;
    while (i < ciovec_count) : (i += 1) {
        const entry_off = ciovec_ptr + i * 8;
        const buf = readU32LE(mem, entry_off) orelse return .fault;
        const buf_len = readU32LE(mem, entry_off + 4) orelse return .fault;
        const slice = sliceMemConst(mem, buf, buf_len) orelse return .fault;
        if (buffer) |b| {
            b.appendSlice(host.alloc, slice) catch return .nomem;
        }
        total += buf_len;
    }
    return writeU32LE(mem, nwritten_ptr, total);
}

// ============================================================
// fd_read
// ============================================================

/// `fd_read(fd, iovec_ptr, iovec_count, *nread_out) → errno` —
/// scatter read into `iovec_count` Iovec entries from the host
/// fd. Stdio-only first pass: fd 0 reads from
/// `host.stdin_bytes`; advances `host.stdin_pos`. EOF (no more
/// bytes) returns success with `*nread_out = 0`.
pub fn fdRead(
    host: *Host,
    mem: []u8,
    fd: p1.Fd,
    iovec_ptr: u32,
    iovec_count: u32,
    nread_ptr: u32,
) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin => {},
        .stdout, .stderr => return .notsup,
        .file, .dir => return .notsup,
        .closed => return .badf,
    }

    var total: u32 = 0;
    var i: u32 = 0;
    while (i < iovec_count) : (i += 1) {
        const entry_off = iovec_ptr + i * 8;
        const buf = readU32LE(mem, entry_off) orelse return .fault;
        const buf_len = readU32LE(mem, entry_off + 4) orelse return .fault;
        const dst = sliceMem(mem, buf, buf_len) orelse return .fault;

        if (host.stdin_bytes) |src| {
            const remaining = src.len - host.stdin_pos;
            const n = @min(remaining, dst.len);
            if (n == 0) break;
            @memcpy(dst[0..n], src[host.stdin_pos .. host.stdin_pos + n]);
            host.stdin_pos += n;
            total += @intCast(n);
            if (n < dst.len) break; // short read; spec lets us stop
        } else {
            break; // no stdin source = EOF
        }
    }
    return writeU32LE(mem, nread_ptr, total);
}

// ============================================================
// fd_close / fd_seek / fd_tell
// ============================================================

/// `fd_close(fd) → errno`. Stdio fds return `success` (noop,
/// matches wasmtime). Other valid fds flip the slot to
/// `.closed`. Out-of-range fd: `badf`.
pub fn fdClose(host: *Host, fd: p1.Fd) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    switch (slot.kind) {
        .stdin, .stdout, .stderr => return .success,
        .closed => return .badf,
        .file, .dir => {
            slot.kind = .closed;
            return .success;
        },
    }
}

/// `fd_seek(fd, offset, whence, *new_pos_out) → errno`. Stdio
/// fds (and pipes more generally) cannot seek — return `spipe`.
/// Non-stdio fds: TODO(4.5) actual seek; return `notsup` for
/// now.
pub fn fdSeek(
    host: *Host,
    mem: []u8,
    fd: p1.Fd,
    offset: i64,
    whence: u8,
    new_pos_ptr: u32,
) p1.Errno {
    _ = offset;
    _ = whence;
    _ = mem;
    _ = new_pos_ptr;
    const slot = host.translateFd(fd) orelse return .badf;
    return switch (slot.kind) {
        .stdin, .stdout, .stderr => .spipe,
        .closed => .badf,
        .file, .dir => .notsup,
    };
}

/// `fd_tell(fd, *pos_out) → errno`. Same shape as `fd_seek`
/// — stdio cannot tell, returns `spipe`.
pub fn fdTell(host: *Host, mem: []u8, fd: p1.Fd, pos_ptr: u32) p1.Errno {
    _ = mem;
    _ = pos_ptr;
    const slot = host.translateFd(fd) orelse return .badf;
    return switch (slot.kind) {
        .stdin, .stdout, .stderr => .spipe,
        .closed => .badf,
        .file, .dir => .notsup,
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "fdWrite: stdout capture buffer accumulates writes" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    h.stdout_buffer = &capture;

    // Memory layout: ciovec at offset 0 (8 bytes); string at 8.
    var mem: [32]u8 = @splat(0);
    std.mem.writeInt(u32, mem[0..4], 8, .little); // buf = 8
    std.mem.writeInt(u32, mem[4..8], 3, .little); // buf_len = 3
    @memcpy(mem[8..11], "hi\n");

    const n_off: u32 = 16;
    const e = fdWrite(&h, &mem, 1, 0, 1, n_off);
    try testing.expectEqual(p1.Errno.success, e);

    try testing.expectEqualStrings("hi\n", capture.items);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, mem[16..20], .little));
}

test "fdWrite: gather write across multiple ciovecs" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    h.stdout_buffer = &capture;

    // Two ciovecs: (16, 5) "hello" + (24, 1) "\n"
    var mem: [64]u8 = @splat(0);
    std.mem.writeInt(u32, mem[0..4], 16, .little);
    std.mem.writeInt(u32, mem[4..8], 5, .little);
    std.mem.writeInt(u32, mem[8..12], 24, .little);
    std.mem.writeInt(u32, mem[12..16], 1, .little);
    @memcpy(mem[16..21], "hello");
    mem[24] = '\n';

    const nwritten: u32 = 32;
    const e = fdWrite(&h, &mem, 1, 0, 2, nwritten);
    try testing.expectEqual(p1.Errno.success, e);
    try testing.expectEqualStrings("hello\n", capture.items);
    try testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, mem[32..36], .little));
}

test "fdWrite: stdin (fd=0) returns notsup" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    const e = fdWrite(&h, &mem, 0, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notsup, e);
}

test "fdWrite: out-of-range fd returns badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    const e = fdWrite(&h, &mem, 99, 0, 0, 0);
    try testing.expectEqual(p1.Errno.badf, e);
}

test "fdWrite: out-of-bounds ciovec buf returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    // ciovec at 0: buf=200 (way past mem.len=16), buf_len=4.
    std.mem.writeInt(u32, mem[0..4], 200, .little);
    std.mem.writeInt(u32, mem[4..8], 4, .little);
    const e = fdWrite(&h, &mem, 1, 0, 1, 8);
    try testing.expectEqual(p1.Errno.fault, e);
}

test "fdRead: stdin reads from host.stdin_bytes; EOF returns nread=0" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.stdin_bytes = "abc";

    var mem: [16]u8 = @splat(0);
    std.mem.writeInt(u32, mem[0..4], 8, .little); // iovec.buf = 8
    std.mem.writeInt(u32, mem[4..8], 4, .little); // iovec.buf_len = 4

    const e1 = fdRead(&h, &mem, 0, 0, 1, 12);
    try testing.expectEqual(p1.Errno.success, e1);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, mem[12..16], .little));
    try testing.expectEqualStrings("abc", mem[8..11]);
    try testing.expectEqual(@as(usize, 3), h.stdin_pos);

    // Second read: EOF.
    @memset(&mem, 0);
    std.mem.writeInt(u32, mem[0..4], 8, .little);
    std.mem.writeInt(u32, mem[4..8], 4, .little);
    const e2 = fdRead(&h, &mem, 0, 0, 1, 12);
    try testing.expectEqual(p1.Errno.success, e2);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, mem[12..16], .little));
}

test "fdRead: stdout (fd=1) returns notsup" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [16]u8 = @splat(0);
    const e = fdRead(&h, &mem, 1, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notsup, e);
}

test "fdClose: stdio = success-noop; out-of-range = badf" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    try testing.expectEqual(p1.Errno.success, fdClose(&h, 0));
    try testing.expectEqual(p1.Errno.success, fdClose(&h, 1));
    try testing.expectEqual(p1.Errno.success, fdClose(&h, 2));
    // Stdio still resolvable post-close.
    try testing.expect(h.translateFd(1) != null);
    try testing.expectEqual(p1.Errno.badf, fdClose(&h, 99));
}

test "fdSeek / fdTell: stdio returns spipe" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [8]u8 = @splat(0);
    try testing.expectEqual(p1.Errno.spipe, fdSeek(&h, &mem, 1, 0, 0, 0));
    try testing.expectEqual(p1.Errno.spipe, fdTell(&h, &mem, 0, 0));
}
