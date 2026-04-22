// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! WASI Preview 1 implementation for custom Wasm runtime.
//!
//! Provides 19 WASI snapshot_preview1 functions for basic I/O, args, environ,
//! clock, random, and filesystem operations. Host functions pop args from the
//! Wasm operand stack, perform the operation, and push errno result.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;
const windows = std.os.windows;
const kernel32 = std.os.windows.kernel32;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const WasmError = vm_mod.WasmError;
const WasmMemory = @import("memory.zig").Memory;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const opcode = @import("opcode.zig");
const ValType = opcode.ValType;

// ============================================================
// Helper functions
// ============================================================

/// Get current monotonic time in nanoseconds (helper for Zig 0.16.0+)
fn getNanoTimestamp() i128 {
    var ts: std.posix.timespec = undefined;
    const result = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    if (result != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

// ============================================================
// WASI errno codes (wasi_snapshot_preview1)
// ============================================================

pub const Errno = enum(u32) {
    SUCCESS = 0,
    TOOBIG = 1,
    ACCES = 2,
    ADDRINUSE = 3,
    ADDRNOTAVAIL = 4,
    AFNOSUPPORT = 5,
    AGAIN = 6,
    ALREADY = 7,
    BADF = 8,
    BADMSG = 9,
    BUSY = 10,
    CANCELED = 11,
    CHILD = 12,
    CONNABORTED = 13,
    CONNREFUSED = 14,
    CONNRESET = 15,
    DEADLK = 16,
    DESTADDRREQ = 17,
    DOM = 18,
    DQUOT = 19,
    EXIST = 20,
    FAULT = 21,
    FBIG = 22,
    HOSTUNREACH = 23,
    IDRM = 24,
    ILSEQ = 25,
    INPROGRESS = 26,
    INTR = 27,
    INVAL = 28,
    IO = 29,
    ISCONN = 30,
    ISDIR = 31,
    LOOP = 32,
    MFILE = 33,
    MLINK = 34,
    MSGSIZE = 35,
    MULTIHOP = 36,
    NAMETOOLONG = 37,
    NETDOWN = 38,
    NETRESET = 39,
    NETUNREACH = 40,
    NFILE = 41,
    NOBUFS = 42,
    NODEV = 43,
    NOENT = 44,
    NOEXEC = 45,
    NOLCK = 46,
    NOLINK = 47,
    NOMEM = 48,
    NOMSG = 49,
    NOPROTOOPT = 50,
    NOSPC = 51,
    NOSYS = 52,
    NOTCONN = 53,
    NOTDIR = 54,
    NOTEMPTY = 55,
    NOTRECOVERABLE = 56,
    NOTSOCK = 57,
    NOTSUP = 58,
    NOTTY = 59,
    NXIO = 60,
    OVERFLOW = 61,
    OWNERDEAD = 62,
    PERM = 63,
    PIPE = 64,
    PROTO = 65,
    PROTONOSUPPORT = 66,
    PROTOTYPE = 67,
    RANGE = 68,
    ROFS = 69,
    SPIPE = 70,
    SRCH = 71,
    STALE = 72,
    TIMEDOUT = 73,
    TXTBSY = 74,
    XDEV = 75,
    NOTCAPABLE = 76,
};

pub const Filetype = enum(u8) {
    UNKNOWN = 0,
    BLOCK_DEVICE = 1,
    CHARACTER_DEVICE = 2,
    DIRECTORY = 3,
    REGULAR_FILE = 4,
    SOCKET_DGRAM = 5,
    SOCKET_STREAM = 6,
    SYMBOLIC_LINK = 7,
};

pub const Whence = enum(u8) {
    SET = 0,
    CUR = 1,
    END = 2,
};

pub const ClockId = enum(u32) {
    REALTIME = 0,
    MONOTONIC = 1,
    PROCESS_CPUTIME = 2,
    THREAD_CPUTIME = 3,
};

// ============================================================
// Preopened directory
// ============================================================

pub const HandleKind = enum {
    file,
    dir,
};

const HostHandle = struct {
    raw: std.posix.fd_t,
    kind: HandleKind,

    fn file(self: HostHandle) std.Io.File {
        return .{ .handle = self.raw, .flags = .{ .nonblocking = false } };
    }

    fn dir(self: HostHandle) std.Io.Dir {
        return .{ .handle = self.raw };
    }

    fn close(self: HostHandle) void {
        switch (self.kind) {
            .file => _ = std.posix.system.close(self.raw),
            .dir => _ = std.posix.system.close(self.raw),
        }
    }

    fn stat(self: HostHandle, io: std.Io) !std.Io.File.Stat {
        return switch (self.kind) {
            .file => self.file().stat(io),
            .dir => self.dir().stat(io),
        };
    }

    fn duplicate(self: HostHandle) !HostHandle {
        const duplicated = if (builtin.os.tag == .windows) blk: {
            const proc = windows.GetCurrentProcess();
            var dup_handle: windows.HANDLE = undefined;
            if (kernel32.DuplicateHandle(proc, self.raw, proc, &dup_handle, 0, 0, windows.DUPLICATE_SAME_ACCESS) == 0) {
                switch (windows.GetLastError()) {
                    .NOT_ENOUGH_MEMORY => return error.SystemResources,
                    .ACCESS_DENIED => return error.AccessDenied,
                    else => return error.Unexpected,
                }
            }
            break :blk dup_handle;
        } else blk: {
            const new_fd = std.posix.system.dup(self.raw);
            if (new_fd < 0) return error.SystemResources;
            break :blk @as(std.posix.fd_t, @intCast(new_fd));
        };

        return .{
            .raw = duplicated,
            .kind = self.kind,
        };
    }
};

/// Ownership mode for file descriptors passed by the embedder.
pub const Ownership = enum {
    /// Runtime does NOT close the fd on teardown — caller retains ownership.
    borrow,
    /// Runtime closes the fd on teardown — ownership transferred.
    own,
};

pub const Preopen = struct {
    wasi_fd: i32,
    path: []const u8,
    host: HostHandle,
    is_open: bool = true,
    ownership: Ownership = .own,
};

/// Runtime file descriptor entry (for dynamically opened files).
pub const FdEntry = struct {
    host: HostHandle,
    is_open: bool = true,
    append: bool = false,
};

// ============================================================
// WASI capabilities — deny-by-default security model
// ============================================================

pub const Capabilities = packed struct {
    allow_stdio: bool = false, // fd 0-2: stdin/stdout/stderr
    allow_read: bool = false, // fd_read, fd_pread, path_open(read)
    allow_write: bool = false, // fd_write, fd_pwrite, path_open(write)
    allow_env: bool = false, // environ_get, environ_sizes_get
    allow_clock: bool = false, // clock_time_get, clock_res_get
    allow_random: bool = false, // random_get
    allow_proc_exit: bool = false, // proc_exit
    allow_path: bool = false, // path_open, path_create_directory, path_remove_directory, etc.

    pub const all = Capabilities{
        .allow_stdio = true,
        .allow_read = true,
        .allow_write = true,
        .allow_env = true,
        .allow_clock = true,
        .allow_random = true,
        .allow_proc_exit = true,
        .allow_path = true,
    };

    pub const cli_default = Capabilities{
        .allow_stdio = true,
        .allow_clock = true,
        .allow_random = true,
        .allow_proc_exit = true,
    };

    /// Sandbox preset: all capabilities denied.
    pub const sandbox = Capabilities{};
};

// ============================================================
// WASI context — per-instance WASI state
// ============================================================

pub const WasiContext = struct {
    io: std.Io,
    args: []const [:0]const u8,
    environ_keys: std.ArrayList([]const u8),
    environ_vals: std.ArrayList([]const u8),
    preopens: std.ArrayList(Preopen),
    fd_table: std.ArrayList(FdEntry), // runtime-opened fds (wasi_fd = index + fd_base)
    fd_base: i32 = 0, // first dynamic fd number (set after preopens added)
    alloc: Allocator,
    exit_code: ?u32 = null,
    caps: Capabilities = .{}, // deny-by-default

    // Stdio override: per-fd custom handle (null = use process default)
    stdio_handles: [3]?std.posix.fd_t = .{ null, null, null },
    stdio_ownership: [3]Ownership = .{ .borrow, .borrow, .borrow },

    pub fn init(alloc: Allocator, io: std.Io) WasiContext {
        return .{
            .io = io,
            .args = &.{},
            .environ_keys = .empty,
            .environ_vals = .empty,
            .preopens = .empty,
            .fd_table = .empty,
            .alloc = alloc,
        };
    }

    fn closeHandle(handle: std.posix.fd_t) void {
        _ = std.posix.system.close(handle);
    }

    pub fn deinit(self: *WasiContext) void {
        // Close owned stdio overrides
        for (self.stdio_handles, self.stdio_ownership) |maybe_handle, ownership| {
            if (maybe_handle) |handle| {
                if (ownership == .own) closeHandle(handle);
            }
        }
        self.environ_keys.deinit(self.alloc);
        self.environ_vals.deinit(self.alloc);
        for (self.preopens.items) |p| {
            if (p.is_open and p.ownership == .own) p.host.close();
        }
        self.preopens.deinit(self.alloc);
        for (self.fd_table.items) |entry| {
            if (entry.is_open) entry.host.close();
        }
        self.fd_table.deinit(self.alloc);
    }

    pub fn setArgs(self: *WasiContext, args: []const [:0]const u8) void {
        self.args = args;
    }

    pub fn addEnv(self: *WasiContext, key: []const u8, val: []const u8) !void {
        try self.environ_keys.append(self.alloc, key);
        try self.environ_vals.append(self.alloc, val);
    }

    pub fn addPreopen(self: *WasiContext, wasi_fd: i32, path: []const u8, host_dir: std.Io.Dir) !void {
        try self.preopens.append(self.alloc, .{
            .wasi_fd = wasi_fd,
            .path = path,
            .host = .{
                .raw = host_dir.handle,
                .kind = .dir,
            },
        });
    }

    pub fn addPreopenPath(self: *WasiContext, io: std.Io, wasi_fd: i32, guest_path: []const u8, host_path: []const u8) !void {
        const dir = if (std.fs.path.isAbsolute(host_path))
            try std.Io.Dir.cwd().openDir(io, host_path, .{ .iterate = true })
        else
            try std.Io.Dir.cwd().openDir(io, host_path, .{ .access_sub_paths = true, .iterate = true });
        errdefer {
            var owned = dir;
            owned.close(io);
        }
        try self.addPreopen(wasi_fd, guest_path, dir);
    }

    /// Register an existing host file descriptor as a preopened entry.
    pub fn addPreopenFd(self: *WasiContext, wasi_fd: i32, guest_path: []const u8, host_fd: std.posix.fd_t, kind: HandleKind, ownership: Ownership) !void {
        try self.preopens.append(self.alloc, .{
            .wasi_fd = wasi_fd,
            .path = guest_path,
            .host = .{ .raw = host_fd, .kind = kind },
            .ownership = ownership,
        });
    }

    /// Override a stdio file descriptor (0=stdin, 1=stdout, 2=stderr).
    pub fn setStdioFd(self: *WasiContext, fd: i32, host_fd: std.posix.fd_t, ownership: Ownership) void {
        const idx: usize = @intCast(fd);
        if (idx >= 3) return;
        // Close previous owned override if any
        if (self.stdio_handles[idx]) |prev| {
            if (self.stdio_ownership[idx] == .own) closeHandle(prev);
        }
        self.stdio_handles[idx] = host_fd;
        self.stdio_ownership[idx] = ownership;
    }

    /// Resolve a stdio fd (0-2) to a File, using override if set.
    pub fn stdioFile(self: *const WasiContext, fd: i32) ?std.Io.File {
        if (fd < 0 or fd > 2) return null;
        const idx: usize = @intCast(fd);
        if (self.stdio_handles[idx]) |handle| {
            return .{ .handle = handle, .flags = .{ .nonblocking = false } };
        }
        return defaultStdioFile(fd);
    }

    fn getHostHandle(self: *WasiContext, wasi_fd: i32) ?HostHandle {
        for (self.preopens.items) |p| {
            if (p.wasi_fd == wasi_fd and p.is_open) return p.host;
        }
        if (wasi_fd >= self.fd_base) {
            const idx: usize = @intCast(wasi_fd - self.fd_base);
            if (idx < self.fd_table.items.len and self.fd_table.items[idx].is_open) {
                return self.fd_table.items[idx].host;
            }
        }
        return null;
    }

    fn getHostFd(self: *WasiContext, wasi_fd: i32) ?std.posix.fd_t {
        if (self.stdioFile(wasi_fd)) |file| return file.handle;
        const host = self.getHostHandle(wasi_fd) orelse return null;
        return host.raw;
    }

    fn getFdEntry(self: *WasiContext, wasi_fd: i32) ?*FdEntry {
        if (wasi_fd < self.fd_base) return null;
        const idx: usize = @intCast(wasi_fd - self.fd_base);
        if (idx >= self.fd_table.items.len or !self.fd_table.items[idx].is_open) return null;
        return &self.fd_table.items[idx];
    }

    fn resolveFile(self: *WasiContext, wasi_fd: i32) ?std.Io.File {
        return if (self.stdioFile(wasi_fd)) |file|
            file
        else if (self.getHostHandle(wasi_fd)) |host|
            .{ .handle = host.raw, .flags = .{ .nonblocking = false } }
        else
            null;
    }

    fn resolveDir(self: *WasiContext, wasi_fd: i32) ?std.Io.Dir {
        const host = self.getHostHandle(wasi_fd) orelse return null;
        if (host.kind != .dir) return null;
        return .{ .handle = host.raw };
    }

    /// Allocate a new WASI fd. All preopens must be added before the first call.
    fn allocFd(self: *WasiContext, host: HostHandle, append: bool) !i32 {
        // Compute fd_base lazily (after all preopens are added)
        if (self.fd_base == 0) {
            var max_fd: i32 = 2; // stdio
            for (self.preopens.items) |p| {
                if (p.wasi_fd > max_fd) max_fd = p.wasi_fd;
            }
            self.fd_base = max_fd + 1;
        }
        // Reuse closed slot
        for (self.fd_table.items, 0..) |*entry, i| {
            if (!entry.is_open) {
                entry.* = .{
                    .host = host,
                    .append = append,
                };
                return self.fd_base + @as(i32, @intCast(i));
            }
        }
        // Append new entry
        const idx: i32 = @intCast(self.fd_table.items.len);
        try self.fd_table.append(self.alloc, .{
            .host = host,
            .append = append,
        });
        return self.fd_base + idx;
    }

    /// Close a dynamic fd. Returns false if fd is not a dynamic fd or already closed.
    fn closeFd(self: *WasiContext, wasi_fd: i32) bool {
        for (self.preopens.items) |*preopen| {
            if (preopen.wasi_fd == wasi_fd and preopen.is_open) {
                preopen.host.close();
                preopen.is_open = false;
                return true;
            }
        }

        const entry = self.getFdEntry(wasi_fd) orelse return false;
        entry.host.close();
        entry.is_open = false;
        entry.append = false;
        return true;
    }
};

// ============================================================
// Helper: get Vm from host function context
// ============================================================

inline fn getVm(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

inline fn getWasi(vm: *Vm) ?*WasiContext {
    const inst = vm.current_instance orelse return null;
    return inst.wasi;
}

fn pushErrno(vm: *Vm, errno: Errno) !void {
    try vm.pushOperand(@intFromEnum(errno));
}

/// Check if a capability is granted. Returns true if allowed.
inline fn hasCap(vm: *Vm, comptime field: std.meta.FieldEnum(Capabilities)) bool {
    const wasi = getWasi(vm) orelse return false;
    return @field(wasi.caps, @tagName(field));
}

/// Default stdio mapping (process stdin/stdout/stderr). Used as fallback
/// when no WasiContext is available or no override is set.
fn defaultStdioFile(fd: i32) ?std.Io.File {
    return switch (fd) {
        0 => std.Io.File.stdin(),
        1 => std.Io.File.stdout(),
        2 => std.Io.File.stderr(),
        else => null,
    };
}

fn wasiFiletypeFromKind(kind: std.Io.File.Kind) u8 {
    return switch (kind) {
        .directory => @intFromEnum(Filetype.DIRECTORY),
        .sym_link => @intFromEnum(Filetype.SYMBOLIC_LINK),
        .file => @intFromEnum(Filetype.REGULAR_FILE),
        .block_device => @intFromEnum(Filetype.BLOCK_DEVICE),
        .character_device => @intFromEnum(Filetype.CHARACTER_DEVICE),
        .named_pipe => @intFromEnum(Filetype.UNKNOWN),
        .unix_domain_socket => @intFromEnum(Filetype.SOCKET_STREAM),
        else => @intFromEnum(Filetype.UNKNOWN),
    };
}

fn wasiNanos(value: i128) u64 {
    const clamped: i64 = std.math.cast(i64, value) orelse blk: {
        break :blk if (value < 0) std.math.minInt(i64) else std.math.maxInt(i64);
    };
    return @bitCast(clamped);
}

// ============================================================
// WASI function implementations
// ============================================================

/// args_sizes_get(argc_ptr: i32, argv_buf_size_ptr: i32) -> errno
pub fn args_sizes_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const argv_buf_size_ptr = vm.popOperandU32();
    const argc_ptr = vm.popOperandU32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const memory = try vm.getMemory(0);
    const argc: u32 = @intCast(wasi.args.len);
    try memory.write(u32, argc_ptr, 0, argc);

    var buf_size: u32 = 0;
    for (wasi.args) |arg| {
        buf_size += @intCast(arg.len + 1);
    }
    try memory.write(u32, argv_buf_size_ptr, 0, buf_size);

    try pushErrno(vm, .SUCCESS);
}

/// args_get(argv_ptr: i32, argv_buf_ptr: i32) -> errno
pub fn args_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const argv_buf_ptr = vm.popOperandU32();
    const argv_ptr = vm.popOperandU32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var buf_offset: u32 = 0;
    for (wasi.args, 0..) |arg, i| {
        // Write pointer at argv[i]
        try memory.write(u32, argv_ptr, @as(u32, @intCast(i)) * 4, argv_buf_ptr + buf_offset);
        // Copy arg string + null terminator
        const dest_start = argv_buf_ptr + buf_offset;
        const arg_len: u32 = @intCast(arg.len);
        if (dest_start + arg_len + 1 > data.len) return error.OutOfBoundsMemoryAccess;
        @memcpy(data[dest_start .. dest_start + arg_len], arg[0..arg_len]);
        data[dest_start + arg_len] = 0;
        buf_offset += arg_len + 1;
    }

    try pushErrno(vm, .SUCCESS);
}

/// environ_sizes_get(count_ptr: i32, buf_size_ptr: i32) -> errno
pub fn environ_sizes_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const buf_size_ptr = vm.popOperandU32();
    const count_ptr = vm.popOperandU32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    // Allow access if allow_env is set OR there are explicitly injected env vars
    if (!hasCap(vm, .allow_env) and wasi.environ_keys.items.len == 0)
        return pushErrno(vm, .ACCES);

    const memory = try vm.getMemory(0);
    const count: u32 = @intCast(wasi.environ_keys.items.len);
    try memory.write(u32, count_ptr, 0, count);

    var buf_size: u32 = 0;
    for (wasi.environ_keys.items, wasi.environ_vals.items) |key, val| {
        buf_size += @intCast(key.len + 1 + val.len + 1); // "KEY=val\0"
    }
    try memory.write(u32, buf_size_ptr, 0, buf_size);

    try pushErrno(vm, .SUCCESS);
}

/// environ_get(environ_ptr: i32, environ_buf_ptr: i32) -> errno
pub fn environ_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const environ_buf_ptr = vm.popOperandU32();
    const environ_ptr = vm.popOperandU32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    // Allow access if allow_env is set OR there are explicitly injected env vars
    if (!hasCap(vm, .allow_env) and wasi.environ_keys.items.len == 0)
        return pushErrno(vm, .ACCES);

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var buf_offset: u32 = 0;
    for (wasi.environ_keys.items, wasi.environ_vals.items, 0..) |key, val, i| {
        try memory.write(u32, environ_ptr, @as(u32, @intCast(i)) * 4, environ_buf_ptr + buf_offset);

        const dest = environ_buf_ptr + buf_offset;
        const total_len: u32 = @intCast(key.len + 1 + val.len + 1);
        if (dest + total_len > data.len) return error.OutOfBoundsMemoryAccess;

        @memcpy(data[dest .. dest + key.len], key);
        data[dest + @as(u32, @intCast(key.len))] = '=';
        const val_start = dest + @as(u32, @intCast(key.len)) + 1;
        @memcpy(data[val_start .. val_start + val.len], val);
        data[val_start + @as(u32, @intCast(val.len))] = 0;
        buf_offset += total_len;
    }

    try pushErrno(vm, .SUCCESS);
}

/// clock_time_get(clock_id: i32, precision: i64, time_ptr: i32) -> errno
pub fn clock_time_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const time_ptr = vm.popOperandU32();
    _ = vm.popOperandI64(); // precision (ignored)
    const clock_id = vm.popOperandU32();

    if (!hasCap(vm, .allow_clock)) return pushErrno(vm, .ACCES);

    const memory = try vm.getMemory(0);

    const ts: i128 = switch (@as(ClockId, @enumFromInt(clock_id))) {
        .REALTIME => blk: {
            const t = getNanoTimestamp();
            break :blk t;
        },
        .MONOTONIC, .PROCESS_CPUTIME, .THREAD_CPUTIME => blk: {
            const t = getNanoTimestamp();
            break :blk t;
        },
    };
    const nanos: u64 = @intCast(@as(u128, @bitCast(ts)) & 0xFFFFFFFFFFFFFFFF);
    try memory.write(u64, time_ptr, 0, nanos);

    try pushErrno(vm, .SUCCESS);
}

/// fd_close(fd: i32) -> errno
pub fn fd_close(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fd = vm.popOperandI32();

    // stdio fds: return SUCCESS without closing (matches wasmtime behavior)
    if (fd >= 0 and fd <= 2) {
        try pushErrno(vm, .SUCCESS);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    // Try dynamic fd_table first
    if (wasi.closeFd(fd)) {
        try pushErrno(vm, .SUCCESS);
        return;
    }

    try pushErrno(vm, .BADF);
}

/// fd_fdstat_get(fd: i32, stat_ptr: i32) -> errno
pub fn fd_fdstat_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const stat_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    // fdstat struct: filetype(u8) + padding(u8) + flags(u16) + rights_base(u64) + rights_inheriting(u64) = 24 bytes
    if (stat_ptr + 24 > data.len) return error.OutOfBoundsMemoryAccess;

    // Zero-fill then set filetype
    @memset(data[stat_ptr .. stat_ptr + 24], 0);

    const filetype: u8 = if (fd >= 0 and fd <= 2)
        @intFromEnum(Filetype.CHARACTER_DEVICE)
    else if (getWasi(vm)) |wasi| blk: {
        const host = wasi.getHostHandle(fd) orelse break :blk @intFromEnum(Filetype.UNKNOWN);
        if (host.kind == .dir) break :blk @intFromEnum(Filetype.DIRECTORY);
        const stat = host.stat(wasi.io) catch break :blk @intFromEnum(Filetype.UNKNOWN);
        break :blk wasiFiletypeFromKind(stat.kind);
    } else @intFromEnum(Filetype.UNKNOWN);
    data[stat_ptr] = filetype;

    // Set full rights
    const all_rights: u64 = 0x1FFFFFFF;
    try memory.write(u64, stat_ptr, 8, all_rights); // rights_base
    try memory.write(u64, stat_ptr, 16, all_rights); // rights_inheriting

    try pushErrno(vm, .SUCCESS);
}

/// fd_filestat_get(fd: i32, filestat_ptr: i32) -> errno
pub fn fd_filestat_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const filestat_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm);
    const file = if (wasi) |w| w.resolveFile(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (defaultStdioFile(fd)) |stdio| stdio else {
        try pushErrno(vm, .BADF);
        return;
    };
    const io = wasi.?.io;

    const stat = file.stat(io) catch {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    try writeFilestat(memory, filestat_ptr, stat);
    try pushErrno(vm, .SUCCESS);
}

/// fd_prestat_get(fd: i32, prestat_ptr: i32) -> errno
pub fn fd_prestat_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const prestat_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    for (wasi.preopens.items) |p| {
        if (p.wasi_fd == fd) {
            const memory = try vm.getMemory(0);
            // prestat: tag(u32) = 0 (dir) + name_len(u32)
            try memory.write(u32, prestat_ptr, 0, 0); // tag = dir
            try memory.write(u32, prestat_ptr, 4, @intCast(p.path.len));
            try pushErrno(vm, .SUCCESS);
            return;
        }
    }

    try pushErrno(vm, .BADF);
}

/// fd_prestat_dir_name(fd: i32, path_ptr: i32, path_len: i32) -> errno
pub fn fd_prestat_dir_name(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    for (wasi.preopens.items) |p| {
        if (p.wasi_fd == fd) {
            const memory = try vm.getMemory(0);
            const data = memory.memory();
            const copy_len = @min(path_len, @as(u32, @intCast(p.path.len)));
            if (path_ptr + copy_len > data.len) return error.OutOfBoundsMemoryAccess;
            @memcpy(data[path_ptr .. path_ptr + copy_len], p.path[0..copy_len]);
            try pushErrno(vm, .SUCCESS);
            return;
        }
    }

    try pushErrno(vm, .BADF);
}

/// fd_read(fd: i32, iovs_ptr: i32, iovs_len: i32, nread_ptr: i32) -> errno
pub fn fd_read(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const nread_ptr = vm.popOperandU32();
    const iovs_len = vm.popOperandU32();
    const iovs_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (fd >= 0 and fd <= 2) {
        if (!hasCap(vm, .allow_stdio)) return pushErrno(vm, .ACCES);
    } else {
        if (!hasCap(vm, .allow_read)) return pushErrno(vm, .ACCES);
    }

    const wasi = getWasi(vm);
    const file = if (wasi) |w| w.resolveFile(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (defaultStdioFile(fd)) |stdio| stdio else {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var total: u32 = 0;
    for (0..iovs_len) |i| {
        const offset: u32 = @intCast(i * 8);
        const iov_ptr = try memory.read(u32, iovs_ptr, offset);
        const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
        if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

        const buf = data[iov_ptr .. iov_ptr + iov_len];
        const n = std.posix.system.read(file.handle, buf.ptr, buf.len);
        if (n < 0) {
            try pushErrno(vm, .IO);
            return;
        }
        const n_usize: usize = @intCast(n);
        total += @intCast(n_usize);
        if (n_usize < buf.len) break;
    }

    try memory.write(u32, nread_ptr, 0, total);
    try pushErrno(vm, .SUCCESS);
}

/// fd_seek(fd: i32, offset: i64, whence: i32, newoffset_ptr: i32) -> errno
pub fn fd_seek(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const newoffset_ptr = vm.popOperandU32();
    const whence_val = vm.popOperandU32();
    const offset = vm.popOperandI64();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_read)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm);
    const file = if (wasi) |w| w.resolveFile(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (fd >= 0 and fd <= 2) {
        try pushErrno(vm, .SPIPE);
        return;
    } else {
        try pushErrno(vm, .BADF);
        return;
    };

    const whence_enum = @as(Whence, @enumFromInt(whence_val));
    const new_pos = blk: {
        const current = std.posix.system.lseek(file.handle, 0, std.posix.SEEK.CUR);
        if (current == -1) {
            try pushErrno(vm, .INVAL);
            return;
        }
        const end = std.posix.system.lseek(file.handle, 0, std.posix.SEEK.END);
        if (end == -1) {
            try pushErrno(vm, .INVAL);
            return;
        }
        const current_i64: i64 = @intCast(current);
        const end_i64: i64 = @intCast(end);
        const seek_pos: i64 = switch (whence_enum) {
            .SET => @bitCast(offset),
            .CUR => current_i64 + offset,
            .END => end_i64 + offset,
        };
        if (seek_pos < 0) {
            try pushErrno(vm, .INVAL);
            return;
        }
        const lseek_result = std.posix.system.lseek(file.handle, seek_pos, std.posix.SEEK.SET);
        if (lseek_result == -1) {
            try pushErrno(vm, .INVAL);
            return;
        }
        break :blk @as(u64, @intCast(seek_pos));
    };

    const memory = try vm.getMemory(0);
    try memory.write(u64, newoffset_ptr, 0, new_pos);
    try pushErrno(vm, .SUCCESS);
}

/// fd_write(fd: i32, iovs_ptr: i32, iovs_len: i32, nwritten_ptr: i32) -> errno
pub fn fd_write(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const nwritten_ptr = vm.popOperandU32();
    const iovs_len = vm.popOperandU32();
    const iovs_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (fd >= 0 and fd <= 2) {
        if (!hasCap(vm, .allow_stdio)) return pushErrno(vm, .ACCES);
    } else {
        if (!hasCap(vm, .allow_write)) return pushErrno(vm, .ACCES);
    }

    const wasi = getWasi(vm);
    const file = if (wasi) |w| w.resolveFile(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (defaultStdioFile(fd)) |stdio| stdio else {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var total: u32 = 0;
    for (0..iovs_len) |i| {
        const offset: u32 = @intCast(i * 8);
        const iov_ptr = try memory.read(u32, iovs_ptr, offset);
        const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
        if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

        if (wasi) |w| {
            if (w.getFdEntry(fd)) |entry| {
                if (entry.append) {
                    const lseek_append = std.posix.system.lseek(file.handle, 0, std.posix.SEEK.END);
                    if (lseek_append == -1) {
                        try pushErrno(vm, .INVAL);
                        return;
                    }
                }
            }
        }

        const buf = data[iov_ptr .. iov_ptr + iov_len];
        const n = std.posix.system.write(file.handle, buf.ptr, buf.len);
        if (n < 0) {
            try pushErrno(vm, .IO);
            return;
        }
        const n_usize: usize = @intCast(n);
        total += @intCast(n_usize);
        if (n_usize < buf.len) break;
    }

    try memory.write(u32, nwritten_ptr, 0, total);
    try pushErrno(vm, .SUCCESS);
}

/// fd_tell(fd: i32, offset_ptr: i32) -> errno
pub fn fd_tell(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const offset_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_read)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm);
    const file = if (wasi) |w| w.resolveFile(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    } else if (fd >= 0 and fd <= 2) {
        try pushErrno(vm, .SPIPE);
        return;
    } else {
        try pushErrno(vm, .BADF);
        return;
    };

    const cur = std.posix.system.lseek(file.handle, 0, std.posix.SEEK.CUR);
    if (cur == -1) {
        try pushErrno(vm, .SPIPE);
        return;
    }

    const memory = try vm.getMemory(0);
    try memory.write(u64, offset_ptr, 0, @bitCast(cur));
    try pushErrno(vm, .SUCCESS);
}

/// fd_readdir(fd: i32, buf_ptr: i32, buf_len: i32, cookie: i64, bufused_ptr: i32) -> errno
pub fn fd_readdir(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const bufused_ptr = vm.popOperandU32();
    const cookie = vm.popOperandI64();
    const buf_len = vm.popOperandU32();
    const buf_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_read)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;

    var dir = wasi.resolveDir(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (buf_ptr + buf_len > data.len) return error.OutOfBoundsMemoryAccess;

    var iter = dir.iterate();

    // Skip entries up to cookie
    var idx: i64 = 0;
    while (idx < cookie) : (idx += 1) {
        _ = iter.next(io) catch {
            try memory.write(u32, bufused_ptr, 0, 0);
            try pushErrno(vm, .SUCCESS);
            return;
        };
    }

    // Fill buffer with dirent entries
    // WASI dirent: d_next(u64) + d_ino(u64) + d_namlen(u32) + d_type(u8) = 24 bytes header + name
    var bufused: u32 = 0;
    const DIRENT_HDR: u32 = 24;
    while (true) {
        const entry = iter.next(io) catch break;
        if (entry == null) break;
        const e = entry.?;
        const name = e.name;
        const name_len: u32 = @intCast(name.len);
        const entry_size = DIRENT_HDR + name_len;

        // Check if entry fits in remaining buffer
        if (bufused + entry_size > buf_len) {
            // Partially write header if we have room for at least the header
            if (bufused + DIRENT_HDR <= buf_len) {
                const off = buf_ptr + bufused;
                idx += 1;
                mem.writeInt(u64, data[off..][0..8], @bitCast(idx), .little); // d_next
                mem.writeInt(u64, data[off + 8 ..][0..8], 0, .little); // d_ino
                mem.writeInt(u32, data[off + 16 ..][0..4], name_len, .little); // d_namlen
                data[off + 20] = wasiFiletype(e.kind); // d_type
                // Partial name copy
                const avail = buf_len - bufused - DIRENT_HDR;
                if (avail > 0) @memcpy(data[off + DIRENT_HDR .. off + DIRENT_HDR + avail], name[0..avail]);
                bufused = buf_len;
            }
            break;
        }

        const off = buf_ptr + bufused;
        idx += 1;
        mem.writeInt(u64, data[off..][0..8], @bitCast(idx), .little); // d_next
        mem.writeInt(u64, data[off + 8 ..][0..8], 0, .little); // d_ino (unknown)
        mem.writeInt(u32, data[off + 16 ..][0..4], name_len, .little); // d_namlen
        data[off + 20] = wasiFiletype(e.kind); // d_type
        @memcpy(data[off + DIRENT_HDR .. off + DIRENT_HDR + name_len], name[0..name_len]);
        bufused += entry_size;
    }

    try memory.write(u32, bufused_ptr, 0, bufused);
    try pushErrno(vm, .SUCCESS);
}

/// Convert WASI fst_flags + timestamps to posix timespec pair [atime, mtime].
/// fst_flags: ATIM=0x01, ATIM_NOW=0x02, MTIM=0x04, MTIM_NOW=0x08
fn wasiTimesToTimespec(fst_flags: u32, atim_ns: i64, mtim_ns: i64) [2]std.posix.timespec {
    const UTIME_NOW: isize = (1 << 30) - 1;
    const UTIME_OMIT: isize = (1 << 30) - 2;
    var times: [2]std.posix.timespec = undefined;

    if (fst_flags & 0x02 != 0) {
        // ATIM_NOW
        times[0] = .{ .sec = 0, .nsec = UTIME_NOW };
    } else if (fst_flags & 0x01 != 0) {
        // ATIM — use provided value
        times[0] = .{ .sec = @intCast(@divTrunc(atim_ns, 1_000_000_000)), .nsec = @intCast(@mod(atim_ns, 1_000_000_000)) };
    } else {
        times[0] = .{ .sec = 0, .nsec = UTIME_OMIT };
    }

    if (fst_flags & 0x08 != 0) {
        // MTIM_NOW
        times[1] = .{ .sec = 0, .nsec = UTIME_NOW };
    } else if (fst_flags & 0x04 != 0) {
        // MTIM — use provided value
        times[1] = .{ .sec = @intCast(@divTrunc(mtim_ns, 1_000_000_000)), .nsec = @intCast(@mod(mtim_ns, 1_000_000_000)) };
    } else {
        times[1] = .{ .sec = 0, .nsec = UTIME_OMIT };
    }

    return times;
}

fn wasiTimestamp(fst_flags: u32, set_bit: u32, now_bit: u32, provided_ns: i64, fallback_ns: i128) i128 {
    if (fst_flags & now_bit != 0) return getNanoTimestamp();
    if (fst_flags & set_bit != 0) return provided_ns;
    return fallback_ns;
}

/// Write a WASI filestat struct (64 bytes) from a portable file stat to memory.
fn writeFilestat(memory: *WasmMemory, ptr: u32, stat: std.Io.File.Stat) !void {
    const data = memory.memory();
    if (ptr + 64 > data.len) return error.OutOfBoundsMemoryAccess;
    @memset(data[ptr .. ptr + 64], 0);
    // dev(u64)=0, ino(u64)=8, filetype(u8)=16, pad=17..23, nlink(u64)=24, size(u64)=32, atim(u64)=40, mtim(u64)=48, ctim(u64)=56
    try memory.write(u64, ptr, 8, @intCast(stat.inode));
    data[ptr + 16] = wasiFiletypeFromKind(stat.kind);
    try memory.write(u64, ptr, 24, @intCast(stat.nlink));
    try memory.write(u64, ptr, 32, stat.size);
    const atime = stat.atime orelse std.Io.Timestamp.zero;
    try memory.write(u64, ptr, 40, @bitCast(@as(i64, @intCast(atime.nanoseconds))));
    try memory.write(u64, ptr, 48, @bitCast(@as(i64, @intCast(stat.mtime.nanoseconds))));
    try memory.write(u64, ptr, 56, @bitCast(@as(i64, @intCast(stat.ctime.nanoseconds))));
}

fn wasiFiletype(kind: std.Io.File.Kind) u8 {
    return switch (kind) {
        .directory => @intFromEnum(Filetype.DIRECTORY),
        .sym_link => @intFromEnum(Filetype.SYMBOLIC_LINK),
        .file => @intFromEnum(Filetype.REGULAR_FILE),
        .block_device => @intFromEnum(Filetype.BLOCK_DEVICE),
        .character_device => @intFromEnum(Filetype.CHARACTER_DEVICE),
        else => @intFromEnum(Filetype.UNKNOWN),
    };
}

/// path_filestat_get(fd: i32, flags: i32, path_ptr: i32, path_len: i32, filestat_ptr: i32) -> errno
pub fn path_filestat_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const filestat_ptr = vm.popOperandU32();
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const flags = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;

    var dir = wasi.resolveDir(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;

    const path = data[path_ptr .. path_ptr + path_len];
    const stat = dir.statFile(io, path, .{ .follow_symlinks = flags & 0x01 != 0 }) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try writeFilestat(memory, filestat_ptr, stat);
    try pushErrno(vm, .SUCCESS);
}

/// path_open(fd:i32, dirflags:i32, path_ptr:i32, path_len:i32, oflags:i32, rights_base:i64, rights_inh:i64, fdflags:i32, opened_fd_ptr:i32) -> errno
pub fn path_open(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const opened_fd_ptr = vm.popOperandU32();
    const fdflags = vm.popOperandU32();
    _ = vm.popOperandI64(); // rights_inheriting
    _ = vm.popOperandI64(); // rights_base
    const oflags = vm.popOperandU32();
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const dirflags = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    var dir = wasi.resolveDir(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const path = data[path_ptr .. path_ptr + path_len];
    const dir_fd = dir.handle;

    if (builtin.os.tag == .windows) {
        const want_directory = oflags & 0x02 != 0;
        const want_create = oflags & 0x01 != 0;
        const want_exclusive = oflags & 0x04 != 0;
        const want_truncate = oflags & 0x08 != 0;
        const want_append = fdflags & 0x01 != 0;

        const new_fd = if (want_directory) blk: {
            const opened_dir = dir.openDir(path, .{
                .access_sub_paths = true,
                .iterate = true,
                .no_follow = dirflags & 0x01 == 0,
            }) catch |err| {
                try pushErrno(vm, toWasiErrno(err));
                return;
            };
            errdefer {
                var owned = opened_dir;
                owned.close();
            }
            break :blk wasi.allocFd(.{
                .raw = opened_dir.fd,
                .kind = .dir,
            }, false) catch {
                var owned = opened_dir;
                owned.close();
                try pushErrno(vm, .NOMEM);
                return;
            };
        } else blk: {
            var opened_file = if (want_create)
                dir.createFile(path, .{
                    .read = true,
                    .truncate = want_truncate,
                    .exclusive = want_exclusive,
                }) catch |err| {
                    try pushErrno(vm, toWasiErrno(err));
                    return;
                }
            else
                dir.openFile(path, .{ .mode = .read_write }) catch |err| {
                    try pushErrno(vm, toWasiErrno(err));
                    return;
                };
            errdefer opened_file.close();

            if (!want_create and want_truncate) {
                opened_file.setEndPos(0) catch |err| {
                    try pushErrno(vm, toWasiErrno(err));
                    return;
                };
            }

            break :blk wasi.allocFd(.{
                .raw = opened_file.handle,
                .kind = .file,
            }, want_append) catch {
                opened_file.close();
                try pushErrno(vm, .NOMEM);
                return;
            };
        };

        if (opened_fd_ptr + 4 > data.len) return error.OutOfBoundsMemoryAccess;
        mem.writeInt(u32, data[opened_fd_ptr..][0..4], @bitCast(new_fd), .little);
        try pushErrno(vm, .SUCCESS);
        return;
    }

    // Convert WASI oflags to posix flags
    var flags: posix.O = .{};
    if (oflags & 0x01 != 0) flags.CREAT = true; // __WASI_OFLAGS_CREAT
    if (oflags & 0x04 != 0) flags.EXCL = true; // __WASI_OFLAGS_EXCL
    if (oflags & 0x08 != 0) flags.TRUNC = true; // __WASI_OFLAGS_TRUNC
    if (oflags & 0x02 != 0) flags.DIRECTORY = true; // __WASI_OFLAGS_DIRECTORY

    // Convert WASI fdflags
    if (fdflags & 0x01 != 0) flags.APPEND = true; // __WASI_FDFLAGS_APPEND
    if (fdflags & 0x04 != 0) flags.NONBLOCK = true; // __WASI_FDFLAGS_NONBLOCK
    // DSYNC (0x02) and RSYNC (0x08) and SYNC (0x10) — mapped to SYNC if any set
    if (fdflags & 0x12 != 0) flags.SYNC = true;

    // WASI SYMLINK_FOLLOW in dirflags (bit 0)
    if (dirflags & 0x01 == 0) flags.NOFOLLOW = true;

    // Default to RDWR; for directories, use RDONLY
    if (!flags.DIRECTORY) {
        flags.ACCMODE = .RDWR;
    }

    const host_fd = posix.openat(dir_fd, path, flags, 0o666) catch |err| {
        // If RDWR fails with ISDIR, retry as RDONLY
        if (err == error.IsDir) {
            const ro_flags = blk: {
                var f = flags;
                f.ACCMODE = .RDONLY;
                break :blk f;
            };
            const ro_fd = posix.openat(dir_fd, path, ro_flags, 0o666) catch |err2| {
                try pushErrno(vm, toWasiErrno(err2));
                return;
            };
            const new_fd = wasi.allocFd(.{
                .raw = ro_fd,
                .kind = if (flags.DIRECTORY) .dir else .file,
            }, flags.APPEND) catch {
                std.Io.Threaded.closeFd(ro_fd);
                try pushErrno(vm, .NOMEM);
                return;
            };
            // Write new fd to memory
            if (opened_fd_ptr + 4 > data.len) return error.OutOfBoundsMemoryAccess;
            mem.writeInt(u32, data[opened_fd_ptr..][0..4], @bitCast(new_fd), .little);
            try pushErrno(vm, .SUCCESS);
            return;
        }
        try pushErrno(vm, toWasiErrno(err));
        return;
    };

    const new_fd = wasi.allocFd(.{
        .raw = host_fd,
        .kind = if (flags.DIRECTORY) .dir else .file,
    }, flags.APPEND) catch {
        std.Io.Threaded.closeFd(host_fd);
        try pushErrno(vm, .NOMEM);
        return;
    };

    // Write new fd to memory
    if (opened_fd_ptr + 4 > data.len) return error.OutOfBoundsMemoryAccess;
    mem.writeInt(u32, data[opened_fd_ptr..][0..4], @bitCast(new_fd), .little);
    try pushErrno(vm, .SUCCESS);
}

/// proc_exit(exit_code: i32) -> noreturn (via Trap)
pub fn proc_exit(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const exit_code = vm.popOperandU32();

    if (!hasCap(vm, .allow_proc_exit)) return pushErrno(vm, .ACCES);

    if (getWasi(vm)) |wasi| {
        wasi.exit_code = exit_code;
    }
    return error.Trap;
}

/// random_get(buf_ptr: i32, buf_len: i32) -> errno
pub fn random_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;

    const buf_len = vm.popOperandU32();
    const buf_ptr = vm.popOperandU32();

    if (!hasCap(vm, .allow_random)) return pushErrno(vm, .ACCES);

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    if (buf_ptr + buf_len > data.len) return error.OutOfBoundsMemoryAccess;

    io.random(data[buf_ptr .. buf_ptr + buf_len]);

    try pushErrno(vm, .SUCCESS);
}

/// clock_res_get(clock_id: i32, resolution_ptr: i32) -> errno
pub fn clock_res_get(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const resolution_ptr = vm.popOperandU32();
    const clock_id = vm.popOperandU32();

    if (!hasCap(vm, .allow_clock)) return pushErrno(vm, .ACCES);

    const memory = try vm.getMemory(0);

    // Return nanosecond resolution for all clocks
    const resolution: u64 = switch (@as(ClockId, @enumFromInt(clock_id))) {
        .REALTIME => 1_000, // microsecond resolution
        .MONOTONIC => 1, // nanosecond resolution
        .PROCESS_CPUTIME, .THREAD_CPUTIME => 1_000, // microsecond resolution
    };
    try memory.write(u64, resolution_ptr, 0, resolution);

    try pushErrno(vm, .SUCCESS);
}

/// fd_datasync(fd: i32) -> errno
pub fn fd_datasync(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_write)) return pushErrno(vm, .ACCES);

    if (fd <= 2) {
        try pushErrno(vm, .INVAL);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    if (wasi.getHostFd(fd)) |host_fd| {
        posix.fdatasync(host_fd) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };
        try pushErrno(vm, .SUCCESS);
    } else {
        try pushErrno(vm, .BADF);
    }
}

/// fd_sync(fd: i32) -> errno
pub fn fd_sync(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_write)) return pushErrno(vm, .ACCES);

    if (fd <= 2) {
        try pushErrno(vm, .INVAL);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    if (wasi.getHostFd(fd)) |host_fd| {
        const result = std.posix.system.fsync(host_fd);
        if (result != 0) {
            try pushErrno(vm, .IO);
            return;
        }
        try pushErrno(vm, .SUCCESS);
    } else {
        try pushErrno(vm, .BADF);
    }
}

/// path_create_directory(fd: i32, path_ptr: i32, path_len: i32) -> errno
pub fn path_create_directory(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const path = data[path_ptr .. path_ptr + path_len];

    var dir = std.Io.Dir{ .handle = host_fd };
    dir.createDir(io, path, .default_dir) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try pushErrno(vm, .SUCCESS);
}

/// path_remove_directory(fd: i32, path_ptr: i32, path_len: i32) -> errno
pub fn path_remove_directory(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const path = data[path_ptr .. path_ptr + path_len];

    var dir = std.Io.Dir{ .handle = host_fd };
    dir.deleteDir(io, path) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try pushErrno(vm, .SUCCESS);
}

/// path_unlink_file(fd: i32, path_ptr: i32, path_len: i32) -> errno
pub fn path_unlink_file(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const path = data[path_ptr .. path_ptr + path_len];

    var dir = std.Io.Dir{ .handle = host_fd };
    dir.deleteFile(io, path) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try pushErrno(vm, .SUCCESS);
}

/// path_rename(fd: i32, old_path_ptr: i32, old_path_len: i32, new_fd: i32, new_path_ptr: i32, new_path_len: i32) -> errno
pub fn path_rename(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const new_path_len = vm.popOperandU32();
    const new_path_ptr = vm.popOperandU32();
    const new_fd = vm.popOperandI32();
    const old_path_len = vm.popOperandU32();
    const old_path_ptr = vm.popOperandU32();
    const old_fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;

    const old_host_fd = wasi.getHostFd(old_fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };
    const new_host_fd = wasi.getHostFd(new_fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (old_path_ptr + old_path_len > data.len) return error.OutOfBoundsMemoryAccess;
    if (new_path_ptr + new_path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const old_path = data[old_path_ptr .. old_path_ptr + old_path_len];
    const new_path = data[new_path_ptr .. new_path_ptr + new_path_len];

    var old_dir = std.Io.Dir{ .handle = old_host_fd };
    const new_dir = std.Io.Dir{ .handle = new_host_fd };
    old_dir.rename(old_path, new_dir, new_path, io) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try pushErrno(vm, .SUCCESS);
}

/// sched_yield() -> errno
pub fn sched_yield(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    // Trivial yield — just return success
    // On most platforms, a simple yield is a no-op for single-threaded Wasm
    try pushErrno(vm, .SUCCESS);
}

/// poll_oneoff(in_ptr: i32, out_ptr: i32, nsubscriptions: i32, nevents_ptr: i32) -> errno
/// Simplified: handles CLOCK subscriptions (sleep), FD subscriptions return immediately.
pub fn poll_oneoff(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;
    const nevents_ptr = vm.popOperandU32();
    const nsubscriptions = vm.popOperandU32();
    const out_ptr = vm.popOperandU32();
    const in_ptr = vm.popOperandU32();

    if (nsubscriptions == 0) {
        try pushErrno(vm, .INVAL);
        return;
    }

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    // subscription = 48 bytes, event = 32 bytes
    if (in_ptr + nsubscriptions * 48 > data.len) return error.OutOfBoundsMemoryAccess;
    if (out_ptr + nsubscriptions * 32 > data.len) return error.OutOfBoundsMemoryAccess;

    var nevents: u32 = 0;
    for (0..nsubscriptions) |i| {
        const sub_off: u32 = in_ptr + @as(u32, @intCast(i)) * 48;
        const evt_off: u32 = out_ptr + nevents * 32;

        // subscription: userdata(u64) at +0, tag(u8) at +8
        const userdata = try memory.read(u64, sub_off, 0);
        const tag = data[sub_off + 8];

        // Clear event
        @memset(data[evt_off .. evt_off + 32], 0);
        // event: userdata(u64) at +0, error(u16) at +8, type(u8) at +10
        try memory.write(u64, evt_off, 0, userdata);
        data[evt_off + 10] = tag;

        if (tag == 0) {
            // CLOCK subscription
            // clock: id(u32) at +16, timeout(u64) at +24, precision(u64) at +32, flags(u16) at +40
            const timeout = try memory.read(u64, sub_off, 24);
            const clock_flags = try memory.read(u16, sub_off, 40);

            if (clock_flags & 0x01 != 0) {
                // ABSTIME: compute relative from current time
                const now_ns = @as(u64, @bitCast(@as(i64, @intCast(getNanoTimestamp()))));
                if (timeout > now_ns) {
                    _ = std.Thread.yield() catch {};
                    try io.sleep(.fromNanoseconds(timeout - now_ns), .awake);
                }
            } else {
                try io.sleep(.fromNanoseconds(timeout), .awake);
            }
            // error = SUCCESS (0, already zeroed)
        } else {
            // FD_READ (1) or FD_WRITE (2) — return immediately as ready
            // error = SUCCESS (already zeroed), nbytes = 0
        }
        nevents += 1;
    }

    try memory.write(u32, nevents_ptr, 0, nevents);
    try pushErrno(vm, .SUCCESS);
}

/// fd_advise(fd: i32, offset: i64, len: i64, advice: i32) -> errno
pub fn fd_advise(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // advice
    _ = vm.popOperandI64(); // len
    _ = vm.popOperandI64(); // offset
    _ = vm.popOperandI32(); // fd
    // Advisory only — no-op is valid
    try pushErrno(vm, .SUCCESS);
}

/// fd_allocate(fd: i32, offset: i64, len: i64) -> errno
pub fn fd_allocate(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandI64(); // len
    _ = vm.popOperandI64(); // offset
    _ = vm.popOperandI32(); // fd
    if (!hasCap(vm, .allow_write)) return pushErrno(vm, .ACCES);
    // fallocate not portable — stub as NOSYS
    try pushErrno(vm, .NOSYS);
}

/// fd_fdstat_set_flags(fd: i32, flags: i32) -> errno
pub fn fd_fdstat_set_flags(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fdflags = vm.popOperandU32();
    const fd = vm.popOperandI32();
    if (!hasCap(vm, .allow_write)) return pushErrno(vm, .ACCES);

    if (builtin.os.tag == .windows) {
        const wasi = getWasi(vm) orelse {
            try pushErrno(vm, .NOSYS);
            return;
        };
        if (fd >= 0 and fd <= 2) {
            try pushErrno(vm, .SUCCESS);
            return;
        }
        if (wasi.getFdEntry(fd)) |entry| {
            entry.append = fdflags & 0x01 != 0;
            try pushErrno(vm, .SUCCESS);
            return;
        }
        if (wasi.getHostHandle(fd) != null) {
            try pushErrno(vm, .SUCCESS);
            return;
        }
        try pushErrno(vm, .BADF);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    // WASI fdflags: APPEND=0x01, DSYNC=0x02, NONBLOCK=0x04, RSYNC=0x08, SYNC=0x10
    var os_flags: u32 = 0;
    if (fdflags & 0x01 != 0) os_flags |= @as(u32, @bitCast(posix.O{ .APPEND = true }));
    if (fdflags & 0x04 != 0) os_flags |= @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    if (fdflags & 0x10 != 0) os_flags |= @as(u32, @bitCast(posix.O{ .SYNC = true }));

    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.fcntl(host_fd, linux.F.SETFL, @as(usize, os_flags));
        if (posix.errno(rc) != .SUCCESS) {
            try pushErrno(vm, .IO);
            return;
        }
    } else {
        const rc = std.c.fcntl(host_fd, std.c.F.SETFL, os_flags);
        if (rc < 0) {
            try pushErrno(vm, .IO);
            return;
        }
    }
    try pushErrno(vm, .SUCCESS);
}

/// fd_filestat_set_size(fd: i32, size: i64) -> errno
pub fn fd_filestat_set_size(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const size = vm.popOperandI64();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_write)) return pushErrno(vm, .ACCES);

    if (fd <= 2) {
        try pushErrno(vm, .INVAL);
        return;
    }

    if (builtin.os.tag == .windows) {
        const wasi = getWasi(vm) orelse {
            try pushErrno(vm, .NOSYS);
            return;
        };
        const file = wasi.resolveFile(fd) orelse {
            try pushErrno(vm, .BADF);
            return;
        };
        file.setEndPos(@bitCast(size)) catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };
        try pushErrno(vm, .SUCCESS);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    if (wasi.getHostFd(fd)) |host_fd| {
        const result = std.posix.system.ftruncate(host_fd, @bitCast(size));
        if (result != 0) {
            try pushErrno(vm, .INVAL);
            return;
        }
        try pushErrno(vm, .SUCCESS);
    } else {
        try pushErrno(vm, .BADF);
    }
}

/// fd_filestat_set_times(fd: i32, atim: i64, mtim: i64, fst_flags: i32) -> errno
pub fn fd_filestat_set_times(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fst_flags = vm.popOperandU32();
    const mtim_ns = vm.popOperandI64();
    const atim_ns = vm.popOperandI64();
    const fd = vm.popOperandI32();
    if (!hasCap(vm, .allow_write)) return pushErrno(vm, .ACCES);

    if (builtin.os.tag == .windows) {
        const wasi = getWasi(vm) orelse {
            try pushErrno(vm, .NOSYS);
            return;
        };
        const file = wasi.resolveFile(fd) orelse if (defaultStdioFile(fd)) |stdio| stdio else {
            try pushErrno(vm, .BADF);
            return;
        };
        var stat_buf: std.c.struct_stat = undefined;
        const fstat_result = std.posix.system.fstat(file.handle, &stat_buf);
        if (fstat_result != 0) {
            try pushErrno(vm, .BADF);
            return;
        }
        // Note: File time updates on Windows require SetFileTime() API.
        // For now, we skip this on Windows and return success.
        try pushErrno(vm, .SUCCESS);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const times = wasiTimesToTimespec(fst_flags, atim_ns, mtim_ns);
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.futimens(host_fd, &times);
        if (rc != 0) {
            try pushErrno(vm, .INVAL);
            return;
        }
    } else {
        if (std.c.futimens(host_fd, &times) < 0) {
            try pushErrno(vm, .IO);
            return;
        }
    }
    try pushErrno(vm, .SUCCESS);
}

/// fd_pread(fd: i32, iovs_ptr: i32, iovs_len: i32, offset: i64, nread_ptr: i32) -> errno
pub fn fd_pread(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const nread_ptr = vm.popOperandU32();
    const file_offset = vm.popOperandI64();
    const iovs_len = vm.popOperandU32();
    const iovs_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_read)) return pushErrno(vm, .ACCES);

    if (builtin.os.tag == .windows) {
        const wasi = getWasi(vm) orelse {
            try pushErrno(vm, .BADF);
            return;
        };
        const file = wasi.resolveFile(fd) orelse {
            try pushErrno(vm, .BADF);
            return;
        };

        const memory = try vm.getMemory(0);
        const data = memory.memory();
        var total: u32 = 0;
        var cur_offset: u64 = @bitCast(file_offset);
        for (0..iovs_len) |i| {
            const offset: u32 = @intCast(i * 8);
            const iov_ptr = try memory.read(u32, iovs_ptr, offset);
            const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
            if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

            const buf = data[iov_ptr .. iov_ptr + iov_len];
            const n = file.readPositional(buf, cur_offset) catch |err| {
                try pushErrno(vm, toWasiErrno(err));
                return;
            };
            total += @intCast(n);
            cur_offset += n;
            if (n < buf.len) break;
        }

        try memory.write(u32, nread_ptr, 0, total);
        try pushErrno(vm, .SUCCESS);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .BADF);
        return;
    };
    const host_fd: posix.fd_t = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();

    var total: u32 = 0;
    var cur_offset: u64 = @bitCast(file_offset);
    for (0..iovs_len) |i| {
        const offset: u32 = @intCast(i * 8);
        const iov_ptr = try memory.read(u32, iovs_ptr, offset);
        const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
        if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

        const buf = data[iov_ptr .. iov_ptr + iov_len];
        const n = std.posix.system.pread(host_fd, buf.ptr, buf.len, @bitCast(cur_offset));
        if (n < 0) {
            try pushErrno(vm, .IO);
            return;
        }
        const n_usize: usize = @intCast(n);
        total += @intCast(n_usize);
        cur_offset += @intCast(n_usize);
        if (n_usize < buf.len) break;
    }

    try memory.write(u32, nread_ptr, 0, total);
    try pushErrno(vm, .SUCCESS);
}

/// fd_pwrite(fd: i32, iovs_ptr: i32, iovs_len: i32, offset: i64, nwritten_ptr: i32) -> errno
pub fn fd_pwrite(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const nwritten_ptr = vm.popOperandU32();
    const file_offset = vm.popOperandI64();
    const iovs_len = vm.popOperandU32();
    const iovs_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_write)) return pushErrno(vm, .ACCES);

    if (builtin.os.tag == .windows) {
        const wasi = getWasi(vm) orelse {
            try pushErrno(vm, .BADF);
            return;
        };
        const file = wasi.resolveFile(fd) orelse {
            try pushErrno(vm, .BADF);
            return;
        };

        const memory = try vm.getMemory(0);
        const data = memory.memory();
        var total: u32 = 0;
        var cur_offset: u64 = @bitCast(file_offset);
        for (0..iovs_len) |i| {
            const offset: u32 = @intCast(i * 8);
            const iov_ptr = try memory.read(u32, iovs_ptr, offset);
            const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
            if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

            const buf = data[iov_ptr .. iov_ptr + iov_len];
            const n = std.posix.system.pwrite(file.handle, buf.ptr, buf.len, @bitCast(cur_offset));
            if (n < 0) {
                try pushErrno(vm, .IO);
                return;
            }
            const n_usize: usize = @intCast(n);
            total += @intCast(n_usize);
            cur_offset += n_usize;
            if (n_usize < buf.len) break;
        }

        try memory.write(u32, nwritten_ptr, 0, total);
        try pushErrno(vm, .SUCCESS);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .BADF);
        return;
    };
    const host_fd: posix.fd_t = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };
    const memory = try vm.getMemory(0);
    const data = memory.memory();
    var total: u32 = 0;
    var cur_offset: u64 = @bitCast(file_offset);
    for (0..iovs_len) |i| {
        const offset: u32 = @intCast(i * 8);
        const iov_ptr = try memory.read(u32, iovs_ptr, offset);
        const iov_len = try memory.read(u32, iovs_ptr, offset + 4);
        if (iov_ptr + iov_len > data.len) return error.OutOfBoundsMemoryAccess;

        const buf = data[iov_ptr .. iov_ptr + iov_len];
        const n = std.posix.system.pwrite(host_fd, buf.ptr, buf.len, @bitCast(cur_offset));
        if (n < 0) {
            try pushErrno(vm, .IO);
            return;
        }
        const n_usize: usize = @intCast(n);
        total += @intCast(n_usize);
        cur_offset += n_usize;
        if (n_usize < buf.len) break;
    }

    try memory.write(u32, nwritten_ptr, 0, total);
    try pushErrno(vm, .SUCCESS);
}

/// fd_renumber(fd_from: i32, fd_to: i32) -> errno
pub fn fd_renumber(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fd_to = vm.popOperandI32();
    const fd_from = vm.popOperandI32();

    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    if (builtin.os.tag == .windows) {
        const wasi = getWasi(vm) orelse {
            try pushErrno(vm, .NOSYS);
            return;
        };

        const from_host = wasi.getHostHandle(fd_from) orelse {
            try pushErrno(vm, .BADF);
            return;
        };
        const append = if (wasi.getFdEntry(fd_from)) |entry| entry.append else false;

        _ = wasi.closeFd(fd_to);
        const new_host = from_host.duplicate() catch |err| {
            try pushErrno(vm, toWasiErrno(err));
            return;
        };

        _ = wasi.closeFd(fd_from);

        if (fd_to >= wasi.fd_base) {
            const idx: usize = @intCast(fd_to - wasi.fd_base);
            if (idx < wasi.fd_table.items.len) {
                wasi.fd_table.items[idx] = .{ .host = new_host, .append = append };
            } else {
                while (wasi.fd_table.items.len < idx) {
                    wasi.fd_table.append(wasi.alloc, .{
                        .host = .{ .raw = undefined, .kind = .file }, // placeholder, never accessed
                        .is_open = false,
                    }) catch {
                        new_host.close();
                        try pushErrno(vm, .NOMEM);
                        return;
                    };
                }
                wasi.fd_table.append(wasi.alloc, .{ .host = new_host, .append = append }) catch {
                    new_host.close();
                    try pushErrno(vm, .NOMEM);
                    return;
                };
            }
        } else {
            new_host.close();
            try pushErrno(vm, .BADF);
            return;
        }

        try pushErrno(vm, .SUCCESS);
        return;
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    // Validate source fd exists
    const from_host = wasi.getHostFd(fd_from) orelse {
        try pushErrno(vm, .BADF);
        return;
    };
    const append = if (wasi.getFdEntry(fd_from)) |entry| entry.append else false;

    // Close destination fd if open
    _ = wasi.closeFd(fd_to);

    // Dup host fd and assign to fd_to slot
    const new_host = if (builtin.os.tag == .windows) unreachable else blk: {
        const fd = std.posix.system.dup(from_host);
        if (fd < 0) {
            try pushErrno(vm, .MFILE);
            return;
        }
        break :blk @as(std.posix.fd_t, @intCast(fd));
    };

    // Close old fd_from
    _ = wasi.closeFd(fd_from);

    // Assign new host fd to fd_to
    if (fd_to >= wasi.fd_base) {
        const idx: usize = @intCast(fd_to - wasi.fd_base);
        if (idx < wasi.fd_table.items.len) {
            wasi.fd_table.items[idx] = .{
                .host = .{ .raw = new_host, .kind = .file },
                .append = append,
            };
        } else {
            // Extend table to fit
            while (wasi.fd_table.items.len < idx) {
                wasi.fd_table.append(wasi.alloc, .{
                    .host = .{ .raw = undefined, .kind = .file }, // placeholder, never accessed
                    .is_open = false,
                }) catch {
                    std.Io.Threaded.closeFd(new_host);
                    try pushErrno(vm, .NOMEM);
                    return;
                };
            }
            wasi.fd_table.append(wasi.alloc, .{
                .host = .{ .raw = new_host, .kind = .file },
                .append = append,
            }) catch {
                std.Io.Threaded.closeFd(new_host);
                try pushErrno(vm, .NOMEM);
                return;
            };
        }
    } else {
        // Can't renumber to a preopened or stdio fd — just close new_host
        std.Io.Threaded.closeFd(new_host);
        try pushErrno(vm, .BADF);
        return;
    }

    try pushErrno(vm, .SUCCESS);
}

/// path_filestat_set_times(fd: i32, flags: i32, path_ptr: i32, path_len: i32, atim: i64, mtim: i64, fst_flags: i32) -> errno
pub fn path_filestat_set_times(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const fst_flags = vm.popOperandU32();
    const mtim_ns = vm.popOperandI64();
    const atim_ns = vm.popOperandI64();
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const flags = vm.popOperandU32();
    const fd = vm.popOperandI32();
    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    if (builtin.os.tag == .windows) {
        const wasi = getWasi(vm) orelse {
            try pushErrno(vm, .NOSYS);
            return;
        };
        var dir = wasi.resolveDir(fd) orelse {
            try pushErrno(vm, .BADF);
            return;
        };

        const memory = try vm.getMemory(0);
        const data = memory.memory();
        if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
        const path = data[path_ptr .. path_ptr + path_len];
        if (dir.openFile(path, .{ .mode = .read_write })) |file| {
            defer file.close();
            var stat_buf: std.c.struct_stat = undefined;
            const fstat_result = std.posix.system.fstat(file.handle, &stat_buf);
            if (fstat_result != 0) {
                try pushErrno(vm, .BADF);
                return;
            }
            // Note: File time updates on Windows require SetFileTime() API.
            // For now, we skip this on Windows and return success.
            try pushErrno(vm, .SUCCESS);
            return;
        } else |_| {
            try pushErrno(vm, .NOSYS);
            return;
        }
    }

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;

    const path = data[path_ptr .. path_ptr + path_len];
    const nofollow: u32 = if (builtin.os.tag == .windows) 0 else if (flags & 0x01 == 0) posix.AT.SYMLINK_NOFOLLOW else 0;
    var times = wasiTimesToTimespec(fst_flags, atim_ns, mtim_ns);

    // utimensat requires sentinel-terminated path
    var path_buf: [4096:0]u8 = undefined;
    if (path_len > 4096) {
        try pushErrno(vm, .NAMETOOLONG);
        return;
    }
    @memcpy(path_buf[0..path_len], path);
    path_buf[path_len] = 0;

    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.utimensat(host_fd, &path_buf, &times, nofollow);
        if (posix.errno(rc) != .SUCCESS) {
            try pushErrno(vm, .IO);
            return;
        }
    } else {
        const rc = std.c.utimensat(host_fd, &path_buf, &times, nofollow);
        if (rc < 0) {
            try pushErrno(vm, .IO);
            return;
        }
    }
    try pushErrno(vm, .SUCCESS);
}

/// path_readlink(fd: i32, path_ptr: i32, path_len: i32, buf_ptr: i32, buf_len: i32, bufused_ptr: i32) -> errno
pub fn path_readlink(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const bufused_ptr = vm.popOperandU32();
    const buf_len = vm.popOperandU32();
    const buf_ptr = vm.popOperandU32();
    const path_len = vm.popOperandU32();
    const path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();
    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory = try vm.getMemory(0);
    const data = memory.memory();
    if (path_ptr + path_len > data.len) return error.OutOfBoundsMemoryAccess;
    if (buf_ptr + buf_len > data.len) return error.OutOfBoundsMemoryAccess;

    const path = data[path_ptr .. path_ptr + path_len];
    const buf = data[buf_ptr .. buf_ptr + buf_len];

    var dir = std.Io.Dir{ .handle = host_fd };
    const result_len = dir.readLink(io, path, buf) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try memory.write(u32, bufused_ptr, 0, @intCast(result_len));
    try pushErrno(vm, .SUCCESS);
}

/// path_symlink(old_path_ptr: i32, old_path_len: i32, fd: i32, new_path_ptr: i32, new_path_len: i32) -> errno
pub fn path_symlink(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const new_path_len = vm.popOperandU32();
    const new_path_ptr = vm.popOperandU32();
    const fd = vm.popOperandI32();
    const old_path_len = vm.popOperandU32();
    const old_path_ptr = vm.popOperandU32();

    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };
    const io = wasi.io;

    const host_fd = wasi.getHostFd(fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory_inst = try vm.getMemory(0);
    const data = memory_inst.memory();
    if (old_path_ptr + old_path_len > data.len) return error.OutOfBoundsMemoryAccess;
    if (new_path_ptr + new_path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const old_path = data[old_path_ptr .. old_path_ptr + old_path_len];
    const new_path = data[new_path_ptr .. new_path_ptr + new_path_len];

    var dir = std.Io.Dir{ .handle = host_fd };
    dir.symLink(io, old_path, new_path, .{}) catch |err| {
        try pushErrno(vm, toWasiErrno(err));
        return;
    };
    try pushErrno(vm, .SUCCESS);
}

/// path_link(old_fd:i32, old_flags:i32, old_path_ptr:i32, old_path_len:i32, new_fd:i32, new_path_ptr:i32, new_path_len:i32) -> errno
pub fn path_link(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    const new_path_len = vm.popOperandU32();
    const new_path_ptr = vm.popOperandU32();
    const new_fd = vm.popOperandI32();
    const old_path_len = vm.popOperandU32();
    const old_path_ptr = vm.popOperandU32();
    _ = vm.popOperandU32(); // old_flags (lookupflags)
    const old_fd = vm.popOperandI32();

    if (!hasCap(vm, .allow_path)) return pushErrno(vm, .ACCES);

    const wasi = getWasi(vm) orelse {
        try pushErrno(vm, .NOSYS);
        return;
    };

    const old_host_fd = wasi.getHostFd(old_fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };
    const new_host_fd = wasi.getHostFd(new_fd) orelse {
        try pushErrno(vm, .BADF);
        return;
    };

    const memory_inst = try vm.getMemory(0);
    const data = memory_inst.memory();
    if (old_path_ptr + old_path_len > data.len) return error.OutOfBoundsMemoryAccess;
    if (new_path_ptr + new_path_len > data.len) return error.OutOfBoundsMemoryAccess;
    const old_path = data[old_path_ptr .. old_path_ptr + old_path_len];
    const new_path = data[new_path_ptr .. new_path_ptr + new_path_len];

    if (builtin.os.tag == .windows) {
        try pushErrno(vm, .NOSYS);
        return;
    } else {
        if (old_path_len >= std.Io.Dir.max_path_bytes or new_path_len >= std.Io.Dir.max_path_bytes) {
            try pushErrno(vm, .NAMETOOLONG);
            return;
        }

        var old_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var new_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        @memcpy(old_path_buf[0..old_path_len], old_path);
        old_path_buf[old_path_len] = 0;
        @memcpy(new_path_buf[0..new_path_len], new_path);
        new_path_buf[new_path_len] = 0;

        const rc = std.os.linux.linkat(
            old_host_fd,
            @ptrCast(old_path_buf[0..old_path_len :0].ptr),
            new_host_fd,
            @ptrCast(new_path_buf[0..new_path_len :0].ptr),
            0,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                try pushErrno(vm, toWasiErrno(std.posix.unexpectedErrno(err)));
                return;
            },
        }
    }
    try pushErrno(vm, .SUCCESS);
}

// ============================================================
// Error mapping
// ============================================================

fn toWasiErrno(err: anyerror) Errno {
    return switch (err) {
        error.AccessDenied => .ACCES,
        error.BrokenPipe => .PIPE,
        error.FileTooBig => .FBIG,
        error.InputOutput => .IO,
        error.IsDir => .ISDIR,
        error.NoSpaceLeft => .NOSPC,
        error.PermissionDenied => .PERM,
        error.Unseekable => .SPIPE,
        error.NotOpenForReading => .BADF,
        error.NotOpenForWriting => .BADF,
        error.FileNotFound => .NOENT,
        error.PathAlreadyExists => .EXIST,
        error.NotDir => .NOTDIR,
        error.DirNotEmpty => .NOTEMPTY,
        error.NameTooLong => .NAMETOOLONG,
        error.FileBusy => .BUSY,
        error.DiskQuota => .DQUOT,
        error.SymLinkLoop => .LOOP,
        error.ReadOnlyFileSystem => .ROFS,
        else => .IO,
    };
}

/// fd_fdstat_set_rights(fd: i32, rights_base: i64, rights_inheriting: i64) -> errno
/// Deprecated in WASI — accept and ignore.
pub fn fd_fdstat_set_rights(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandI64(); // rights_inheriting
    _ = vm.popOperandI64(); // rights_base
    _ = vm.popOperandI32(); // fd
    try pushErrno(vm, .SUCCESS);
}

/// proc_raise(sig: i32) -> errno
pub fn proc_raise(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandI32(); // sig
    try pushErrno(vm, .NOSYS);
}

/// sock_accept(fd: i32, flags: i32, result_fd_ptr: i32) -> errno
pub fn sock_accept(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // result_fd_ptr
    _ = vm.popOperandU32(); // flags
    _ = vm.popOperandI32(); // fd
    try pushErrno(vm, .NOSYS);
}

/// sock_recv(fd: i32, ri_data_ptr: i32, ri_data_len: i32, ri_flags: i32, ro_datalen_ptr: i32, ro_flags_ptr: i32) -> errno
pub fn sock_recv(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // ro_flags_ptr
    _ = vm.popOperandU32(); // ro_datalen_ptr
    _ = vm.popOperandU32(); // ri_flags
    _ = vm.popOperandU32(); // ri_data_len
    _ = vm.popOperandU32(); // ri_data_ptr
    _ = vm.popOperandI32(); // fd
    try pushErrno(vm, .NOSYS);
}

/// sock_send(fd: i32, si_data_ptr: i32, si_data_len: i32, si_flags: i32, so_datalen_ptr: i32) -> errno
pub fn sock_send(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // so_datalen_ptr
    _ = vm.popOperandU32(); // si_flags
    _ = vm.popOperandU32(); // si_data_len
    _ = vm.popOperandU32(); // si_data_ptr
    _ = vm.popOperandI32(); // fd
    try pushErrno(vm, .NOSYS);
}

/// sock_shutdown(fd: i32, how: i32) -> errno
pub fn sock_shutdown(ctx: *anyopaque, _: usize) anyerror!void {
    const vm = getVm(ctx);
    _ = vm.popOperandU32(); // how
    _ = vm.popOperandI32(); // fd
    try pushErrno(vm, .NOSYS);
}

// ============================================================
// Registration — register WASI functions for module imports
// ============================================================

const WasiEntry = struct {
    name: []const u8,
    func: store_mod.HostFn,
};

const wasi_table = [_]WasiEntry{
    .{ .name = "args_get", .func = &args_get },
    .{ .name = "args_sizes_get", .func = &args_sizes_get },
    .{ .name = "clock_res_get", .func = &clock_res_get },
    .{ .name = "clock_time_get", .func = &clock_time_get },
    .{ .name = "environ_get", .func = &environ_get },
    .{ .name = "environ_sizes_get", .func = &environ_sizes_get },
    .{ .name = "fd_advise", .func = &fd_advise },
    .{ .name = "fd_allocate", .func = &fd_allocate },
    .{ .name = "fd_close", .func = &fd_close },
    .{ .name = "fd_datasync", .func = &fd_datasync },
    .{ .name = "fd_fdstat_get", .func = &fd_fdstat_get },
    .{ .name = "fd_fdstat_set_flags", .func = &fd_fdstat_set_flags },
    .{ .name = "fd_fdstat_set_rights", .func = &fd_fdstat_set_rights },
    .{ .name = "fd_filestat_get", .func = &fd_filestat_get },
    .{ .name = "fd_filestat_set_size", .func = &fd_filestat_set_size },
    .{ .name = "fd_filestat_set_times", .func = &fd_filestat_set_times },
    .{ .name = "fd_pread", .func = &fd_pread },
    .{ .name = "fd_prestat_get", .func = &fd_prestat_get },
    .{ .name = "fd_prestat_dir_name", .func = &fd_prestat_dir_name },
    .{ .name = "fd_pwrite", .func = &fd_pwrite },
    .{ .name = "fd_read", .func = &fd_read },
    .{ .name = "fd_readdir", .func = &fd_readdir },
    .{ .name = "fd_renumber", .func = &fd_renumber },
    .{ .name = "fd_seek", .func = &fd_seek },
    .{ .name = "fd_sync", .func = &fd_sync },
    .{ .name = "fd_tell", .func = &fd_tell },
    .{ .name = "fd_write", .func = &fd_write },
    .{ .name = "poll_oneoff", .func = &poll_oneoff },
    .{ .name = "path_create_directory", .func = &path_create_directory },
    .{ .name = "path_filestat_get", .func = &path_filestat_get },
    .{ .name = "path_link", .func = &path_link },
    .{ .name = "path_filestat_set_times", .func = &path_filestat_set_times },
    .{ .name = "path_open", .func = &path_open },
    .{ .name = "path_readlink", .func = &path_readlink },
    .{ .name = "path_remove_directory", .func = &path_remove_directory },
    .{ .name = "path_rename", .func = &path_rename },
    .{ .name = "path_symlink", .func = &path_symlink },
    .{ .name = "path_unlink_file", .func = &path_unlink_file },
    .{ .name = "proc_exit", .func = &proc_exit },
    .{ .name = "proc_raise", .func = &proc_raise },
    .{ .name = "random_get", .func = &random_get },
    .{ .name = "sched_yield", .func = &sched_yield },
    .{ .name = "sock_accept", .func = &sock_accept },
    .{ .name = "sock_recv", .func = &sock_recv },
    .{ .name = "sock_send", .func = &sock_send },
    .{ .name = "sock_shutdown", .func = &sock_shutdown },
};

fn lookupWasiFunc(name: []const u8) ?store_mod.HostFn {
    for (&wasi_table) |*entry| {
        if (mem.eql(u8, entry.name, name)) return entry.func;
    }
    return null;
}

/// Register WASI functions that the module imports from "wasi_snapshot_preview1".
pub fn registerAll(store: *Store, module: *const Module) !void {
    for (module.imports.items) |imp| {
        switch (imp.kind) {
            .func => {
                if (!mem.eql(u8, imp.module, "wasi_snapshot_preview1")) continue;
                const func_ptr = lookupWasiFunc(imp.name) orelse continue;
                const func_type = module.getTypeFunc(imp.index) orelse return error.InvalidTypeIndex;
                try store.exposeHostFunction(
                    imp.module,
                    imp.name,
                    func_ptr,
                    0,
                    func_type.params,
                    func_type.results,
                );
            },
            .memory => {
                // WASI threads convention: host provides shared memory via "env" "memory"
                if (!mem.eql(u8, imp.module, "env")) continue;
                if (!mem.eql(u8, imp.name, "memory")) continue;
                const mt = imp.memory_type orelse continue;
                const addr = try store.addMemory(
                    mt.limits.min,
                    mt.limits.max,
                    mt.limits.page_size,
                    mt.limits.is_shared,
                    mt.limits.is_64,
                );
                const m = try store.getMemory(addr);
                try m.allocateInitial();
                try store.addExport("env", "memory", .memory, addr);
            },
            else => {},
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn readTestFile(io: std.Io, name: []const u8) ![]const u8 {
    const paths = [_][]const u8{
        "src/testdata/",
        "testdata/",
        "src/wasm/testdata/",
    };
    for (&paths) |prefix| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ prefix, name });
        defer testing.allocator.free(path);
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer file.close(io);
        const stat = try file.stat(io);
        const data = try testing.allocator.alloc(u8, stat.size);
        const n = try file.readPositionalAll(io, data, 0);
        return data[0..n];
    }
    return error.FileNotFound;
}

test "WASI — fd_write via 07_wasi_hello.wasm" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = testing.allocator;

    // Load and decode module
    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    // Create store and register WASI
    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    // Instantiate
    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    // Set up WASI context
    var wasi_ctx = WasiContext.init(alloc, testing.io);
    defer wasi_ctx.deinit();
    wasi_ctx.caps = Capabilities.all;
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    // Create pipe for capturing stdout
    var fds: [2]i32 = undefined;
    switch (std.posix.errno(std.os.linux.pipe(&fds))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    defer std.Io.Threaded.closeFd(fds[0]);
    wasi_ctx.setStdioFd(1, fds[1], .borrow);

    // Run _start
    var vm_inst = Vm.init(alloc);
    var results: [0]u64 = .{};
    vm_inst.invoke(&instance, "_start", &.{}, &results) catch |err| {
        if (err != error.Trap) return err;
    };
    std.Io.Threaded.closeFd(fds[1]);

    // Read captured output
    var buf: [256]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    const output = buf[0..n];

    try testing.expectEqualStrings("Hello, WASI!\n", output);
}

test "WASI — args_sizes_get and args_get" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc, testing.io);
    defer wasi_ctx.deinit();

    const test_args = [_][:0]const u8{ "prog", "arg1", "arg2" };
    wasi_ctx.setArgs(&test_args);
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    // Manually test args_sizes_get via direct call
    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;
    const memory = try instance.getMemory(0);

    // Push args (argv_buf_size_ptr=104, argc_ptr=100)
    try vm_inst.pushOperand(100); // argc_ptr
    try vm_inst.pushOperand(104); // argv_buf_size_ptr

    // Call args_sizes_get
    try args_sizes_get(@ptrCast(&vm_inst), 0);

    // Check errno
    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, 0), errno); // SUCCESS

    // Check argc
    const argc = try memory.read(u32, 100, 0);
    try testing.expectEqual(@as(u32, 3), argc);

    // Check buf_size: "prog\0" + "arg1\0" + "arg2\0" = 5 + 5 + 5 = 15
    const buf_size = try memory.read(u32, 104, 0);
    try testing.expectEqual(@as(u32, 15), buf_size);
}

test "WASI — environ_sizes_get with empty environ" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc, testing.io);
    defer wasi_ctx.deinit();
    wasi_ctx.caps = Capabilities.all;
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    try vm_inst.pushOperand(200); // count_ptr
    try vm_inst.pushOperand(204); // buf_size_ptr

    try environ_sizes_get(@ptrCast(&vm_inst), 0);

    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, 0), errno);

    const memory = try instance.getMemory(0);
    const count = try memory.read(u32, 200, 0);
    try testing.expectEqual(@as(u32, 0), count);

    const buf_size = try memory.read(u32, 204, 0);
    try testing.expectEqual(@as(u32, 0), buf_size);
}

test "WASI — clock_time_get returns nonzero" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc, testing.io);
    defer wasi_ctx.deinit();
    wasi_ctx.caps.allow_clock = true;
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    // clock_time_get(clock_id=0, precision=0, time_ptr=300)
    try vm_inst.pushOperand(0); // clock_id = REALTIME
    try vm_inst.pushOperand(0); // precision
    try vm_inst.pushOperand(300); // time_ptr

    try clock_time_get(@ptrCast(&vm_inst), 0);

    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, 0), errno);

    const memory = try instance.getMemory(0);
    const time_val = try memory.read(u64, 300, 0);
    try testing.expect(time_val > 0);
}

test "WASI — random_get fills buffer" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc, testing.io);
    defer wasi_ctx.deinit();
    wasi_ctx.caps = Capabilities.all;
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    const memory = try instance.getMemory(0);
    const data = memory.memory();

    // Zero-fill target area
    @memset(data[400..416], 0);

    // random_get(buf_ptr=400, buf_len=16)
    try vm_inst.pushOperand(400); // buf_ptr
    try vm_inst.pushOperand(16); // buf_len

    try random_get(@ptrCast(&vm_inst), 0);

    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, 0), errno);

    // Very unlikely all 16 bytes remain zero after random fill
    var all_zero = true;
    for (data[400..416]) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "WASI — deny-by-default capabilities" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc, testing.io);
    defer wasi_ctx.deinit();
    // Default capabilities: all denied
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    // clock_time_get should return EACCES (2) when allow_clock is false
    try vm_inst.pushOperand(0); // clock_id
    try vm_inst.pushOperand(0); // precision
    try vm_inst.pushOperand(300); // time_ptr
    try clock_time_get(@ptrCast(&vm_inst), 0);
    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, @intFromEnum(Errno.ACCES)), errno);
}

test "WASI — path_open creates file and returns valid fd" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc, testing.io);
    defer wasi_ctx.deinit();
    wasi_ctx.caps = Capabilities.all;
    instance.wasi = &wasi_ctx;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const host_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(host_path);
    try wasi_ctx.addPreopenPath(testing.io, 3, "/tmp", host_path);

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    const memory = try instance.getMemory(0);
    const data = memory.memory();

    // Write path "zwasm_test_open.txt" into wasm memory at offset 100
    const test_path = "zwasm_test_path_open.txt";
    @memcpy(data[100 .. 100 + test_path.len], test_path);

    // Clean up test file if it exists
    tmp.dir.deleteFile(testing.io, test_path) catch {};

    // Push path_open args in signature order (stack: first pushed = bottom)
    // path_open(fd=3, dirflags=1, path_ptr=100, path_len, oflags=CREAT(1),
    //           rights_base=0, rights_inh=0, fdflags=0, opened_fd_ptr=200)
    try vm_inst.pushOperand(3); // fd (preopen)
    try vm_inst.pushOperand(1); // dirflags = SYMLINK_FOLLOW
    try vm_inst.pushOperand(100); // path_ptr
    try vm_inst.pushOperand(test_path.len); // path_len
    try vm_inst.pushOperand(1); // oflags = CREAT
    try vm_inst.pushOperand(0); // rights_base (i64)
    try vm_inst.pushOperand(0); // rights_inheriting (i64)
    try vm_inst.pushOperand(0); // fdflags
    try vm_inst.pushOperand(200); // opened_fd_ptr
    try path_open(@ptrCast(&vm_inst), 0);
    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, @intFromEnum(Errno.SUCCESS)), errno);

    // Read the opened fd from memory
    const opened_fd = mem.readInt(u32, data[200..204], .little);
    try testing.expect(opened_fd >= 4); // should be > preopen fd 3

    // Verify: the fd is usable (write to it via fd_write)
    // Write "hello" to the opened fd
    const msg = "hello";
    @memcpy(data[300 .. 300 + msg.len], msg);
    // iovec at 400: {buf=300, len=5}
    mem.writeInt(u32, data[400..404], 300, .little);
    mem.writeInt(u32, data[404..408], @intCast(msg.len), .little);
    try vm_inst.pushOperand(opened_fd); // fd
    try vm_inst.pushOperand(400); // iovs_ptr
    try vm_inst.pushOperand(1); // iovs_len
    try vm_inst.pushOperand(500); // nwritten_ptr
    try fd_write(@ptrCast(&vm_inst), 0);
    const write_errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, @intFromEnum(Errno.SUCCESS)), write_errno);

    // Close the fd
    try vm_inst.pushOperand(opened_fd);
    try fd_close(@ptrCast(&vm_inst), 0);
    const close_errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, @intFromEnum(Errno.SUCCESS)), close_errno);

    // Clean up
    tmp.dir.deleteFile(testing.io, test_path) catch {};
}

test "WASI — fd_readdir lists directory entries" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc, testing.io);
    defer wasi_ctx.deinit();
    wasi_ctx.caps = Capabilities.all;
    instance.wasi = &wasi_ctx;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const host_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(host_path);

    // Create a temp directory with known contents
    const test_dir = "zwasm_test_readdir";
    tmp.dir.createDir(testing.io, test_dir, .default_dir) catch {};
    var dir_fd = try tmp.dir.openDir(testing.io, test_dir, .{ .access_sub_paths = true });
    defer dir_fd.close(testing.io);

    // Create two files in the directory
    const f1 = try dir_fd.createFile(testing.io, "afile.txt", .{ .read = true });
    f1.close(testing.io);
    const f2 = try dir_fd.createFile(testing.io, "bfile.txt", .{ .read = true });
    f2.close(testing.io);

    // Reopen dir fd for reading
    const read_dir_fd = try tmp.dir.openDir(testing.io, test_dir, .{ .access_sub_paths = true, .iterate = true });
    try wasi_ctx.addPreopenPath(testing.io, 3, "/tmp", host_path);
    // Put the dir fd in fd_table
    const wasi_dir_fd = try wasi_ctx.allocFd(.{
        .raw = read_dir_fd.handle,
        .kind = .dir,
    }, false);

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    const memory = try instance.getMemory(0);
    const data = memory.memory();

    // fd_readdir(fd, buf_ptr=1000, buf_len=4096, cookie=0, bufused_ptr=5000)
    try vm_inst.pushOperand(@intCast(wasi_dir_fd)); // fd
    try vm_inst.pushOperand(1000); // buf_ptr
    try vm_inst.pushOperand(4096); // buf_len
    try vm_inst.pushOperand(0); // cookie = start
    try vm_inst.pushOperand(5000); // bufused_ptr
    try fd_readdir(@ptrCast(&vm_inst), 0);
    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, @intFromEnum(Errno.SUCCESS)), errno);

    // Read bufused
    const bufused = mem.readInt(u32, data[5000..5004], .little);
    // Should have at least 2 entries (afile.txt=9, bfile.txt=9) + headers (24 each)
    // Plus . and .. on some platforms
    try testing.expect(bufused > 0);

    // First entry: check d_namlen and d_type are reasonable
    const d_namlen = mem.readInt(u32, data[1016..1020], .little);
    try testing.expect(d_namlen > 0);
    try testing.expect(d_namlen < 256);

    // Clean up
    dir_fd.deleteFile(testing.io, "afile.txt") catch {};
    dir_fd.deleteFile(testing.io, "bfile.txt") catch {};
    tmp.dir.deleteDir(testing.io, test_dir) catch {};
}

test "WASI — registerAll for wasi_hello module" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    // Should have registered fd_write
    try testing.expectEqual(@as(usize, 1), store_inst.functions.items.len);
}

test "WASI — env.memory shared import" {
    const alloc = testing.allocator;
    const wasm_bytes = try readTestFile(testing.io, "32_env_shared_memory.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    // env.memory should have been created as a shared memory import
    try testing.expectEqual(@as(usize, 1), store_inst.memories.items.len);
    try testing.expect(store_inst.memories.items[0].is_shared_memory);

    // Should be resolvable as an import
    const handle = try store_inst.lookupImport("env", "memory", .memory);
    try testing.expect(handle < store_inst.memories.items.len);
}

test "injected env vars accessible without allow_env" {
    const alloc = testing.allocator;

    const wasm_bytes = try readTestFile(testing.io, "07_wasi_hello.wasm");
    defer alloc.free(wasm_bytes);

    var module = Module.init(alloc, wasm_bytes);
    defer module.deinit();
    try module.decode();

    var store_inst = Store.init(alloc);
    defer store_inst.deinit();
    try registerAll(&store_inst, &module);

    var instance = instance_mod.Instance.init(alloc, &store_inst, &module);
    defer instance.deinit();

    var wasi_ctx = WasiContext.init(alloc, testing.io);
    defer wasi_ctx.deinit();
    // allow_env = false (default), but inject a variable
    wasi_ctx.caps = Capabilities.cli_default;
    try wasi_ctx.addEnv("MY_VAR", "hello");
    instance.wasi = &wasi_ctx;

    try instance.instantiate();

    var vm_inst = Vm.init(alloc);
    vm_inst.current_instance = &instance;

    // environ_sizes_get should succeed and report 1 variable
    try vm_inst.pushOperand(200); // count_ptr
    try vm_inst.pushOperand(204); // buf_size_ptr
    try environ_sizes_get(@ptrCast(&vm_inst), 0);

    const errno = vm_inst.popOperand();
    try testing.expectEqual(@as(u64, 0), errno); // SUCCESS

    const memory = try instance.getMemory(0);
    const count = try memory.read(u32, 200, 0);
    try testing.expectEqual(@as(u32, 1), count);
}

test "Capabilities.sandbox denies all" {
    const caps = Capabilities.sandbox;
    try testing.expect(!caps.allow_stdio);
    try testing.expect(!caps.allow_read);
    try testing.expect(!caps.allow_write);
    try testing.expect(!caps.allow_env);
    try testing.expect(!caps.allow_clock);
    try testing.expect(!caps.allow_random);
    try testing.expect(!caps.allow_proc_exit);
    try testing.expect(!caps.allow_path);
}

test "stdio override: default returns process stdio" {
    const alloc = testing.allocator;
    var ctx = WasiContext.init(alloc, testing.io);
    defer ctx.deinit();

    // Without overrides, stdioFile returns process stdin/stdout/stderr
    const stdin_file = ctx.stdioFile(0);
    try testing.expect(stdin_file != null);
    try testing.expectEqual(std.Io.File.stdin().handle, stdin_file.?.handle);

    const stdout_file = ctx.stdioFile(1);
    try testing.expect(stdout_file != null);
    try testing.expectEqual(std.Io.File.stdout().handle, stdout_file.?.handle);

    const stderr_file = ctx.stdioFile(2);
    try testing.expect(stderr_file != null);
    try testing.expectEqual(std.Io.File.stderr().handle, stderr_file.?.handle);

    // Non-stdio fd returns null
    try testing.expect(ctx.stdioFile(3) == null);
}

test "stdio override: custom fd replaces default" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var ctx = WasiContext.init(alloc, testing.io);
    defer ctx.deinit();

    // Create a pipe to use as custom stdout
    var fds: [2]i32 = undefined;
    switch (std.posix.errno(std.os.linux.pipe(&fds))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    defer std.Io.Threaded.closeFd(fds[0]);

    // Set stdout (fd 1) to write end of pipe, with ownership (runtime closes it)
    ctx.setStdioFd(1, fds[1], .own);

    const stdout_file = ctx.stdioFile(1);
    try testing.expect(stdout_file != null);
    try testing.expectEqual(fds[1], stdout_file.?.handle);

    // stdin and stderr remain default
    try testing.expectEqual(std.Io.File.stdin().handle, ctx.stdioFile(0).?.handle);
    try testing.expectEqual(std.Io.File.stderr().handle, ctx.stdioFile(2).?.handle);
}

test "stdio override: borrow mode does not close fd on deinit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var fds: [2]std.os.linux.fd_t = undefined;
    switch (std.posix.errno(std.os.linux.pipe(&fds))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    {
        var ctx = WasiContext.init(alloc, testing.io);
        ctx.setStdioFd(1, fds[1], .borrow);
        ctx.deinit();
    }

    const rc = std.os.linux.write(fds[1], "ok", 2);
    const written: usize = switch (std.posix.errno(rc)) {
        .SUCCESS => rc,
        else => 0,
    };
    try testing.expectEqual(@as(usize, 2), written);
}

test "addPreopenFd: registers fd-based preopen" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var ctx = WasiContext.init(alloc, testing.io);
    defer ctx.deinit();

    // Open a real directory to get a valid fd
    var dir = try std.Io.Dir.cwd().openDir(testing.io, ".", .{});
    const dir_fd = dir.handle;
    // Transfer ownership to WasiContext (which will close it)
    dir = undefined;

    try ctx.addPreopenFd(3, "/sandbox", dir_fd, .dir, .own);

    try testing.expectEqual(@as(usize, 1), ctx.preopens.items.len);
    try testing.expectEqual(@as(i32, 3), ctx.preopens.items[0].wasi_fd);
    try testing.expect(std.mem.eql(u8, "/sandbox", ctx.preopens.items[0].path));
    try testing.expectEqual(dir_fd, ctx.preopens.items[0].host.raw);
    try testing.expectEqual(HandleKind.dir, ctx.preopens.items[0].host.kind);
}
