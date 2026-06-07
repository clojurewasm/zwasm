//! WASI **Preview 2** host trampolines + the single-component WASI-P2 runner
//! (CM campaign Phase D). Extracted from `component.zig` (D-309): the
//! Component-Model orchestration there crossed the file-size smell cap as the
//! WASI-P2 surface grew (stdio / clocks / random / exit / filesystem / poll).
//!
//! These satisfy a P2 component's canon-lowered `wasi:*` core imports by
//! name-mapping (`wasi/adapter.zig`) onto the existing Preview-1 impl
//! (`wasi/fd.zig` etc.), reusing it wholesale. Registered via
//! `Linker.defineFuncCtx` so each `*Caller` reaches both guest memory and the
//! per-run `WasiP2Ctx`. Zone 3 (touches `invoke`). A handful of `p2*` helpers
//! are `pub` solely for the in-tree e2e/unit tests that live in `component.zig`.

const std = @import("std");

const decode = @import("../feature/component/decode.zig");
const ctypes = @import("../feature/component/types.zig");
const cvalidate = @import("../feature/component/validate.zig");
const wasi_host = @import("../wasi/host.zig");
const wasi_fd = @import("../wasi/fd.zig");
const wasi_proc = @import("../wasi/proc.zig");
const wasi_clocks = @import("../wasi/clocks.zig");
const wasi_p1 = @import("../wasi/preview1.zig");
const adapter = @import("../wasi/adapter.zig");
const resource_table = @import("../feature/component/resource_table.zig");
const Caller = @import("../zwasm/caller.zig").Caller;

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const Linker = @import("../zwasm/linker.zig").Linker;
const Value = @import("../zwasm.zig").Value;

// ============================================================
// WASI Preview 2 host trampolines (CM campaign chunk D1-2)
// ============================================================
//
// A P2 component's canon-lowered core module imports flat core funcs for the
// WASI interfaces it uses (e.g. `io.get-stdout`, `io.write`, `io.drop-os`).
// These host trampolines satisfy those imports by name-mapping (per
// `wasi/adapter.zig`) onto the EXISTING Preview 1 impl (`wasi/fd.zig`),
// reusing it wholesale. They are registered via `Linker.defineFuncCtx` so the
// `*Caller` reaches both the guest memory and this per-run host context.

/// Per-run host context for the WASI-P2 → P1 trampolines. `get-stdout` mints
/// an output-stream handle in `streams` whose `rep` is the P1 fd it is bound to
/// (1 = stdout); `write` forwards the flat `list<u8>` to `wasi/fd.zig
/// writeSlice` on that fd; `drop-os` drops the handle. Threaded into each
/// trampoline via `Caller.data`.
pub const WasiP2Ctx = struct {
    host: *wasi_host.Host,
    /// One handle table keyed by resource-type id; each P2 resource the host
    /// models gets a distinct id (output-stream rep = P1 fd, descriptor rep = P1 fd).
    resources: resource_table.ResourceTable,
    /// Instance exporting `cabi_realloc` (set AFTER instantiation) — lets a
    /// trampoline allocate guest memory for list/string results (e.g.
    /// `get-directories`) via a nested invoke. See lesson
    /// `2026-06-07-engine-invoke-is-reentrant-stack-disciplined`.
    realloc_instance: ?*Instance = null,
    realloc_name: []const u8 = "cabi_realloc",
    /// Instance whose linear memory the lowered funcs read/write — the
    /// canon-lower-bound memory (the memory-exporting instance: `$main`, or
    /// `$libc` in the hand-authored fixtures). NOT the immediate caller's: a
    /// lower reached via wit-bindgen's shim `call_indirect` has the memory-less
    /// shim as caller, so trampolines must source memory from here (D-310).
    mem_instance: ?*Instance = null,

    /// Resource-type ids for the P2 resources the host models (`pub` for the
    /// in-tree tests that mint handles directly).
    pub const OUTPUT_STREAM_RT: u32 = 1;
    pub const DESCRIPTOR_RT: u32 = 2;
    pub const INPUT_STREAM_RT: u32 = 3;
    /// A `wasi:io/poll` pollable. Its rep is NOT a P1 fd (it carries no host
    /// resource for a synchronous always-ready host), so the generic drop must
    /// NOT `fd_close` it — see `p2ResourceDrop`.
    pub const POLLABLE_RT: u32 = 4;

    pub fn init(alloc: Allocator, host: *wasi_host.Host) !WasiP2Ctx {
        return .{ .host = host, .resources = try resource_table.ResourceTable.init(alloc) };
    }

    pub fn deinit(self: *WasiP2Ctx) void {
        self.resources.deinit();
    }

    /// Allocate `size` bytes of fresh guest memory via the guest's
    /// `cabi_realloc` (old_ptr=0). Used to build list/string return areas.
    fn reallocGuest(self: *WasiP2Ctx, size: u32, alignment: u32) WasiP2Error!u32 {
        const inst = self.realloc_instance orelse return WasiP2Error.NoRealloc;
        var args = [_]Value{ .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = @bitCast(alignment) }, .{ .i32 = @bitCast(size) } };
        var res = [_]Value{.{ .i32 = 0 }};
        inst.invoke(self.realloc_name, &args, &res) catch return WasiP2Error.ReallocFailed;
        const ptr: u32 = @bitCast(res[0].i32);
        if (ptr == 0 and size != 0) return WasiP2Error.ReallocFailed;
        return ptr;
    }

    /// The guest linear memory the lowered funcs operate on (`mem_instance`).
    fn memory(self: *WasiP2Ctx) WasiP2Error!Memory {
        const inst = self.mem_instance orelse return WasiP2Error.NoMemory;
        const rt = inst.handle.runtime orelse return WasiP2Error.NoMemory;
        if (rt.memory.len == 0) return WasiP2Error.NoMemory;
        return .{ .rt = rt };
    }
};

/// The lowered-WASI guest memory for a trampoline. Prefers the canon-lower-bound
/// memory recorded on `WasiP2Ctx` (`mem_instance`) — the immediate caller may be
/// the memory-less wit-bindgen shim (D-310). Falls back to `caller.memory()`
/// when no `mem_instance` is set (direct-call unit tests that build a ctx by
/// hand), preserving the original direct-dispatch behaviour.
fn ctxMemory(caller: *Caller) WasiP2Error!Memory {
    const ctx = caller.data(WasiP2Ctx);
    if (ctx.mem_instance != null) return ctx.memory();
    return caller.memory() orelse return WasiP2Error.NoMemory;
}

pub const WasiP2Error = error{ NoMemory, OutOfBounds, WriteFailed, NoRealloc, ReallocFailed, ProcExit } ||
    resource_table.Error || Memory.Error;

const Memory = @import("../zwasm/memory.zig").Memory;

/// `wasi:cli/stdout` `get-stdout` → mint an output-stream handle bound to fd 1.
pub fn p2GetStdout(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.OUTPUT_STREAM_RT, 1);
}

/// `wasi:cli/stderr` `get-stderr` → mint an output-stream handle bound to fd 2.
/// The write/drop trampolines are shared (they resolve the fd from the handle).
fn p2GetStderr(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.OUTPUT_STREAM_RT, 2);
}

/// `wasi:cli/exit` `exit(status: result)` → P1 `proc_exit`. The bare `result`
/// status lowers to a single i32 discriminant (0=ok, 1=err); map it straight to
/// the exit code. `exit` is `noreturn`: after recording the code we return
/// `ProcExit` to unwind the guest invoke, and `runWasiP2Main` treats a set
/// `host.exit_code` as a clean termination (not a failure).
fn p2Exit(caller: *Caller, status: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    _ = wasi_proc.procExit(ctx.host, status);
    return WasiP2Error.ProcExit;
}

/// `wasi:clocks/monotonic-clock` `now()` → instant(u64). Returns the host
/// monotonic clock (P1 clock id 1) directly as the lowered `i64` — no guest
/// memory / return area. `now()` is infallible in WIT and the component-run
/// path always has `host.io`, so a clock-read failure is a host-setup bug.
fn p2MonotonicNow(caller: *Caller) WasiP2Error!i64 {
    const ctx = caller.data(WasiP2Ctx);
    const ns = wasi_clocks.clockTimeNs(ctx.host, 1) catch
        @panic("WASI-P2 monotonic-clock.now: host clock unavailable (host.io unset)");
    return @bitCast(ns);
}

/// `wasi:clocks/wall-clock` `now()` → datetime{seconds: u64, nanoseconds: u32}.
/// Splits the host realtime clock (P1 clock id 0) into seconds + sub-second ns
/// and writes the 12-byte record to the return area at `retptr` (seconds @ 0,
/// nanoseconds @ 8). Reuses clockTimeNs; no realloc (the guest supplies retptr).
fn p2WallNow(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const ns = wasi_clocks.clockTimeNs(ctx.host, 0) catch
        @panic("WASI-P2 wall-clock.now: host clock unavailable (host.io unset)");
    try mem.write(retptr, @as(u64, ns / std.time.ns_per_s));
    try mem.write(retptr + 8, @as(u32, @intCast(ns % std.time.ns_per_s)));
}

/// `wasi:cli/stdin` `get-stdin` → mint an input-stream handle bound to fd 0.
fn p2GetStdin(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.INPUT_STREAM_RT, 0);
}

/// `wasi:io/streams` `[method]input-stream.read(self, len) -> result<list<u8>,
/// stream-error>` (self, len, retptr): read up to `len` bytes from the fd bound
/// to `self` (stdin) into a cabi_realloc'd buffer. Writes the `result` at
/// `retptr`: disc@0 (0=ok / 1=err), and on ok (data_ptr@4, len@8); on EOF the
/// stream is closed → err(stream-error::closed) (err disc@0=1, variant case@4=1).
fn p2InStreamRead(caller: *Caller, self_handle: u32, len: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    _ = try ctx.resources.rep(WasiP2Ctx.INPUT_STREAM_RT, self_handle); // validate handle (rep = fd 0)
    const n: u32 = @intCast(@min(len, std.math.maxInt(u32)));
    const data_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    const got: u32 = if (n == 0) 0 else @intCast(wasi_fd.readStdinSlice(ctx.host, mem.sliceAt(data_ptr, n) catch return WasiP2Error.OutOfBounds));
    if (got == 0 and n != 0) {
        try mem.write(retptr, @as(u8, 1)); // err disc
        try mem.write(retptr + 4, @as(u8, 1)); // stream-error::closed (variant case 1)
    } else {
        try mem.write(retptr, @as(u8, 0)); // ok disc
        try mem.write(retptr + 4, data_ptr); // list data ptr
        try mem.write(retptr + 8, got); // list length
    }
}

/// `wasi:random/random` `get-random-bytes(len: u64) -> list<u8>`. Allocates
/// `len` bytes via the guest `cabi_realloc` (nested invoke), fills them with
/// secure random, and writes `(data_ptr, len)` to the return area at `retptr`.
/// Mirrors the D2 list-return pattern (p2GetDirectories).
fn p2RandomGetBytes(caller: *Caller, len: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const n: u32 = @intCast(@min(len, std.math.maxInt(u32)));
    const data_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    if (n != 0) {
        const dest = mem.sliceAt(data_ptr, n) catch return WasiP2Error.OutOfBounds;
        if (wasi_clocks.randomFill(ctx.host, dest) != .success)
            @panic("WASI-P2 get-random-bytes: secure random unavailable (host.io unset)");
    }
    try mem.write(retptr, data_ptr); // list data ptr
    try mem.write(retptr + 4, n); // list length
}

/// `wasi:io/streams` `[method]output-stream.blocking-write-and-flush`
/// (self, ptr, len, retptr): write the flat `list<u8>` at `(ptr, len)` to the
/// fd bound to `self`, then store the `result<_, stream-error>` ok-discriminant
/// (0) at `retptr`.
pub fn p2OutStreamWrite(caller: *Caller, self_handle: u32, ptr: u32, len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.OUTPUT_STREAM_RT, self_handle));
    const mem = try ctxMemory(caller);
    const bytes = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
    if (wasi_fd.writeSlice(ctx.host, fd, bytes) != .success) return WasiP2Error.WriteFailed;
    try mem.write(retptr, @as(u8, 0));
}

/// `wasi:io/streams` `[resource-drop]output-stream` (self): drop the handle.
pub fn p2OutStreamDrop(caller: *Caller, self_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    _ = try ctx.resources.drop(WasiP2Ctx.OUTPUT_STREAM_RT, self_handle);
}

/// `wasi:filesystem/types` `[method]descriptor.write` (self, buf_ptr, buf_len,
/// offset, retptr): positionally write the flat `list<u8>` at `(buf_ptr,
/// buf_len)` to the fd bound to the `descriptor` handle, then store the
/// `result<filesize, error-code>` (disc 0 = ok, u64 filesize at +8) at `retptr`.
pub fn p2DescriptorWrite(caller: *Caller, self_handle: u32, buf_ptr: u32, buf_len: u32, offset: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const bytes = mem.sliceAt(buf_ptr, buf_len) catch return WasiP2Error.OutOfBounds;
    const errno = wasi_fd.pwriteSlice(ctx.host, fd, bytes, offset);
    if (errno != .success) {
        try mem.write(retptr, @as(u8, 1)); // result disc: err
        try mem.write(retptr + 8, @intFromEnum(adapter.errnoToP2ErrorCode(errno))); // error-code (align 8)
        return;
    }
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 8, @as(u64, buf_len)); // filesize written
}

/// `wasi:filesystem/types` `[resource-drop]descriptor` (self): drop the handle
/// (closes the underlying fd via P1 `fd_close`).
pub fn p2DescriptorDrop(caller: *Caller, self_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    _ = wasi_fd.fdClose(ctx.host, fd);
    _ = try ctx.resources.drop(WasiP2Ctx.DESCRIPTOR_RT, self_handle);
}

/// Generic classified `canon resource.drop`: drop a handle of ANY host-modeled
/// P2 resource (output-stream / descriptor — both rep = a P1 fd) and close the
/// underlying fd (a noop for stdio per P1 `fd_close`). The language-level drop
/// already named the type; the table's stored type is authoritative, so the
/// host need not resolve which interface's resource was dropped.
fn p2ResourceDrop(caller: *Caller, self_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    // fd-backed resources (stdio/descriptor streams) close their fd; a pollable
    // carries no host fd, so only its handle slot is released.
    if (try ctx.resources.dropAny(self_handle)) |h| {
        if (h.rt != WasiP2Ctx.POLLABLE_RT) _ = wasi_fd.fdClose(ctx.host, @intCast(h.rep));
    }
}

/// True if `inst` exports a function named `name`.
fn instanceExportsFunc(inst: *Instance, name: []const u8) bool {
    for (inst.handle.exports_storage) |e| {
        if (e.kind == .func and std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

/// True if `inst` exports a linear memory (the canon-lower-bound memory the
/// host trampolines read/write — `$main` / `$libc`).
fn instanceExportsMemory(inst: *Instance) bool {
    for (inst.handle.exports_storage) |e| {
        if (e.kind == .memory) return true;
    }
    return false;
}

/// The WASI fd of the preopen rooted at host-OS fd `host_fd` (its `.dir`
/// fd-table slot), or null if not found.
fn preopenWasiFd(host: *wasi_host.Host, host_fd: std.posix.fd_t) ?wasi_p1.Fd {
    for (host.fd_table.items, 0..) |slot, i| {
        if (slot.kind == .dir and slot.host_handle == host_fd) return @intCast(i);
    }
    return null;
}

/// `wasi:filesystem/types` `[method]descriptor.open-at` (self, path_flags,
/// path_ptr, path_len, open_flags, descriptor_flags, retptr): open `path`
/// relative to the directory descriptor `self`, mint a descriptor resource for
/// the opened fd, and store `result<own<descriptor>, error-code>` (disc 0 = ok,
/// handle at +4) at `retptr`. P2 open-flags bits map 1:1 onto P1 oflags
/// (create/directory/exclusive/truncate = 0x1/2/4/8). A P1 error becomes
/// `result.err(error-code)` via the D-307 errno map (no trap).
pub fn p2DescriptorOpenAt(caller: *Caller, self_handle: u32, path_flags: u32, path_ptr: u32, path_len: u32, open_flags: u32, descriptor_flags: u32, retptr: u32) WasiP2Error!void {
    _ = path_flags;
    _ = descriptor_flags;
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const oflags: wasi_p1.Oflags = @intCast(open_flags & 0x000F);
    const rights = wasi_p1.RIGHTS_FD_READ | wasi_p1.RIGHTS_FD_WRITE;
    // pathOpen writes the opened fd to retptr+4; reuse that slot for the result payload.
    const errno = wasi_fd.pathOpen(ctx.host, mem.slice(), dirfd, 0, path_ptr, path_len, oflags, rights, rights, 0, retptr + 4);
    if (errno != .success) {
        try mem.write(retptr, @as(u8, 1)); // result disc: err
        try mem.write(retptr + 4, @intFromEnum(adapter.errnoToP2ErrorCode(errno))); // D-307: error-code
        return;
    }
    const opened_fd = try mem.read(u32, retptr + 4);
    const handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, opened_fd);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 4, handle); // own<descriptor>
}

/// `wasi:filesystem/preopens` `get-directories` (retptr): build a
/// `list<tuple<own<descriptor>, string>>` of the host's preopened dirs in a
/// freshly `cabi_realloc`'d backing (each entry mints a descriptor resource
/// bound to the preopen's WASI fd), then store `(list_ptr, list_len)` at
/// `retptr`. The list/string allocation is the nested-invoke realloc path.
pub fn p2GetDirectories(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const preopens = ctx.host.preopens;
    const n: u32 = @intCast(preopens.len);
    // Each list element is a tuple (descriptor handle i32, str_ptr i32, str_len i32) = 12 bytes.
    const list_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n * 12, 4);
    for (preopens, 0..) |p, i| {
        const wfd = preopenWasiFd(ctx.host, p.host_fd) orelse return WasiP2Error.WriteFailed;
        const handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, wfd);
        const path_len: u32 = @intCast(p.guest_path.len);
        const str_ptr = try ctx.reallocGuest(path_len, 1);
        @memcpy(mem.sliceAt(str_ptr, path_len) catch return WasiP2Error.OutOfBounds, p.guest_path);
        const tup = list_ptr + @as(u32, @intCast(i)) * 12;
        try mem.write(tup, handle);
        try mem.write(tup + 4, str_ptr);
        try mem.write(tup + 8, path_len);
    }
    try mem.write(retptr, list_ptr);
    try mem.write(retptr + 4, n);
}

/// `wasi:io/streams` `[method]output-stream.blocking-flush` (self, retptr):
/// store `result<_, stream-error>` ok (disc 0) at `retptr`. The host writes
/// directly to the underlying fd (nothing is buffered at this layer), so a
/// flush is always an immediate success once the handle is valid.
fn p2OutStreamFlush(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    _ = try ctx.resources.rep(WasiP2Ctx.OUTPUT_STREAM_RT, self_handle); // validate handle
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
}

/// `wasi:filesystem/types` `[method]descriptor.sync` (self, retptr): flush the
/// fd to disk via P1 `fd_sync`, then store `result<_, error-code>` at `retptr`
/// (disc 0 = ok; on a P1 error, disc 1 + the D-307 error-code ordinal at +1).
fn p2DescriptorSync(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const errno = wasi_fd.fdSync(ctx.host, fd);
    if (errno == .success) {
        try mem.write(retptr, @as(u8, 0));
    } else {
        try mem.write(retptr, @as(u8, 1)); // result disc: err
        try mem.write(retptr + 1, @intFromEnum(adapter.errnoToP2ErrorCode(errno)));
    }
}

/// Map a P1 `Filetype` onto the P2 `descriptor-type` enum ordinal (the two
/// enums diverge in case order — fifo/socket are P2-only at 4/7).
fn filetypeToDescriptorType(ft: wasi_p1.Filetype) u8 {
    return switch (ft) {
        .unknown => 0,
        .block_device => 1,
        .character_device => 2,
        .directory => 3,
        .regular_file => 6,
        .socket_dgram, .socket_stream => 7,
        .symbolic_link => 5,
        _ => 0,
    };
}

/// Stat the fd bound to `self` via P1 `fd_filestat_get` into a scratch buffer,
/// returning the raw `Filestat` (the shared P1→P2 front-half for stat/get-type).
fn descriptorFilestat(ctx: *WasiP2Ctx, mem: Memory, fd: wasi_p1.Fd) WasiP2Error!union(enum) { ok: wasi_p1.Filestat, err: wasi_p1.Errno } {
    const scratch = try ctx.reallocGuest(@sizeOf(wasi_p1.Filestat), 8);
    const errno = wasi_fd.fdFilestatGet(ctx.host, mem.slice(), fd, scratch);
    if (errno != .success) return .{ .err = errno };
    const bytes = mem.sliceAt(scratch, @sizeOf(wasi_p1.Filestat)) catch return WasiP2Error.OutOfBounds;
    return .{ .ok = std.mem.bytesToValue(wasi_p1.Filestat, bytes) };
}

/// `wasi:filesystem/types` `[method]descriptor.get-type` (self, retptr): store
/// `result<descriptor-type, error-code>` at `retptr` (disc@0; payload@1).
fn p2DescriptorGetType(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    switch (try descriptorFilestat(ctx, mem, fd)) {
        .ok => |fs| {
            try mem.write(retptr, @as(u8, 0)); // result disc: ok
            try mem.write(retptr + 1, filetypeToDescriptorType(fs.filetype));
        },
        .err => |errno| {
            try mem.write(retptr, @as(u8, 1));
            try mem.write(retptr + 1, @intFromEnum(adapter.errnoToP2ErrorCode(errno)));
        },
    }
}

/// `wasi:filesystem/types` `[method]descriptor.stat` (self, retptr): store
/// `result<descriptor-stat, error-code>` at `retptr`. The `descriptor-stat`
/// record (align 8) lands at the result payload offset +8; its canonical layout
/// is `%type@0, link-count@8, size@16` then three `option<datetime>` (24 bytes
/// each: disc@0, datetime{seconds u64@8, nanoseconds u32@16}) at +24/+48/+72.
fn p2DescriptorStat(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    switch (try descriptorFilestat(ctx, mem, fd)) {
        .ok => |fs| {
            try mem.write(retptr, @as(u8, 0)); // result disc: ok
            const base = retptr + 8; // descriptor-stat align-8 payload
            try mem.write(base, filetypeToDescriptorType(fs.filetype));
            try mem.write(base + 8, @as(u64, fs.nlink));
            try mem.write(base + 16, @as(u64, fs.size));
            // Three Some(datetime) timestamps: access / modification / change.
            inline for (.{ .{ base + 24, fs.atim }, .{ base + 48, fs.mtim }, .{ base + 72, fs.ctim } }) |t| {
                try mem.write(t[0], @as(u8, 1)); // option disc: some
                try mem.write(t[0] + 8, @as(u64, t[1] / std.time.ns_per_s));
                try mem.write(t[0] + 16, @as(u32, @intCast(t[1] % std.time.ns_per_s)));
            }
        },
        .err => |errno| {
            try mem.write(retptr, @as(u8, 1));
            try mem.write(retptr + 8, @intFromEnum(adapter.errnoToP2ErrorCode(errno)));
        },
    }
}

/// `wasi:filesystem/types` `[method]descriptor.read` (self, length, offset,
/// retptr): positionally read up to `length` bytes at `offset` into a
/// `cabi_realloc`'d buffer via P1 `fd_pread`, then store `result<tuple<list<u8>,
/// bool>, error-code>` at `retptr` (align 4 → payload@+4): on ok, list
/// (data_ptr@+4, len@+8) + EOF bool@+12; on a P1 error, disc 1 + error-code@+4.
fn p2DescriptorRead(caller: *Caller, self_handle: u32, length: u64, offset: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const n: u32 = @intCast(@min(length, std.math.maxInt(u32)));
    const data_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    // A single-entry iovec + nread slot in a fresh scratch area (P1 fd_pread is
    // iovec-based; reuse it wholesale rather than duplicate the read loop).
    const scratch = try ctx.reallocGuest(12, 4);
    try mem.write(scratch, data_ptr); // iovec[0].buf
    try mem.write(scratch + 4, n); // iovec[0].buf_len
    const errno = wasi_fd.fdPread(ctx.host, mem.slice(), fd, scratch, 1, offset, scratch + 8);
    if (errno != .success) {
        try mem.write(retptr, @as(u8, 1)); // result disc: err
        try mem.write(retptr + 4, @intFromEnum(adapter.errnoToP2ErrorCode(errno)));
        return;
    }
    const nread = try mem.read(u32, scratch + 8);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 4, data_ptr); // tuple.0 list data ptr
    try mem.write(retptr + 8, nread); // tuple.0 list length
    try mem.write(retptr + 12, @as(u8, if (nread < n) 1 else 0)); // tuple.1 eof bool
}

// ---- wasi:io/poll (D3-7) ----
//
// A synchronous host has no async readiness: every resource it models is
// always ready (a file read never blocks, stdio is immediate, a clock duration
// is checked at poll time). So every pollable's `ready` is true, `block` is a
// noop, and `poll` reports all input pollables ready. `subscribe`-style methods
// mint a POLLABLE_RT handle; its rep is unused (kept 0). This matches the spec
// contract (poll never fails; readiness errors surface via the source op).

/// `wasi:io/streams`/`wasi:clocks` `subscribe*` → mint a pollable handle. The
/// source handle / clock argument is irrelevant for an always-ready host.
fn p2Subscribe(caller: *Caller, _: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

/// `wasi:clocks/monotonic-clock` `subscribe-instant`/`subscribe-duration`
/// (when: u64) → pollable. Same always-ready handle; the deadline is ignored.
fn p2SubscribeClock(caller: *Caller, _: u64) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

/// `wasi:io/poll` `[method]pollable.ready` (self) -> bool: always ready (1).
fn p2PollableReady(caller: *Caller, self_handle: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    _ = try ctx.resources.rep(WasiP2Ctx.POLLABLE_RT, self_handle); // validate handle
    return 1;
}

/// `wasi:io/poll` `[method]pollable.block` (self): a synchronous host never
/// blocks — return immediately once the handle is validated.
fn p2PollableBlock(caller: *Caller, self_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    _ = try ctx.resources.rep(WasiP2Ctx.POLLABLE_RT, self_handle);
}

/// `wasi:io/poll` `poll(in: list<borrow<pollable>>) -> list<u32>` (in_ptr,
/// in_len, retptr): every pollable is always ready, so return the full index
/// set `[0, in_len)` as a freshly `cabi_realloc`'d `list<u32>` and write
/// `(data_ptr, in_len)` at `retptr`. Each input handle is validated.
fn p2Poll(caller: *Caller, in_ptr: u32, in_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    var i: u32 = 0;
    while (i < in_len) : (i += 1) {
        _ = try ctx.resources.rep(WasiP2Ctx.POLLABLE_RT, try mem.read(u32, in_ptr + i * 4));
    }
    const data_ptr: u32 = if (in_len == 0) 0 else try ctx.reallocGuest(in_len * 4, 4);
    i = 0;
    while (i < in_len) : (i += 1) try mem.write(data_ptr + i * 4, i);
    try mem.write(retptr, data_ptr); // list data ptr
    try mem.write(retptr + 4, in_len); // list length
}

// ---- wasi:cli/environment + terminal-* + output-stream.check-write (E2) ----
//
// A sandboxed, non-tty, always-writable host. get-environment / get-arguments
// return the empty list; initial-cwd + get-terminal-* return `none`;
// check-write reports a large byte permit so the guest proceeds to write.

/// `wasi:cli/environment` `get-environment`/`get-arguments` → the empty list:
/// write `(data_ptr=0, len=0)` to the return area at `retptr`.
fn p2EmptyList(caller: *Caller, retptr: u32) WasiP2Error!void {
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u32, 0)); // list data ptr
    try mem.write(retptr + 4, @as(u32, 0)); // list length
}

/// An `option<...>` host query with no value (`initial-cwd`, `get-terminal-*`)
/// → `none`: write the option discriminant 0 at `retptr`.
fn p2ReturnNone(caller: *Caller, retptr: u32) WasiP2Error!void {
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 0)); // option disc: none
}

/// `wasi:io/streams` `[method]output-stream.check-write` (self, retptr) ->
/// `result<u64, stream-error>`: an always-writable sync host reports a large
/// permit. Writes disc 0 (ok) + the u64 permit at `retptr+8` (align 8).
fn p2CheckWrite(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    _ = try ctx.resources.rep(WasiP2Ctx.OUTPUT_STREAM_RT, self_handle); // validate handle
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 8, @as(u64, 4096)); // bytes the guest may write now
}

/// Bind the trampoline for `op` under the core import `name` in namespace
/// `module`. The name is whatever the core module imports; the trampoline is
/// chosen by the classified `op`, not by the name.
fn defineClassifiedFunc(lk: *Linker, module: []const u8, name: []const u8, op: adapter.P2Op, ctx: *WasiP2Ctx) !void {
    switch (op) {
        .cli_get_stdout => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2GetStdout),
        .cli_get_stderr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2GetStderr),
        .out_stream_write, .out_stream_blocking_write_and_flush => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2OutStreamWrite),
        // Any classified `canon resource.drop` (classifyCoreExport returns
        // out_stream_drop for all) routes to the generic drop — correct for both
        // output-stream and descriptor handles (both rep = a P1 fd).
        .out_stream_drop, .fs_descriptor_drop, .in_stream_drop => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ResourceDrop),
        .cli_get_stdin => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2GetStdin),
        .in_stream_read, .in_stream_blocking_read => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2InStreamRead),
        .fs_descriptor_write => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u64, u32) WasiP2Error!void, p2DescriptorWrite),
        .fs_get_directories => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2GetDirectories),
        .fs_descriptor_open_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorOpenAt),
        .cli_exit => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2Exit),
        .clocks_monotonic_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2MonotonicNow),
        .clocks_wall_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2WallNow),
        .random_get_bytes => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u64, u32) WasiP2Error!void, p2RandomGetBytes),
        .out_stream_blocking_flush => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2OutStreamFlush),
        .fs_descriptor_read => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u64, u32) WasiP2Error!void, p2DescriptorRead),
        .fs_descriptor_sync => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorSync),
        .fs_descriptor_stat => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorStat),
        .fs_descriptor_get_type => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorGetType),
        .poll_pollable_ready => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2PollableReady),
        .poll_pollable_block => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2PollableBlock),
        .poll_poll => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, p2Poll),
        .in_stream_subscribe, .out_stream_subscribe => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2Subscribe),
        .clocks_subscribe_instant, .clocks_subscribe_duration => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u64) WasiP2Error!u32, p2SubscribeClock),
        .cli_get_environment, .cli_get_arguments => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2EmptyList),
        .cli_initial_cwd, .cli_get_terminal_stdin, .cli_get_terminal_stdout, .cli_get_terminal_stderr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ReturnNone),
        .out_stream_check_write => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2CheckWrite),
    }
}

/// The Nth `.core_module` section body in a decoded component.
fn nthCoreModule(decoded: *const decode.Component, n: u32) ?[]const u8 {
    var i: u32 = 0;
    for (decoded.sections.items) |sec| {
        if (sec.id != .core_module) continue;
        if (i == n) return sec.body;
        i += 1;
    }
    return null;
}

/// The (first) `canon lift`'s underlying core-instance export — the lowered
/// `run` the host invokes (resolved through the unified core-func index space).
fn firstLiftCoreExport(info: *const ctypes.TypeInfo) ?ctypes.TypeInfo.CoreExportRef {
    for (info.canons.items) |c| {
        if (c == .lift) return info.resolveCoreFuncExport(c.lift.core_func);
    }
    return null;
}

/// Run a single-component WASI-P2 CLI program end-to-end (the `wasi:cli/run`
/// stdio print subset). Decodes the component, instantiates its inner core
/// modules, wires the canon-lowered `wasi:*` imports to the P2 trampolines +
/// the libc core-instance memory cross-instance, and invokes the lowered `run`.
/// Captured output lands in `host` (e.g. `host.stdout_buffer`).
///
/// SCOPE (D1-2 → D-306): the print subset — host-wasi namespace(s)
/// (get-stdout/write/drop-os) + libc core-instance memories. The general
/// N-interface, adapter-classified wiring (resolve each `.lower` → its
/// component import → `adapter.classifyImport` → the matching trampoline, and
/// arbitrary cross-instance funcs) is the D2/D3 follow-up.
// ============================================================
// General component instantiation engine (ADR-0175)
// ============================================================
//
// A component's core-instance index space is built in definition order
// (each `.instantiate`'s `with` args reference earlier instances). A guest
// instance is a real `*Instance`; a synthetic (`.inline_exports`) instance is a
// name→`Def` table where `Def` is a host WASI trampoline, a re-exported guest
// func, or a re-exported guest table. This subsumes the hand-authored fixtures
// (main + libc + host-wasi inline_exports) AND real wit-bindgen output (a
// `$shim` guest module exporting `call_indirect` trampolines + a table, the
// memory-needing lowers materialised as host funcs, and a `$fixup` whose active
// `elem` fills the shim table — built like any other instance).

/// What a synthetic instance's export resolves to when poured into an importer.
const Def = union(enum) {
    host_op: adapter.P2Op,
    guest_func: struct { inst: *Instance, name: []const u8 },
    guest_table: struct { inst: *Instance, name: []const u8 },
};
const SynthExport = struct { name: []const u8, def: Def };
const Built = union(enum) { guest: *Instance, synthetic: []const SynthExport };

/// Resolve one `core:inlineexport` to the `Def` an importer should bind, or
/// null when it is not a host-relevant export (skipped). `built` holds the
/// already-constructed earlier instances (aliases only reference those).
fn synthDef(info: *const ctypes.TypeInfo, built: []const ?Built, ex: ctypes.CoreInlineExport) !?Def {
    switch (ex.sort) {
        .func => switch (info.coreFunc(ex.index) orelse return null) {
            .lower => |cfn| {
                const ref = info.resolveComponentImport(cfn) orelse return null;
                const op = adapter.classifyImport(ref.interface, ref.func) orelse return error.UnsupportedWasiImport;
                return .{ .host_op = op };
            },
            // Any classified `canon resource.drop` routes to the generic drop.
            .resource_drop => return .{ .host_op = .out_stream_drop },
            .alias => |t| switch (t) {
                .core_export => |ce| {
                    const prov = built[ce.instance] orelse return error.ImportUnsatisfied;
                    switch (prov) {
                        .guest => |gi| return .{ .guest_func = .{ .inst = gi, .name = ce.name } },
                        .synthetic => |se| {
                            for (se) |e| if (std.mem.eql(u8, e.name, ce.name)) return e.def;
                            return null;
                        },
                    }
                },
                else => return null,
            },
            else => return null,
        },
        .table => {
            const ref = info.resolveCoreTableExport(ex.index) orelse return null;
            const prov = built[ref.instance] orelse return error.ImportUnsatisfied;
            return switch (prov) {
                .guest => |gi| .{ .guest_table = .{ .inst = gi, .name = ref.name } },
                .synthetic => null,
            };
        },
        else => return null, // memory/global inline exports: not yet needed
    }
}

/// Pour one synthetic export into `lk` under namespace `ns` as import `e.name`.
fn defineSynth(lk: *Linker, ns: []const u8, e: SynthExport, ctx: *WasiP2Ctx) !void {
    switch (e.def) {
        .host_op => |op| try defineClassifiedFunc(lk, ns, e.name, op, ctx),
        .guest_func => |g| try lk.defineCrossModuleFunc(ns, e.name, g.inst, g.name),
        .guest_table => |g| {
            const rt = g.inst.handle.runtime orelse return error.ImportUnsatisfied;
            for (g.inst.handle.exports_storage) |exp| {
                if (exp.kind == .table and std.mem.eql(u8, exp.name, g.name)) {
                    try lk.defineTable(ns, e.name, rt.tables[exp.idx]);
                    return;
                }
            }
            return error.ImportUnsatisfied;
        },
    }
}

/// Run a single-component WASI-P2 program end-to-end. Decodes the component,
/// builds every core instance in definition order (ADR-0175 general engine),
/// then invokes the lowered `run`. Captured output lands in `host`.
pub fn runWasiP2Main(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host) anyerror!void {
    var decoded = try decode.decode(alloc, bytes);
    defer decoded.deinit(alloc);
    var info = try ctypes.decodeTypeInfo(alloc, &decoded);
    defer info.deinit();
    try cvalidate.validate(&info); // ADR-0176: reject invalid components pre-instantiate

    const run_ref = firstLiftCoreExport(&info) orelse return error.NoRunExport;
    const cis = info.core_instances.items;
    if (run_ref.instance >= cis.len) return error.NoRunExport;

    var ctx = try WasiP2Ctx.init(alloc, host);
    defer ctx.deinit();

    // Heap-stable holders (a Linker must outlive its instance; instances
    // reference each other). A synthetic-export arena outlives the build loop.
    var modules: std.ArrayList(*Module) = .empty;
    var instances: std.ArrayList(*Instance) = .empty;
    var linkers: std.ArrayList(*Linker) = .empty;
    var synth_arena = std.heap.ArenaAllocator.init(alloc);
    defer synth_arena.deinit();
    defer {
        for (instances.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (linkers.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (modules.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        instances.deinit(alloc);
        linkers.deinit(alloc);
        modules.deinit(alloc);
    }

    const built = try alloc.alloc(?Built, cis.len);
    defer alloc.free(built);
    @memset(built, null);

    for (cis, 0..) |ci, i| {
        built[i] = switch (ci) {
            .inline_exports => |exps| blk: {
                const list = try synth_arena.allocator().alloc(SynthExport, exps.len);
                var n: usize = 0;
                for (exps) |ex| {
                    const def = (try synthDef(&info, built, ex)) orelse continue;
                    list[n] = .{ .name = ex.name, .def = def };
                    n += 1;
                }
                break :blk .{ .synthetic = list[0..n] };
            },
            .instantiate => |it| blk: {
                const mb = nthCoreModule(&decoded, it.module) orelse return error.NoCoreModule;
                const mod = try alloc.create(Module);
                mod.* = try engine.compile(mb);
                try modules.append(alloc, mod);

                const lk = try alloc.create(Linker);
                lk.* = engine.linker();
                try linkers.append(alloc, lk);

                // Pour each `with` argument's instance into the linker under its
                // namespace, satisfying this module's imports.
                for (it.args) |arg| {
                    if (arg.instance >= cis.len) return error.ImportUnsatisfied;
                    const provider = built[arg.instance] orelse return error.ImportUnsatisfied;
                    switch (provider) {
                        .guest => |gi| try lk.defineInstance(arg.name, gi),
                        .synthetic => |se| for (se) |e| try defineSynth(lk, arg.name, e, &ctx),
                    }
                }

                const gi = try alloc.create(Instance);
                gi.* = try lk.instantiate(mod);
                try instances.append(alloc, gi);
                // The instance exporting cabi_realloc is the list/string
                // return-area allocator the trampolines call via nested invoke;
                // the memory-exporting instance is the lowers' bound memory.
                if (ctx.realloc_instance == null and instanceExportsFunc(gi, ctx.realloc_name))
                    ctx.realloc_instance = gi;
                if (ctx.mem_instance == null and instanceExportsMemory(gi))
                    ctx.mem_instance = gi;
                break :blk .{ .guest = gi };
            },
        };
    }

    const main_inst = switch (built[run_ref.instance].?) {
        .guest => |gi| gi,
        .synthetic => return error.NoRunExport,
    };
    var results = [_]Value{.{ .i32 = 0 }};
    main_inst.invoke(run_ref.name, &.{}, &results) catch |err| {
        // wasi:cli/exit unwinds with ProcExit after recording host.exit_code —
        // a clean termination, not a failure.
        if (err == error.ProcExit) return;
        return err;
    };
}
