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
// path_rename / path_link
// ============================================================

/// `path_rename(old_dirfd, old_path, new_dirfd, new_path) → errno` — rename
/// (move) a path across two preopen dirfds (`std.Io.Dir.rename`). Both ends are
/// resolved + escape-guarded.
pub fn pathRename(host: *Host, mem: []const u8, old_dirfd: p1.Fd, old_ptr: u32, old_len: u32, new_dirfd: p1.Fd, new_ptr: u32, new_len: u32) p1.Errno {
    var ro: Resolved = undefined;
    const e1 = resolve(host, mem, old_dirfd, old_ptr, old_len, &ro);
    if (e1 != .success) return e1;
    var rn: Resolved = undefined;
    const e2 = resolve(host, mem, new_dirfd, new_ptr, new_len, &rn);
    if (e2 != .success) return e2;
    const io = host.io orelse return .nosys;
    ro.dir.rename(ro.sub, rn.dir, rn.sub, io) catch |err| return mapDirErr(err);
    return .success;
}

/// `path_link(old_dirfd, old_flags, old_path, new_dirfd, new_path) → errno` —
/// create a hard link at `new_path` to the existing `old_path`
/// (`std.Io.Dir.hardLink`). `old_flags` bit 0 = follow-symlinks.
pub fn pathLink(host: *Host, mem: []const u8, old_dirfd: p1.Fd, old_flags: u32, old_ptr: u32, old_len: u32, new_dirfd: p1.Fd, new_ptr: u32, new_len: u32) p1.Errno {
    var ro: Resolved = undefined;
    const e1 = resolve(host, mem, old_dirfd, old_ptr, old_len, &ro);
    if (e1 != .success) return e1;
    var rn: Resolved = undefined;
    const e2 = resolve(host, mem, new_dirfd, new_ptr, new_len, &rn);
    if (e2 != .success) return e2;
    const io = host.io orelse return .nosys;
    ro.dir.hardLink(ro.sub, rn.dir, rn.sub, io, .{
        .follow_symlinks = old_flags & p1.LOOKUPFLAGS_SYMLINK_FOLLOW != 0,
    }) catch |err| return mapDirErr(err);
    return .success;
}

// ============================================================
// path_symlink / path_readlink
// ============================================================

/// `path_symlink(target, target_len, dirfd, link_path, link_path_len) → errno`
/// — create a symlink at `link_path` (relative to `dirfd`, escape-guarded)
/// whose contents are `target`. The target is the symlink's literal value, NOT
/// a path resolved against the preopen, so it is not escape-checked.
pub fn pathSymlink(host: *Host, mem: []const u8, target_ptr: u32, target_len: u32, dirfd: p1.Fd, path_ptr: u32, path_len: u32) p1.Errno {
    const target = sliceMemConst(mem, target_ptr, target_len) orelse return .fault;
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    r.dir.symLink(io, target, r.sub, .{}) catch |err| return mapDirErr(err);
    return .success;
}

/// `path_readlink(dirfd, path, buf, buf_len, *bufused_out) → errno` — read the
/// symlink at `path` into the guest buffer (`std.Io.Dir.readLink`), writing the
/// byte count to `bufused`. A non-symlink path → `inval` (NotLink).
pub fn pathReadlink(host: *Host, mem: []u8, dirfd: p1.Fd, path_ptr: u32, path_len: u32, buf_ptr: u32, buf_len: u32, bufused_ptr: u32) p1.Errno {
    if (@as(usize, bufused_ptr) + 4 > mem.len) return .fault;
    const buf = blk: {
        const end = @as(usize, buf_ptr) + @as(usize, buf_len);
        if (end > mem.len) return .fault;
        break :blk mem[buf_ptr..end];
    };
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    const n = r.dir.readLink(io, r.sub, buf) catch |err| return mapDirErr(err);
    std.mem.writeInt(u32, mem[bufused_ptr..][0..4], @intCast(n), .little);
    return .success;
}

// ============================================================
// path_filestat_get / path_filestat_set_times
// ============================================================

fn filetypeFromKind(kind: std.Io.File.Kind) p1.Filetype {
    return switch (kind) {
        .file => .regular_file,
        .directory => .directory,
        .sym_link => .symbolic_link,
        .block_device => .block_device,
        .character_device => .character_device,
        .named_pipe, .unix_domain_socket, .whiteout, .door, .event_port, .unknown => .unknown,
    };
}

fn setTimestampOf(flags: p1.Fstflags, now_bit: p1.Fstflags, set_bit: p1.Fstflags, ns: u64) std.Io.File.SetTimestamp {
    if (flags & now_bit != 0) return .now;
    if (flags & set_bit != 0) return .{ .new = std.Io.Timestamp.fromNanoseconds(@intCast(ns)) };
    return .unchanged;
}

/// `path_filestat_get(dirfd, lookupflags, path, *filestat_out) → errno` — stat
/// a path relative to `dirfd` (`std.Io.Dir.statFile`) and write the 64-byte
/// `Filestat`. `lookupflags` bit 0 = follow-symlinks.
pub fn pathFilestatGet(host: *Host, mem: []u8, dirfd: p1.Fd, lookupflags: u32, path_ptr: u32, path_len: u32, filestat_ptr: u32) p1.Errno {
    const dst = blk: {
        const end = @as(usize, filestat_ptr) + @sizeOf(p1.Filestat);
        if (end > mem.len) return .fault;
        break :blk mem[filestat_ptr..end];
    };
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    const st = r.dir.statFile(io, r.sub, .{ .follow_symlinks = lookupflags & p1.LOOKUPFLAGS_SYMLINK_FOLLOW != 0 }) catch |err| return mapDirErr(err);
    const atim_ns: i96 = if (st.atime) |a| a.nanoseconds else st.mtime.nanoseconds;
    const fs: p1.Filestat = .{
        .dev = 0,
        .ino = @intCast(st.inode),
        .filetype = filetypeFromKind(st.kind),
        .nlink = @intCast(st.nlink),
        .size = st.size,
        .atim = if (atim_ns > 0) @intCast(atim_ns) else 0,
        .mtim = if (st.mtime.nanoseconds > 0) @intCast(st.mtime.nanoseconds) else 0,
        .ctim = if (st.ctime.nanoseconds > 0) @intCast(st.ctime.nanoseconds) else 0,
    };
    @memcpy(dst, std.mem.asBytes(&fs));
    return .success;
}

/// `path_filestat_set_times(dirfd, lookupflags, path, atim, mtim, fst_flags)
/// → errno` — set a path's access/modify timestamps (`std.Io.Dir.setTimestamps`).
/// Explicit-value + `*_NOW` for one stamp → `inval`.
pub fn pathFilestatSetTimes(host: *Host, mem: []const u8, dirfd: p1.Fd, lookupflags: u32, path_ptr: u32, path_len: u32, atim: u64, mtim: u64, fst_flags: p1.Fstflags) p1.Errno {
    if (fst_flags & p1.FSTFLAGS_ATIM != 0 and fst_flags & p1.FSTFLAGS_ATIM_NOW != 0) return .inval;
    if (fst_flags & p1.FSTFLAGS_MTIM != 0 and fst_flags & p1.FSTFLAGS_MTIM_NOW != 0) return .inval;
    var r: Resolved = undefined;
    const e = resolve(host, mem, dirfd, path_ptr, path_len, &r);
    if (e != .success) return e;
    const io = host.io orelse return .nosys;
    r.dir.setTimestamps(io, r.sub, .{
        .follow_symlinks = lookupflags & p1.LOOKUPFLAGS_SYMLINK_FOLLOW != 0,
        .access_timestamp = setTimestampOf(fst_flags, p1.FSTFLAGS_ATIM_NOW, p1.FSTFLAGS_ATIM, atim),
        .modify_timestamp = setTimestampOf(fst_flags, p1.FSTFLAGS_MTIM_NOW, p1.FSTFLAGS_MTIM, mtim),
    }) catch |err| return mapDirErr(err);
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

test "pathFilestatGet / pathFilestatSetTimes: stat a path + set its mtim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "hello" });
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    writeGuestPath(&mem, 0, "f.txt");
    const FS = 16; // filestat_ptr
    try testing.expectEqual(p1.Errno.success, pathFilestatGet(&h, &mem, dirfd, p1.LOOKUPFLAGS_SYMLINK_FOLLOW, 0, 5, FS));
    try testing.expectEqual(@as(u8, @intFromEnum(p1.Filetype.regular_file)), mem[FS + 16]); // filetype @+16
    try testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, mem[FS + 32 ..][0..8], .little)); // size @+32

    // Set mtim to 3.0s (whole second) and read it back @+48.
    try testing.expectEqual(p1.Errno.success, pathFilestatSetTimes(&h, &mem, dirfd, 0, 0, 5, 0, 3_000_000_000, p1.FSTFLAGS_MTIM));
    try testing.expectEqual(p1.Errno.success, pathFilestatGet(&h, &mem, dirfd, 0, 0, 5, FS));
    try testing.expectEqual(@as(u64, 3_000_000_000), std.mem.readInt(u64, mem[FS + 48 ..][0..8], .little));

    // Conflicting explicit+NOW → inval; a missing path → noent.
    try testing.expectEqual(p1.Errno.inval, pathFilestatSetTimes(&h, &mem, dirfd, 0, 0, 5, 0, 0, p1.FSTFLAGS_MTIM | p1.FSTFLAGS_MTIM_NOW));
    writeGuestPath(&mem, 0, "nope!");
    try testing.expectEqual(p1.Errno.noent, pathFilestatGet(&h, &mem, dirfd, 0, 0, 5, FS));
}

test "pathSymlink / pathReadlink: create a symlink and read its target back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    writeGuestPath(&mem, 0, "target.txt"); // target (link contents) @0, len 10
    writeGuestPath(&mem, 16, "lnk"); // link path @16, len 3
    const sym_e = pathSymlink(&h, &mem, 0, 10, dirfd, 16, 3);
    // A platform that denies unprivileged symlink creation (e.g. Windows
    // without Developer Mode) returns acces — the handler is correct; skip the
    // round-trip assertion there. Mac/Linux create + read it back fully.
    if (sym_e == .acces) return;
    try testing.expectEqual(p1.Errno.success, sym_e);

    // readlink the symlink into buf @32, write bufused @64.
    try testing.expectEqual(p1.Errno.success, pathReadlink(&h, &mem, dirfd, 16, 3, 32, 32, 64));
    const n = std.mem.readInt(u32, mem[64..68], .little);
    try testing.expectEqual(@as(u32, 10), n);
    try testing.expectEqualStrings("target.txt", mem[32 .. 32 + n]);

    // readlink on a non-symlink → inval (NotLink).
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain", .data = "x" });
    writeGuestPath(&mem, 96, "plain");
    try testing.expectEqual(p1.Errno.inval, pathReadlink(&h, &mem, dirfd, 96, 5, 32, 32, 64));
}

test "pathRename / pathLink: move a file and hard-link it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "data" });
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    h.io = testing.io;
    const dirfd = try h.addPreopen(tmp.dir.handle, "/sandbox");

    var mem: [128]u8 = @splat(0);
    writeGuestPath(&mem, 0, "a.txt"); // @0 len 5
    writeGuestPath(&mem, 16, "b.txt"); // @16 len 5
    try testing.expectEqual(p1.Errno.success, pathRename(&h, &mem, dirfd, 0, 5, dirfd, 16, 5));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "a.txt", .{}));
    _ = tmp.dir.statFile(testing.io, "b.txt", .{}) catch return error.RenameTargetMissing;

    // hard-link b.txt → c.txt; both resolve to the same inode (size matches).
    writeGuestPath(&mem, 32, "c.txt"); // @32 len 5
    const link_e = pathLink(&h, &mem, dirfd, 0, 16, 5, dirfd, 32, 5);
    if (link_e == .acces) return; // platform without unprivileged hardlink support
    try testing.expectEqual(p1.Errno.success, link_e);
    const st = tmp.dir.statFile(testing.io, "c.txt", .{}) catch return error.LinkMissing;
    try testing.expectEqual(@as(u64, 4), st.size);

    // Renaming a missing source → noent.
    writeGuestPath(&mem, 48, "ghost");
    try testing.expectEqual(p1.Errno.noent, pathRename(&h, &mem, dirfd, 48, 5, dirfd, 0, 5));
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
