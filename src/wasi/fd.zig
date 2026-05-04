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

const p1 = @import("preview1.zig");
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
// fd_fdstat_get / fd_fdstat_set_flags  (§9.4 / 4.5 chunk a)
// ============================================================

fn filetypeFor(kind: host_mod.FdKind) p1.Filetype {
    return switch (kind) {
        .stdin, .stdout, .stderr => .character_device,
        .file => .regular_file,
        .dir => .directory,
        .closed => .unknown,
    };
}

/// `fd_fdstat_get(fd, *fdstat_out) → errno` — write the
/// 24-byte `Fdstat` block. Layout per witx:
///   offset 0  : u8  filetype
///   offset 1  : u8  reserved (zero)
///   offset 2  : u16 fs_flags  (little-endian)
///   offset 4  : u32 reserved (zero)
///   offset 8  : u64 fs_rights_base  (little-endian)
///   offset 16 : u64 fs_rights_inheriting (little-endian)
pub fn fdFdstatGet(
    host: *const Host,
    mem: []u8,
    fd: p1.Fd,
    fdstat_ptr: u32,
) p1.Errno {
    if (@as(usize, fdstat_ptr) + 24 > mem.len) return .fault;
    if (fd >= host.fd_table.items.len) return .badf;
    const slot = &host.fd_table.items[fd];
    if (slot.kind == .closed) return .badf;

    const dst = mem[fdstat_ptr..][0..24];
    @memset(dst, 0);
    dst[0] = @intFromEnum(filetypeFor(slot.kind));
    std.mem.writeInt(u16, dst[2..4], slot.fs_flags, .little);
    std.mem.writeInt(u64, dst[8..16], slot.rights_base, .little);
    std.mem.writeInt(u64, dst[16..24], slot.rights_inheriting, .little);
    return .success;
}

/// `fd_fdstat_set_flags(fd, flags) → errno` — replace the
/// writable-subset flags on the slot. Only the flag bits the
/// witx schema allows on update are persisted (APPEND / DSYNC
/// / NONBLOCK / RSYNC / SYNC); other bits are silently
/// ignored, matching wasmtime.
pub fn fdFdstatSetFlags(host: *Host, fd: p1.Fd, flags: p1.Fdflags) p1.Errno {
    const slot = host.translateFd(fd) orelse return .badf;
    if (slot.kind == .closed) return .badf;
    const allowed: p1.Fdflags = p1.FDFLAGS_APPEND | p1.FDFLAGS_DSYNC |
        p1.FDFLAGS_NONBLOCK | p1.FDFLAGS_RSYNC | p1.FDFLAGS_SYNC;
    slot.fs_flags = flags & allowed;
    return .success;
}

// ============================================================
// path_open  (§9.4 / 4.5 chunk b)
// ============================================================

fn pathHasParentEscape(path: []const u8) bool {
    if (path.len > 0 and path[0] == '/') return true;
    var iter = std.mem.tokenizeScalar(u8, path, '/');
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

fn mapOpenError(err: anyerror) p1.Errno {
    return switch (err) {
        error.FileNotFound => .noent,
        error.AccessDenied => .acces,
        error.IsDir => .isdir,
        error.NotDir => .notdir,
        error.SymLinkLoop => .loop,
        error.NameTooLong => .nametoolong,
        error.PathAlreadyExists => .exist,
        error.NoSpaceLeft => .nospc,
        error.SystemResources, error.SystemFdQuotaExceeded, error.ProcessFdQuotaExceeded => .nfile,
        else => .io,
    };
}

/// `path_open(dirfd, dirflags, path, oflags, rights_base,
/// rights_inheriting, fdflags, *opened_fd_out) → errno` —
/// opens a path RELATIVE to a preopen `dirfd`. Strict scope:
///
/// - `dirfd` must resolve to an `OpenFd` of kind `.dir`
///   (preopens are the only roots) → `notdir` otherwise.
/// - The path string spans `mem[path_ptr .. path_ptr +
///   path_len]`. Out-of-bounds → `fault`.
/// - Path must be relative and contain no `..` segments —
///   absolute paths or any traversal escape returns
///   `notcapable`. The kernel-side `openat` would also block
///   most escapes, but the explicit pre-check is part of the
///   WASI security contract.
/// - Open is delegated to `std.Io.Dir{.fd = slot.host_handle}
///   .openFile(io, ...)`. Errors map through `mapOpenError`.
///
/// On success, a new `.file` slot is appended to
/// `host.fd_table`; the new guest fd is written to
/// `opened_fd_ptr`. The `oflags` / `dirflags` parameters are
/// accepted but only the bare-open path is honoured for now —
/// CREAT / EXCL / TRUNC come alongside their consuming
/// realworld samples.
pub fn pathOpen(
    host: *Host,
    mem: []u8,
    dirfd: p1.Fd,
    dirflags: u32,
    path_ptr: u32,
    path_len: u32,
    oflags: p1.Oflags,
    fs_rights_base: p1.Rights,
    fs_rights_inheriting: p1.Rights,
    fdflags: p1.Fdflags,
    opened_fd_ptr: u32,
) p1.Errno {
    _ = dirflags;
    _ = oflags;

    // Bounds-check the path slice.
    const path_end = @as(usize, path_ptr) + @as(usize, path_len);
    if (path_end > mem.len) return .fault;
    const path = mem[path_ptr..path_end];
    if (pathHasParentEscape(path)) return .notcapable;

    // Resolve dirfd.
    const dir_slot = host.translateFd(dirfd) orelse return .badf;
    if (dir_slot.kind != .dir) return .notdir;
    const dir_handle = dir_slot.host_handle orelse return .notdir;

    // Filesystem syscalls require an io context; tests / production
    // callers must thread one onto the Host before calling.
    const io = host.io orelse return .nosys;

    const dir: std.Io.Dir = .{ .handle = dir_handle };
    const file = dir.openFile(io, path, .{}) catch |err| return mapOpenError(err);

    // Reserve the new fd_table slot.
    host.fd_table.append(host.alloc, .{
        .kind = .file,
        .rights_base = fs_rights_base,
        .rights_inheriting = fs_rights_inheriting,
        .fs_flags = fdflags,
        .host_handle = file.handle,
    }) catch {
        file.close(io);
        return .nomem;
    };
    const new_fd: p1.Fd = @intCast(host.fd_table.items.len - 1);

    return writeU32LE(mem, opened_fd_ptr, new_fd);
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

test "fdFdstatGet: stdout writes 24-byte block (character_device, RIGHTS_FD_WRITE)" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [32]u8 = @splat(0xAB);
    const e = fdFdstatGet(&h, &mem, 1, 0);
    try testing.expectEqual(p1.Errno.success, e);
    // filetype = character_device (2)
    try testing.expectEqual(@as(u8, @intFromEnum(p1.Filetype.character_device)), mem[0]);
    // reserved byte zeroed
    try testing.expectEqual(@as(u8, 0), mem[1]);
    // fs_flags = 0
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, mem[2..4], .little));
    // rights_base = RIGHTS_FD_WRITE (default for fd 1)
    try testing.expectEqual(p1.RIGHTS_FD_WRITE, std.mem.readInt(u64, mem[8..16], .little));
    // rights_inheriting = 0
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, mem[16..24], .little));
    // The 25th byte should be untouched.
    try testing.expectEqual(@as(u8, 0xAB), mem[24]);
}

test "fdFdstatGet: out-of-range fd returns badf; out-of-bounds ptr returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [32]u8 = @splat(0);
    try testing.expectEqual(p1.Errno.badf, fdFdstatGet(&h, &mem, 99, 0));
    try testing.expectEqual(p1.Errno.fault, fdFdstatGet(&h, &mem, 1, 100));
}

test "pathOpen: rejects parent-escape and absolute paths with notcapable" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    const fake_fd: std.posix.fd_t = undefined;
    const dirfd = try h.addPreopen(fake_fd, "/sandbox");

    // "../escape"
    var mem: [64]u8 = @splat(0);
    @memcpy(mem[16..25], "../escape");
    const e1 = pathOpen(&h, &mem, dirfd, 0, 16, 9, 0, p1.RIGHTS_FD_READ, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notcapable, e1);

    // "/etc/passwd"
    @memset(&mem, 0);
    @memcpy(mem[16..27], "/etc/passwd");
    const e2 = pathOpen(&h, &mem, dirfd, 0, 16, 11, 0, p1.RIGHTS_FD_READ, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notcapable, e2);
}

test "pathOpen: returns notdir when dirfd is not a preopen" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    var mem: [64]u8 = @splat(0);
    @memcpy(mem[16..23], "foo.txt");
    // fd 1 = stdout (not a .dir).
    const e = pathOpen(&h, &mem, 1, 0, 16, 7, 0, p1.RIGHTS_FD_READ, 0, 0, 0);
    try testing.expectEqual(p1.Errno.notdir, e);
}

test "pathOpen: out-of-bounds path slice returns fault" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    const fake_fd: std.posix.fd_t = undefined;
    const dirfd = try h.addPreopen(fake_fd, "/sandbox");
    var mem: [16]u8 = @splat(0);
    // path_ptr=10, path_len=20 → end=30 past mem.len=16.
    const e = pathOpen(&h, &mem, dirfd, 0, 10, 20, 0, p1.RIGHTS_FD_READ, 0, 0, 0);
    try testing.expectEqual(p1.Errno.fault, e);
}

test "pathOpen: happy path opens an existing file inside a real preopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.txt", .data = "Hi" });

    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [64]u8 = @splat(0);
    @memcpy(mem[16..25], "hello.txt");
    const e = pathOpen(&h, &mem, dirfd, 0, 16, 9, 0, p1.RIGHTS_FD_READ, 0, 0, 32);
    try testing.expectEqual(p1.Errno.success, e);

    const new_fd = std.mem.readInt(u32, mem[32..36], .little);
    // fd table starts at 3 stdio + 1 preopen = 4 entries; new fd
    // is appended at index 4.
    try testing.expectEqual(@as(u32, 4), new_fd);

    const slot = h.translateFd(new_fd) orelse return error.MissingFile;
    try testing.expectEqual(host_mod.FdKind.file, slot.kind);
    // Close the host file via std.Io.File. The flags field is
    // not load-bearing for close (the close vtable just looks
    // at the handle), so the default `.nonblocking = false`
    // suffices. Production cleanup will route through
    // `fd_close` once that's wired with `io`.
    const file: std.Io.File = .{ .handle = slot.host_handle.?, .flags = .{ .nonblocking = false } };
    file.close(testing.io);
    slot.kind = .closed;
}

test "fdFdstatSetFlags: persists allowed bits + masks unknown ones" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    // Set NONBLOCK | APPEND | (some unknown high bit).
    const requested: p1.Fdflags = p1.FDFLAGS_NONBLOCK | p1.FDFLAGS_APPEND | 0x8000;
    const e = fdFdstatSetFlags(&h, 1, requested);
    try testing.expectEqual(p1.Errno.success, e);
    const slot = h.translateFd(1).?;
    try testing.expectEqual(@as(p1.Fdflags, p1.FDFLAGS_NONBLOCK | p1.FDFLAGS_APPEND), slot.fs_flags);

    // Round-trip: fdstat_get reflects the new flags.
    var mem: [32]u8 = @splat(0);
    _ = fdFdstatGet(&h, &mem, 1, 0);
    try testing.expectEqual(
        @as(u16, p1.FDFLAGS_NONBLOCK | p1.FDFLAGS_APPEND),
        std.mem.readInt(u16, mem[2..4], .little),
    );
}
