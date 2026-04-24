const std = @import("std");
const builtin = @import("builtin");

pub const windows = std.os.windows;

const page_size = std.heap.page_size_min;

pub const Protection = enum {
    none,
    read_write,
    read_exec,
};

pub const PageError = error{
    OutOfMemory,
    PermissionDenied,
    InvalidAddress,
    Unexpected,
};

// Zig 0.16 trimmed `std.os.windows.kernel32` down to `CreateProcessW` only —
// the VM-management entry points we need for JIT codegen are no longer in
// stdlib. Declare our own externs. Signatures match the Win32 SDK. Constants
// live on `windows.MEM` / `windows.PAGE` which are still stdlib-provided.
extern "kernel32" fn VirtualAlloc(
    lpAddress: ?*anyopaque,
    dwSize: windows.SIZE_T,
    flAllocationType: windows.MEM.ALLOCATE,
    flProtect: windows.PAGE,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn VirtualFree(
    lpAddress: *anyopaque,
    dwSize: windows.SIZE_T,
    dwFreeType: windows.MEM.FREE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn VirtualProtect(
    lpAddress: *anyopaque,
    dwSize: windows.SIZE_T,
    flNewProtect: windows.PAGE,
    lpflOldProtect: *windows.PAGE,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: windows.HANDLE,
    hSourceHandle: windows.HANDLE,
    hTargetProcessHandle: windows.HANDLE,
    lpTargetHandle: *windows.HANDLE,
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwOptions: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const DUPLICATE_SAME_ACCESS: windows.DWORD = 0x00000002;

extern "kernel32" fn FlushInstructionCache(
    hProcess: windows.HANDLE,
    lpBaseAddress: ?*const anyopaque,
    dwSize: windows.SIZE_T,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn FlushFileBuffers(
    hFile: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

// WASI I/O shims. Zig 0.16 sets `std.c.fd_t = windows.HANDLE` on Windows
// but `std.c.write`/`read`/`lseek`/... are bound to MSVCRT `_write(int fd, …)`,
// so passing a HANDLE where an int fd is expected silently corrupts Windows
// stdio. The functions below present a POSIX-style API and dispatch to
// Win32 `WriteFile`/`ReadFile`/`SetFilePointerEx` on Windows, and keep the
// std.c.* path on POSIX.
extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: *windows.DWORD,
    lpOverlapped: ?*Overlapped,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: *windows.DWORD,
    lpOverlapped: ?*Overlapped,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetFilePointerEx(
    hFile: windows.HANDLE,
    liDistanceToMove: windows.LARGE_INTEGER,
    lpNewFilePointer: ?*windows.LARGE_INTEGER,
    dwMoveMethod: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CloseHandle(
    hObject: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;

// Flattened OVERLAPPED layout — we only use the Offset/OffsetHigh path.
const Overlapped = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: windows.DWORD = 0,
    OffsetHigh: windows.DWORD = 0,
    hEvent: ?windows.HANDLE = null,
};

const FILE_BEGIN: windows.DWORD = 0;
const FILE_CURRENT: windows.DWORD = 1;
const FILE_END: windows.DWORD = 2;

const ERROR_HANDLE_EOF: windows.DWORD = 38;
const ERROR_BROKEN_PIPE: windows.DWORD = 109;

// Thread-local errno set by pfd helpers. Read via `pfdErrno()`. Callers that
// previously consulted `std.c._errno().*` should use `pfdErrno()` instead so
// the code path does not depend on libc being linked.
pub threadlocal var pfd_last_errno: std.posix.E = .SUCCESS;

pub fn pfdErrno() std.posix.E {
    return pfd_last_errno;
}

/// Copy libc's thread-local errno slot into `pfd_last_errno`. Call this after
/// a `std.c.*` call has returned a failure so that `pfdErrno()` reflects the
/// actual failure. Mac/BSD code paths use this; Linux pfd helpers set
/// `pfd_last_errno` directly from the syscall return value.
pub fn syncErrnoFromLibC() void {
    switch (comptime builtin.os.tag) {
        .linux, .windows => {},
        else => pfd_last_errno = @enumFromInt(std.c._errno().*),
    }
}

// Linux direct-syscall helpers. Syscalls return errno as negative values
// cast to `usize`; convert that into the POSIX-style (-1, errno-in-slot)
// convention that upstream callers already expect.
fn linuxResultAsIsize(rc: usize) isize {
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS) {
        pfd_last_errno = e;
        return -1;
    }
    return @bitCast(rc);
}

fn linuxResultAsI32(rc: usize) i32 {
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS) {
        pfd_last_errno = e;
        return -1;
    }
    return 0;
}

fn linuxResultAsI64(rc: usize) i64 {
    const e = std.os.linux.errno(rc);
    if (e != .SUCCESS) {
        pfd_last_errno = e;
        return -1;
    }
    return @as(i64, @bitCast(@as(u64, rc)));
}

// Mac/BSD helpers — call after a `std.c.*` invocation so `pfd_last_errno`
// reflects the failure. The `if` is comptime-inert on Linux/Windows because
// the whole `else =>` arm is comptime-pruned.
fn cResultAsIsize(rc: isize) isize {
    if (rc < 0) pfd_last_errno = @enumFromInt(std.c._errno().*);
    return rc;
}

fn cResultAsI32(rc: c_int) i32 {
    const r: i32 = @intCast(rc);
    if (r != 0) pfd_last_errno = @enumFromInt(std.c._errno().*);
    return r;
}

fn cResultAsI64(rc: std.c.off_t) i64 {
    if (rc < 0) pfd_last_errno = @enumFromInt(std.c._errno().*);
    return @intCast(rc);
}

/// POSIX-style write. Returns bytes written (>= 0) or -1 on error.
pub fn pfdWrite(handle: std.posix.fd_t, buf: []const u8) isize {
    switch (comptime builtin.os.tag) {
        .windows => {
            var written: windows.DWORD = 0;
            const ok = WriteFile(handle, buf.ptr, @intCast(buf.len), &written, null);
            if (ok == windows.BOOL.FALSE) {
                pfd_last_errno = .IO;
                return -1;
            }
            return @intCast(written);
        },
        .linux => return linuxResultAsIsize(std.os.linux.write(handle, buf.ptr, buf.len)),
        else => return cResultAsIsize(std.c.write(handle, buf.ptr, buf.len)),
    }
}

/// POSIX-style read. Returns bytes read (>= 0, 0 == EOF) or -1 on error.
pub fn pfdRead(handle: std.posix.fd_t, buf: []u8) isize {
    switch (comptime builtin.os.tag) {
        .windows => {
            var got: windows.DWORD = 0;
            const ok = ReadFile(handle, buf.ptr, @intCast(buf.len), &got, null);
            if (ok == windows.BOOL.FALSE) {
                const err = GetLastError();
                if (err == ERROR_BROKEN_PIPE or err == ERROR_HANDLE_EOF) return 0;
                pfd_last_errno = .IO;
                return -1;
            }
            return @intCast(got);
        },
        .linux => return linuxResultAsIsize(std.os.linux.read(handle, buf.ptr, buf.len)),
        else => return cResultAsIsize(std.c.read(handle, buf.ptr, buf.len)),
    }
}

/// POSIX-style positional read. Does not move the file offset.
pub fn pfdPread(handle: std.posix.fd_t, buf: []u8, offset: u64) isize {
    switch (comptime builtin.os.tag) {
        .windows => {
            var ov: Overlapped = .{
                .Offset = @truncate(offset),
                .OffsetHigh = @truncate(offset >> 32),
            };
            var got: windows.DWORD = 0;
            const ok = ReadFile(handle, buf.ptr, @intCast(buf.len), &got, &ov);
            if (ok == windows.BOOL.FALSE) {
                const err = GetLastError();
                if (err == ERROR_BROKEN_PIPE or err == ERROR_HANDLE_EOF) return 0;
                pfd_last_errno = .IO;
                return -1;
            }
            return @intCast(got);
        },
        .linux => return linuxResultAsIsize(std.os.linux.pread(handle, buf.ptr, buf.len, @intCast(offset))),
        else => return cResultAsIsize(std.c.pread(handle, buf.ptr, buf.len, @intCast(offset))),
    }
}

/// POSIX-style positional write. Does not move the file offset.
pub fn pfdPwrite(handle: std.posix.fd_t, buf: []const u8, offset: u64) isize {
    switch (comptime builtin.os.tag) {
        .windows => {
            var ov: Overlapped = .{
                .Offset = @truncate(offset),
                .OffsetHigh = @truncate(offset >> 32),
            };
            var written: windows.DWORD = 0;
            const ok = WriteFile(handle, buf.ptr, @intCast(buf.len), &written, &ov);
            if (ok == windows.BOOL.FALSE) {
                pfd_last_errno = .IO;
                return -1;
            }
            return @intCast(written);
        },
        .linux => return linuxResultAsIsize(std.os.linux.pwrite(handle, buf.ptr, buf.len, @intCast(offset))),
        else => return cResultAsIsize(std.c.pwrite(handle, buf.ptr, buf.len, @intCast(offset))),
    }
}

/// POSIX-style seek. `whence` uses `std.posix.SEEK.{SET,CUR,END}`.
/// Returns the new offset or -1 on error.
pub fn pfdSeek(handle: std.posix.fd_t, offset: i64, whence: c_int) i64 {
    switch (comptime builtin.os.tag) {
        .windows => {
            const method: windows.DWORD = switch (whence) {
                std.posix.SEEK.SET => FILE_BEGIN,
                std.posix.SEEK.CUR => FILE_CURRENT,
                std.posix.SEEK.END => FILE_END,
                else => {
                    pfd_last_errno = .INVAL;
                    return -1;
                },
            };
            var new_pos: windows.LARGE_INTEGER = 0;
            const ok = SetFilePointerEx(handle, offset, &new_pos, method);
            if (ok == windows.BOOL.FALSE) {
                pfd_last_errno = .IO;
                return -1;
            }
            return new_pos;
        },
        .linux => return linuxResultAsI64(std.os.linux.lseek(handle, offset, @intCast(whence))),
        else => return cResultAsI64(std.c.lseek(handle, offset, whence)),
    }
}

pub fn pfdClose(handle: std.posix.fd_t) void {
    switch (comptime builtin.os.tag) {
        .windows => _ = CloseHandle(handle),
        .linux => _ = std.os.linux.close(handle),
        else => _ = std.c.close(handle),
    }
}

// Path-based helpers. All POSIX-only (callers of these helpers already
// branch to a `std.Io.Dir` path on Windows before reaching here). The
// `.windows` arms return -1 so compilation succeeds on Windows builds;
// the helpers themselves are never reached at runtime on Windows.
pub fn pfdMkdirAt(dirfd: std.posix.fd_t, path: [*:0]const u8, mode: u32) i32 {
    switch (comptime builtin.os.tag) {
        .windows => return -1,
        .linux => return linuxResultAsI32(std.os.linux.mkdirat(dirfd, path, mode)),
        else => return cResultAsI32(std.c.mkdirat(dirfd, path, @intCast(mode))),
    }
}

pub fn pfdUnlinkAt(dirfd: std.posix.fd_t, path: [*:0]const u8, flags: u32) i32 {
    switch (comptime builtin.os.tag) {
        .windows => return -1,
        .linux => return linuxResultAsI32(std.os.linux.unlinkat(dirfd, path, flags)),
        else => return cResultAsI32(std.c.unlinkat(dirfd, path, @intCast(flags))),
    }
}

pub fn pfdRenameAt(
    old_dirfd: std.posix.fd_t,
    old_path: [*:0]const u8,
    new_dirfd: std.posix.fd_t,
    new_path: [*:0]const u8,
) i32 {
    switch (comptime builtin.os.tag) {
        .windows => return -1,
        .linux => return linuxResultAsI32(std.os.linux.renameat(old_dirfd, old_path, new_dirfd, new_path)),
        else => return cResultAsI32(std.c.renameat(old_dirfd, old_path, new_dirfd, new_path)),
    }
}

pub fn pfdReadlinkAt(dirfd: std.posix.fd_t, path: [*:0]const u8, buf: []u8) isize {
    switch (comptime builtin.os.tag) {
        .windows => return -1,
        .linux => return linuxResultAsIsize(std.os.linux.readlinkat(dirfd, path, buf.ptr, buf.len)),
        else => return cResultAsIsize(std.c.readlinkat(dirfd, path, buf.ptr, buf.len)),
    }
}

pub fn pfdDup(fd: std.posix.fd_t) i32 {
    switch (comptime builtin.os.tag) {
        .windows => return -1,
        .linux => {
            const rc = std.os.linux.dup(fd);
            const e = std.os.linux.errno(rc);
            if (e != .SUCCESS) {
                pfd_last_errno = e;
                return -1;
            }
            return @intCast(rc);
        },
        else => return cResultAsI32(std.c.dup(fd)),
    }
}

pub fn pfdFsync(handle: std.posix.fd_t) i32 {
    switch (comptime builtin.os.tag) {
        .windows => {
            if (FlushFileBuffers(handle) == windows.BOOL.FALSE) {
                pfd_last_errno = .IO;
                return -1;
            }
            return 0;
        },
        .linux => return linuxResultAsI32(std.os.linux.fsync(handle)),
        else => return cResultAsI32(std.c.fsync(handle)),
    }
}

pub fn pfdDup2(oldfd: std.posix.fd_t, newfd: std.posix.fd_t) i32 {
    switch (comptime builtin.os.tag) {
        .windows => return -1,
        .linux => return linuxResultAsI32(std.os.linux.dup2(oldfd, newfd)),
        else => return cResultAsI32(std.c.dup2(oldfd, newfd)),
    }
}

pub fn pfdPipe(fds: *[2]std.posix.fd_t) i32 {
    switch (comptime builtin.os.tag) {
        .windows => return -1,
        .linux => return linuxResultAsI32(std.os.linux.pipe(fds)),
        else => return cResultAsI32(std.c.pipe(fds)),
    }
}

/// Sleep for the given number of nanoseconds. Best-effort — short-sleep
/// tests use this to give other threads time to start.
pub fn pfdSleepNs(ns: u64) void {
    switch (comptime builtin.os.tag) {
        .windows => {
            const K32 = struct {
                extern "kernel32" fn Sleep(dwMilliseconds: windows.DWORD) callconv(.winapi) void;
            };
            const ms: windows.DWORD = @intCast(@max(ns / 1_000_000, 1));
            K32.Sleep(ms);
        },
        .linux => {
            const req: std.os.linux.timespec = .{
                .sec = @intCast(ns / 1_000_000_000),
                .nsec = @intCast(ns % 1_000_000_000),
            };
            _ = std.os.linux.nanosleep(&req, null);
        },
        else => {
            const req: std.posix.timespec = .{
                .sec = @intCast(ns / 1_000_000_000),
                .nsec = @intCast(ns % 1_000_000_000),
            };
            _ = std.c.nanosleep(&req, null);
        },
    }
}

pub fn reservePages(size: usize, prot: Protection) PageError![]align(page_size) u8 {
    if (builtin.os.tag == .windows) {
        const addr = VirtualAlloc(null, size, .{ .RESERVE = true }, protectionToWin(prot)) orelse
            return error.OutOfMemory;
        const ptr: [*]align(page_size) u8 = @ptrCast(@alignCast(addr));
        return ptr[0..size];
    }

    const posix = std.posix;
    const buf = posix.mmap(
        null,
        size,
        protectionToPosix(prot),
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return error.OutOfMemory;
    return @alignCast(buf);
}

pub fn allocatePages(size: usize, prot: Protection) PageError![]align(page_size) u8 {
    if (builtin.os.tag == .windows) {
        const addr = VirtualAlloc(
            null,
            size,
            .{ .RESERVE = true, .COMMIT = true },
            protectionToWin(prot),
        ) orelse return error.OutOfMemory;
        const ptr: [*]align(page_size) u8 = @ptrCast(@alignCast(addr));
        return ptr[0..size];
    }

    return reservePages(size, prot);
}

pub fn commitPages(region: []align(page_size) u8, prot: Protection) PageError!void {
    if (region.len == 0) return;

    if (builtin.os.tag == .windows) {
        const addr = VirtualAlloc(
            region.ptr,
            region.len,
            .{ .COMMIT = true },
            protectionToWin(prot),
        ) orelse return error.OutOfMemory;
        if (@intFromPtr(addr) != @intFromPtr(region.ptr)) return error.Unexpected;
        return;
    }

    try mprotectPosix(region, protectionToPosix(prot));
}

pub fn protectPages(region: []align(page_size) u8, prot: Protection) PageError!void {
    if (region.len == 0) return;

    if (builtin.os.tag == .windows) {
        var old_protect: windows.PAGE = .{};
        if (VirtualProtect(region.ptr, region.len, protectionToWin(prot), &old_protect) == windows.BOOL.FALSE) {
            return error.PermissionDenied;
        }
        return;
    }

    try mprotectPosix(region, protectionToPosix(prot));
}

fn mprotectPosix(region: []align(page_size) u8, prot: std.posix.PROT) PageError!void {
    if (builtin.link_libc) {
        if (std.c.mprotect(region.ptr, region.len, prot) != 0) return error.PermissionDenied;
        return;
    }
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.mprotect(region.ptr, region.len, prot);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            else => return error.PermissionDenied,
        }
    }
    return error.Unexpected;
}

pub fn freePages(region: []align(page_size) u8) void {
    if (region.len == 0) return;

    if (builtin.os.tag == .windows) {
        _ = VirtualFree(region.ptr, 0, .{ .RELEASE = true });
        return;
    }

    std.posix.munmap(region);
}

pub fn flushInstructionCache(ptr: [*]const u8, len: usize) void {
    if (len == 0) return;

    if (builtin.os.tag == .windows) {
        _ = FlushInstructionCache(windows.GetCurrentProcess(), ptr, len);
    } else if (builtin.os.tag == .macos) {
        const func = @extern(*const fn ([*]const u8, usize) callconv(.c) void, .{
            .name = "sys_icache_invalidate",
        });
        func(ptr, len);
    } else if (builtin.os.tag == .linux) {
        const func = @extern(*const fn ([*]const u8, [*]const u8) callconv(.c) void, .{
            .name = "__clear_cache",
        });
        func(ptr, ptr + len);
    }
}

// Process-wide environment table captured at program start via `setEnvironMap`.
// This lets `envPath` / `appCacheDir` / `tempDirPath` look up variables without
// calling libc's `getenv` — the last remaining blocker for dropping
// `link_libc = true` on Linux (W46 Phase 1e).
var env_map_ref: ?*const std.process.Environ.Map = null;

/// Capture the process's environment block. Call once at program start
/// (from `main(init: std.process.Init)`). Tests that never exercise
/// `envPath` may skip calling this; `envPath` returns null when unset.
pub fn setEnvironMap(m: *const std.process.Environ.Map) void {
    env_map_ref = m;
}

pub fn appCacheDir(alloc: std.mem.Allocator, app_name: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        // Zig 0.16 removed `std.fs.getAppDataDir`. Build the path ourselves
        // from %LOCALAPPDATA% (fall back to %APPDATA%).
        const base = (try envPath(alloc, "LOCALAPPDATA")) orelse
            (try envPath(alloc, "APPDATA")) orelse return error.NoCacheDir;
        defer alloc.free(base);
        return std.fmt.allocPrint(alloc, "{s}\\{s}", .{ base, app_name });
    }

    const home = (try envPath(alloc, "HOME")) orelse return error.NoCacheDir;
    defer alloc.free(home);
    return std.fmt.allocPrint(alloc, "{s}/.cache/{s}", .{ home, app_name });
}

pub fn tempDirPath(alloc: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (try envPath(alloc, "TEMP")) |path| return path;
        if (try envPath(alloc, "TMP")) |path| return path;
        // Fall back to a reasonable Windows default.
        return alloc.dupe(u8, "C:\\Windows\\Temp");
    }
    if (try envPath(alloc, "TMPDIR")) |path| return path;
    return alloc.dupe(u8, "/tmp");
}

fn envPath(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    const m = env_map_ref orelse return null;
    const val = m.get(name) orelse return null;
    if (val.len == 0) return null;
    return try alloc.dupe(u8, val);
}

fn protectionToWin(prot: Protection) windows.PAGE {
    return switch (prot) {
        .none => .{ .NOACCESS = true },
        .read_write => .{ .READWRITE = true },
        .read_exec => .{ .EXECUTE_READ = true },
    };
}

fn protectionToPosix(prot: Protection) std.posix.PROT {
    return switch (prot) {
        .none => .{},
        .read_write => .{ .READ = true, .WRITE = true },
        .read_exec => .{ .READ = true, .EXEC = true },
    };
}
