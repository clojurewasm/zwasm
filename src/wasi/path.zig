//! WASI 0.1 `path_*` handlers (D-278): filesystem operations relative to a
//! preopen `.dir` fd. Each resolves the dirfd + bounds-checks the guest path
//! + rejects `..`-escape (the WASI sandbox contract, mirroring `fd.zig`'s
//! `pathOpen` front-half), then delegates to the cross-platform `std.Io.Dir`
//! API (NOT `std.posix.*` — those hardcode POSIX `c_int` fds and break Win64;
//! see lesson windowsmini-reconciliation).
//!
//! Zone 2 (`src/wasi/`) — siblings: p1.zig / host.zig / fd.zig / clocks.zig.

const std = @import("std");

const p1 = @import("preview1.zig");
const host_mod = @import("host.zig");

const Host = host_mod.Host;

// ============================================================
// Shared resolution + error mapping
// ============================================================

fn sliceMemConst(mem: []const u8, ptr: u32, len: u32) ?[]const u8 {
    const end = @as(usize, ptr) + @as(usize, len);
    if (end > mem.len) return null;
    return mem[ptr..end];
}

/// A guest path is sandboxed to its preopen root: absolute paths and any `..`
/// segment escape the root and are rejected with `notcapable`.
fn pathHasParentEscape(path: []const u8) bool {
    if (path.len > 0 and path[0] == '/') return true;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

const Resolved = struct { dir: std.Io.Dir, sub: []const u8 };

/// Resolve `(dirfd, path_ptr, path_len)` to a host `Dir` + bounded guest path.
/// Returns the errno on failure (`.success` when `out` is populated).
fn resolve(host: *Host, mem: []const u8, dirfd: p1.Fd, path_ptr: u32, path_len: u32, out: *Resolved) p1.Errno {
    const path = sliceMemConst(mem, path_ptr, path_len) orelse return .fault;
    if (pathHasParentEscape(path)) return .notcapable;
    const slot = host.translateFd(dirfd) orelse return .badf;
    if (slot.kind != .dir) return .notdir;
    const handle = slot.host_handle orelse return .notdir;
    out.* = .{ .dir = .{ .handle = handle }, .sub = path };
    return .success;
}

/// Map a `std.Io.Dir`/`File` filesystem error to a WASI errno. The arms cover
/// the union of the create/delete/rename/link/readlink/stat error sets.
fn mapDirErr(err: anyerror) p1.Errno {
    return switch (err) {
        error.FileNotFound => .noent,
        error.PathAlreadyExists => .exist,
        error.AccessDenied, error.PermissionDenied => .acces,
        error.NotDir => .notdir,
        error.IsDir => .isdir,
        error.DirNotEmpty => .notempty,
        error.SymLinkLoop => .loop,
        error.NotLink => .inval,
        error.NameTooLong => .nametoolong,
        error.NoSpaceLeft => .nospc,
        error.ReadOnlyFileSystem => .rofs,
        error.FileBusy => .busy,
        error.RenameAcrossMountPoints => .xdev,
        else => .io,
    };
}

// ============================================================
// path_create_directory / path_remove_directory
// ============================================================

/// `path_create_directory(dirfd, path) → errno` — create a directory relative
/// to the preopen `dirfd` (`std.Io.Dir.createDir`).
pub fn pathCreateDirectory(host: *Host, mem: []const u8, dirfd: p1.Fd, path_ptr: u32, path_len: u32) p1.Errno {
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    r.dir.createDir(io, r.sub, std.Io.File.Permissions.default_dir) catch |err| return mapDirErr(err);
    return .success;
}

/// `path_remove_directory(dirfd, path) → errno` — remove an empty directory
/// relative to `dirfd` (`std.Io.Dir.deleteDir`; non-empty → `notempty`).
pub fn pathRemoveDirectory(host: *Host, mem: []const u8, dirfd: p1.Fd, path_ptr: u32, path_len: u32) p1.Errno {
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    r.dir.deleteDir(io, r.sub) catch |err| return mapDirErr(err);
    return .success;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn writeGuestPath(mem: []u8, off: usize, name: []const u8) void {
    @memcpy(mem[off .. off + name.len], name);
}

test "pathCreateDirectory / pathRemoveDirectory: round-trip on a real preopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [64]u8 = @splat(0);
    writeGuestPath(&mem, 0, "newdir");
    try testing.expectEqual(p1.Errno.success, pathCreateDirectory(&h, &mem, dirfd, 0, 6));
    // The directory now exists on the host.
    const st = tmp.dir.statFile(testing.io, "newdir", .{}) catch return error.DirNotCreated;
    try testing.expectEqual(std.Io.File.Kind.directory, st.kind);

    try testing.expectEqual(p1.Errno.success, pathRemoveDirectory(&h, &mem, dirfd, 0, 6));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "newdir", .{}));
}

test "path_* resolution: escape / non-dir / out-of-bounds rejections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [64]u8 = @splat(0);
    writeGuestPath(&mem, 0, "../escape");
    try testing.expectEqual(p1.Errno.notcapable, pathCreateDirectory(&h, &mem, dirfd, 0, 9));
    // Non-preopen dirfd (stdout) → notdir.
    writeGuestPath(&mem, 0, "x");
    try testing.expectEqual(p1.Errno.notdir, pathCreateDirectory(&h, &mem, 1, 0, 1));
    // Out-of-bounds path slice → fault.
    try testing.expectEqual(p1.Errno.fault, pathRemoveDirectory(&h, &mem, dirfd, 60, 20));
    // Removing a missing directory → noent.
    writeGuestPath(&mem, 0, "ghost");
    try testing.expectEqual(p1.Errno.noent, pathRemoveDirectory(&h, &mem, dirfd, 0, 5));
}
