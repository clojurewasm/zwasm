//! WASI host capability table (Phase 4 / §9.4 / 4.2).
//!
//! Holds the pre-instantiation state a `wasi_snapshot_preview1`
//! module needs from its host: argv, environ, fd table (with
//! stdin / stdout / stderr pre-populated at index 0 / 1 / 2),
//! preopens. The §9.4 / 4.3+ syscall handlers consume this
//! struct; the §9.4 / 4.7 import-resolution wires it onto a
//! `Runtime`.
//!
//! No syscall behaviour lives here yet — `Host` is the typed
//! container only (per ROADMAP §P13). The std.process.Init
//! adapter (`Host.initFromProcess`) lands in §9.4 / 4.7
//! alongside the binding integration.
//!
//! Zone 2 (`src/wasi/`) — may import Zone 0 (`util/`) +
//! Zone 1 + Zone 2-self. MUST NOT import Zone 2-other
//! (`interp/`, `jit*/`) or Zone 3 (`c_api/`, `cli/`).

const std = @import("std");

const p1 = @import("p1.zig");

const Allocator = std.mem.Allocator;

/// Classification of an entry in `Host.fd_table`. The 0/1/2
/// slots are always `.stdin` / `.stdout` / `.stderr`. `.file` /
/// `.dir` are populated when a guest opens or pre-opens a path.
/// `.closed` marks a freed slot — the table reuses indices
/// rather than shrinking.
pub const FdKind = enum(u8) {
    stdin,
    stdout,
    stderr,
    file,
    dir,
    closed,
};

/// One row of the host's fd table. Placeholder fields for the
/// underlying file handle / preopen path land alongside the
/// §9.4 / 4.4 (`fd_read` / `fd_write`) and §9.4 / 4.5
/// (`path_open`) handlers — this chunk wires the kind +
/// rights only.
pub const OpenFd = struct {
    kind: FdKind,
    rights_base: p1.Rights = 0,
    rights_inheriting: p1.Rights = 0,
};

/// One environment-variable entry. Both `key` and `value` are
/// owned by the Host's allocator and freed in `deinit`.
pub const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// One preopen — a host-side directory the guest sees at
/// `guest_path`. The `host_fd` is a host-OS file descriptor
/// pointing at the directory; the §9.4 / 4.5 (`path_open`)
/// handler combines it with guest-supplied relative paths via
/// `openat` to enforce the no-`..`-escape rule. `guest_path`
/// is owned by the Host's allocator.
pub const PreopenEntry = struct {
    host_fd: std.posix.fd_t,
    guest_path: []const u8,
};

/// Default rights granted to inherited stdio fds. Mirrors the
/// witx `fdflags` defaults a `wasi-libc`-compiled guest expects
/// from a vanilla preopen-style stdin / stdout / stderr.
const STDIO_READ_RIGHTS: p1.Rights = p1.RIGHTS_FD_READ;
const STDIO_WRITE_RIGHTS: p1.Rights = p1.RIGHTS_FD_WRITE;

pub const Host = struct {
    alloc: Allocator,
    args: [][]const u8 = &.{},
    envs: []EnvEntry = &.{},
    preopens: []PreopenEntry = &.{},
    fd_table: std.ArrayList(OpenFd) = .empty,

    /// Construct a Host with stdio fds 0 / 1 / 2 pre-populated.
    /// Callers grow `args` / `envs` / `preopens` via the
    /// respective setters before consuming the table.
    pub fn init(alloc: Allocator) !Host {
        var h: Host = .{ .alloc = alloc };
        try h.fd_table.append(alloc, .{ .kind = .stdin, .rights_base = STDIO_READ_RIGHTS });
        try h.fd_table.append(alloc, .{ .kind = .stdout, .rights_base = STDIO_WRITE_RIGHTS });
        try h.fd_table.append(alloc, .{ .kind = .stderr, .rights_base = STDIO_WRITE_RIGHTS });
        return h;
    }

    pub fn deinit(self: *Host) void {
        for (self.args) |a| self.alloc.free(a);
        self.alloc.free(self.args);
        for (self.envs) |e| {
            self.alloc.free(e.key);
            self.alloc.free(e.value);
        }
        self.alloc.free(self.envs);
        for (self.preopens) |p| self.alloc.free(p.guest_path);
        self.alloc.free(self.preopens);
        self.fd_table.deinit(self.alloc);
    }

    /// Replace the args slice with a deep copy of `src`. Existing
    /// args are released first so this is a "set" semantics, not
    /// an "append".
    pub fn setArgs(self: *Host, src: []const []const u8) !void {
        for (self.args) |a| self.alloc.free(a);
        self.alloc.free(self.args);
        const buf = try self.alloc.alloc([]const u8, src.len);
        errdefer self.alloc.free(buf);
        var copied: usize = 0;
        errdefer for (buf[0..copied]) |a| self.alloc.free(a);
        for (src, 0..) |s, i| {
            buf[i] = try self.alloc.dupe(u8, s);
            copied += 1;
        }
        self.args = buf;
    }

    /// Replace the envs slice. `keys` and `vals` must have the
    /// same length; pairs are stored independently so a future
    /// `environ_get` can write them in any order.
    pub fn setEnvs(self: *Host, keys: []const []const u8, vals: []const []const u8) !void {
        if (keys.len != vals.len) return error.EnvsKeyValueLengthMismatch;
        for (self.envs) |e| {
            self.alloc.free(e.key);
            self.alloc.free(e.value);
        }
        self.alloc.free(self.envs);
        const buf = try self.alloc.alloc(EnvEntry, keys.len);
        errdefer self.alloc.free(buf);
        var copied: usize = 0;
        errdefer for (buf[0..copied]) |e| {
            self.alloc.free(e.key);
            self.alloc.free(e.value);
        };
        for (keys, vals, 0..) |k, v, i| {
            const k_copy = try self.alloc.dupe(u8, k);
            errdefer self.alloc.free(k_copy);
            const v_copy = try self.alloc.dupe(u8, v);
            buf[i] = .{ .key = k_copy, .value = v_copy };
            copied += 1;
        }
        self.envs = buf;
    }

    /// Append a preopen and reserve an fd-table slot for it.
    /// Returns the guest fd (3, 4, …) the preopen now occupies;
    /// the corresponding `OpenFd.kind` is `.dir`.
    pub fn addPreopen(
        self: *Host,
        host_fd: std.posix.fd_t,
        guest_path: []const u8,
    ) !p1.Fd {
        const path_copy = try self.alloc.dupe(u8, guest_path);
        errdefer self.alloc.free(path_copy);
        const new_preopens = try self.alloc.realloc(self.preopens, self.preopens.len + 1);
        new_preopens[self.preopens.len] = .{ .host_fd = host_fd, .guest_path = path_copy };
        self.preopens = new_preopens;
        try self.fd_table.append(self.alloc, .{
            .kind = .dir,
            .rights_base = p1.RIGHTS_PATH_OPEN | p1.RIGHTS_FD_READ,
            .rights_inheriting = p1.RIGHTS_FD_READ | p1.RIGHTS_FD_WRITE | p1.RIGHTS_FD_SEEK,
        });
        return @intCast(self.fd_table.items.len - 1);
    }

    /// Resolve a guest fd to its `OpenFd` slot. Returns `null`
    /// for out-of-range fds; callers translate that to
    /// `Errno.badf`. Closed slots return a non-null pointer to
    /// a row whose `kind == .closed` — also a `badf` from the
    /// caller's perspective.
    pub fn translateFd(self: *Host, guest_fd: p1.Fd) ?*OpenFd {
        if (guest_fd >= self.fd_table.items.len) return null;
        return &self.fd_table.items[guest_fd];
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Host.init: stdio fds pre-populated at 0/1/2 with default rights" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    try testing.expectEqual(@as(usize, 3), h.fd_table.items.len);
    try testing.expectEqual(FdKind.stdin, h.fd_table.items[0].kind);
    try testing.expectEqual(FdKind.stdout, h.fd_table.items[1].kind);
    try testing.expectEqual(FdKind.stderr, h.fd_table.items[2].kind);
    try testing.expectEqual(p1.RIGHTS_FD_READ, h.fd_table.items[0].rights_base);
    try testing.expectEqual(p1.RIGHTS_FD_WRITE, h.fd_table.items[1].rights_base);
}

test "Host.translateFd: stdio resolves; out-of-range returns null" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    const slot = h.translateFd(1) orelse return error.MissingStdout;
    try testing.expectEqual(FdKind.stdout, slot.kind);
    try testing.expect(h.translateFd(99) == null);
}

test "Host.setArgs: deep-copies caller-supplied args" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    var src_buf: [3][]const u8 = .{ "zwasm", "run", "hello.wasm" };
    try h.setArgs(&src_buf);
    try testing.expectEqual(@as(usize, 3), h.args.len);
    try testing.expectEqualStrings("zwasm", h.args[0]);
    try testing.expectEqualStrings("hello.wasm", h.args[2]);
    // Mutating the source array doesn't leak into the host copy.
    src_buf[0] = "X";
    try testing.expectEqualStrings("zwasm", h.args[0]);
}

test "Host.setEnvs: paired keys + vals deep-copied" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    const keys: [2][]const u8 = .{ "PATH", "HOME" };
    const vals: [2][]const u8 = .{ "/usr/bin:/bin", "/root" };
    try h.setEnvs(&keys, &vals);
    try testing.expectEqual(@as(usize, 2), h.envs.len);
    try testing.expectEqualStrings("PATH", h.envs[0].key);
    try testing.expectEqualStrings("/root", h.envs[1].value);
}

test "Host.setEnvs: length mismatch errors out" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();
    const keys: [1][]const u8 = .{"A"};
    const vals: [2][]const u8 = .{ "1", "2" };
    try testing.expectError(error.EnvsKeyValueLengthMismatch, h.setEnvs(&keys, &vals));
}

test "Host.addPreopen: extends fd_table; new slot is .dir at fd 3" {
    var h = try Host.init(testing.allocator);
    defer h.deinit();

    // host_fd is opaque to this layer (4.5 path_open
    // dereferences it). Use a typed-undefined sentinel — fd_t
    // is `c_int` on Mac / Linux but `HANDLE` (`*anyopaque`) on
    // Windows; `undefined` is the only literal that types
    // portably. The test never reads the value back.
    const fake_fd: std.posix.fd_t = undefined;
    const fd = try h.addPreopen(fake_fd, "/sandbox");
    try testing.expectEqual(@as(p1.Fd, 3), fd);
    try testing.expectEqual(@as(usize, 1), h.preopens.len);
    try testing.expectEqualStrings("/sandbox", h.preopens[0].guest_path);

    const slot = h.translateFd(fd) orelse return error.MissingPreopen;
    try testing.expectEqual(FdKind.dir, slot.kind);
    try testing.expect((slot.rights_base & p1.RIGHTS_PATH_OPEN) != 0);
}

test "Host.deinit: leak-clean after addPreopen + setArgs + setEnvs" {
    // testing.allocator is leak-detecting; this test fails the
    // run if any of the dupes leak.
    var h = try Host.init(testing.allocator);

    var args: [2][]const u8 = .{ "zwasm", "hello" };
    try h.setArgs(&args);
    const keys: [1][]const u8 = .{"K"};
    const vals: [1][]const u8 = .{"V"};
    try h.setEnvs(&keys, &vals);
    const fake_fd: std.posix.fd_t = undefined;
    _ = try h.addPreopen(fake_fd, "/p");

    h.deinit();
}
