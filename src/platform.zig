const std = @import("std");
const builtin = @import("builtin");

pub const windows = std.os.windows;
pub const kernel32 = std.os.windows.kernel32;

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

pub fn reservePages(size: usize, prot: Protection) PageError![]align(page_size) u8 {
    if (builtin.os.tag == .windows) {
        const addr = kernel32.VirtualAlloc(null, size, windows.MEM_RESERVE, protectionToWin(prot)) orelse
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
        const addr = kernel32.VirtualAlloc(
            null,
            size,
            windows.MEM_RESERVE | windows.MEM_COMMIT,
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
        const addr = kernel32.VirtualAlloc(
            region.ptr,
            region.len,
            windows.MEM_COMMIT,
            protectionToWin(prot),
        ) orelse return error.OutOfMemory;
        if (@intFromPtr(addr) != @intFromPtr(region.ptr)) return error.Unexpected;
        return;
    }

    const result = std.posix.system.mprotect(@ptrCast(region.ptr), region.len, protectionToPosix(prot));
    if (result != 0) return error.PermissionDenied;
}

pub fn protectPages(region: []align(page_size) u8, prot: Protection) PageError!void {
    if (region.len == 0) return;

    if (builtin.os.tag == .windows) {
        var old_protect: windows.DWORD = 0;
        windows.VirtualProtect(region.ptr, region.len, protectionToWin(prot), &old_protect) catch |err| switch (err) {
            error.InvalidAddress => return error.InvalidAddress,
            else => return error.Unexpected,
        };
        return;
    }

    const result = std.posix.system.mprotect(@ptrCast(region.ptr), region.len, protectionToPosix(prot));
    if (result != 0) return error.PermissionDenied;
}

pub fn freePages(region: []align(page_size) u8) void {
    if (region.len == 0) return;

    if (builtin.os.tag == .windows) {
        windows.VirtualFree(region.ptr, 0, windows.MEM_RELEASE);
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

pub fn appCacheDir(alloc: std.mem.Allocator, app_name: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        return std.fs.getAppDataDir(alloc, app_name);
    }

    if (try envPath(alloc, "HOME")) |home| {
        defer alloc.free(home);
        return std.fmt.allocPrint(alloc, "{s}/.cache/{s}", .{ home, app_name });
    }

    return std.fmt.allocPrint(alloc, "/tmp/{s}", .{app_name});
}

pub fn tempDirPath(alloc: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (try envPath(alloc, "TEMP")) |path| return path;
        if (try envPath(alloc, "TMP")) |path| return path;
    } else {
        if (try envPath(alloc, "TMPDIR")) |path| return path;
    }

    if (builtin.os.tag == .windows) {
        return std.fs.getAppDataDir(alloc, "Temp");
    }
    return alloc.dupe(u8, "/tmp");
}

fn envPath(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (builtin.os.tag == .windows) {
        var env_map = try std.process.Environ.createMap(.{ .block = .global }, alloc);
        defer env_map.deinit();

        const value = env_map.get(name) orelse return null;
        return alloc.dupe(u8, value);
    }

    return null;
}

fn protectionToWin(prot: Protection) windows.DWORD {
    return switch (prot) {
        .none => windows.PAGE_NOACCESS,
        .read_write => windows.PAGE_READWRITE,
        .read_exec => windows.PAGE_EXECUTE_READ,
    };
}

fn protectionToPosix(prot: Protection) std.posix.PROT {
    return switch (prot) {
        .none => .{},
        .read_write => .{ .READ = true, .WRITE = true },
        .read_exec => .{ .READ = true, .EXEC = true },
    };
}

extern "kernel32" fn FlushInstructionCache(
    hProcess: windows.HANDLE,
    lpBaseAddress: ?*const anyopaque,
    dwSize: windows.SIZE_T,
) callconv(.winapi) windows.BOOL;
