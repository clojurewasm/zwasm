// FILE-SIZE-EXEMPT: WASI P2 + growing WASI-0.3 (P3) async host-peer surface; split of the P3 async host to a sibling component_wasi_p3_host.zig is planned (debt D-444), deferred so the E1..E3 host interfaces land first (per ADR-0190, ADR-0099).
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
const canon = @import("../feature/component/canon.zig");
const wit_type = @import("../feature/component/wit_type.zig");
const cvalidate = @import("../feature/component/validate.zig");
const wasi_host = @import("../wasi/host.zig");
const wasi_fd = @import("../wasi/fd.zig");
const wasi_path = @import("../wasi/path.zig");
const wasi_proc = @import("../wasi/proc.zig");
const wasi_clocks = @import("../wasi/clocks.zig");
const wasi_p1 = @import("../wasi/preview1.zig");
const p2sock = @import("../wasi/p2_sockets.zig");
const adapter = @import("../wasi/adapter.zig");
const resource_table = @import("../feature/component/resource_table.zig");
const async_mod = @import("../feature/component/async.zig");
const Caller = @import("../zwasm/caller.zig").Caller;

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const Linker = @import("../zwasm/linker.zig").Linker;
const Value = @import("../zwasm.zig").Value;
const build_options = @import("build_options");

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
/// A guest `stream.read` parked at a host source (ADR-0191 E2c): the destination
/// buffer the delivered bytes are copied into when the source becomes ready.
pub const PendingRead = struct { ptr: u32, cap: u32, elem_size: u32 = 1 };

pub const WasiP2Ctx = struct {
    host: *wasi_host.Host,
    /// One handle table keyed by resource-type id; each P2 resource the host
    /// models gets a distinct id (output-stream rep = P1 fd, descriptor rep = P1 fd).
    resources: resource_table.ResourceTable,
    /// GUEST-defined resources (D-322): handles minted by the component's
    /// own `canon resource.new/drop/rep` builtins. SEPARATE from the host
    /// `resources` table — its rt ids are the component's TYPE-SPACE
    /// indices, which would collide with the hardcoded host RT ids.
    guest_resources: resource_table.ResourceTable,
    /// Per-definition contexts for the synthesized resource builtins.
    rb_ctxs: std.ArrayList(*ResourceBuiltinCtx) = .empty,
    /// Resolved guest-resource destructors (type-space index -> core func).
    guest_dtors: std.ArrayList(GuestDtor) = .empty,
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
    /// Allocator backing `dir_streams` (the per-run cursor state below).
    alloc: Allocator,
    /// Live directory-entry-stream cursors; a DIR_STREAM_RT handle's rep
    /// indexes this list.
    dir_streams: std.ArrayList(DirStream) = .empty,
    /// Live tcp sockets (ADR-0180); a TCP_SOCKET_RT / SOCK_*_STREAM_RT /
    /// SOCK_POLLABLE_RT handle's rep (low bits) indexes this list.
    tcp_sockets: std.ArrayList(p2sock.TcpSocket) = .empty,
    /// CM-async (WASI 0.3, ADR-0189 ζ2): the value the async task delivered via
    /// `canon task.return` — surfaced to the P3 runner after the callback loop
    /// exits. Minimal single-`i32`-lowered-result form; typed/multi-value is a
    /// later ζ2 slice. `null` until the guest calls `task.return`.
    task_return: ?u32 = null,
    /// CM-async per-task state (ADR-0189 ζ2): the stream/future end handle table,
    /// the shared-rendezvous arena, and the waitable-set table. Lives here (not
    /// in the P3 runner's frame) so the canon async builtins reach it via
    /// `Caller.data`. Empty for a P2 component (P2 mints no async builtins).
    streams: async_mod.StreamFutureTable,
    shared: async_mod.SharedTable,
    sets: async_mod.WaitableSetTable,
    /// Per-definition contexts for the synthesized async builtins.
    ab_ctxs: std.ArrayList(*AsyncBuiltinCtx) = .empty,
    /// WASI 0.3 host stream peers (ADR-0190): a `SharedStream` handle whose
    /// readable end the host drains → the P1 fd it sinks to. A guest
    /// `stream.write` to such a stream COMPLETES immediately (stdout/stderr are
    /// always write-ready), the bytes marshalled to `fd`.
    host_sinks: std.AutoHashMapUnmanaged(u32, wasi_p1.Fd) = .empty,
    /// WASI 0.3 host stream SOURCES (ADR-0190, the read direction): a
    /// `SharedStream` handle whose readable end the guest reads → the P1 fd the
    /// host supplies bytes from (stdin). A guest `stream.read` pulls available
    /// bytes from `fd` into guest memory.
    host_sources: std.AutoHashMapUnmanaged(u32, wasi_p1.Fd) = .empty,
    /// WAIT-path (ADR-0191 E2c): a guest `stream.read` on a host source that is
    /// not yet ready PARKS — the read request is recorded here (keyed by the
    /// readable end handle = the waitable a set joins) and delivered at `waitOn`
    /// time. `defer_host_source_reads` forces the park branch (host policy:
    /// "source not ready yet"); default off = E3's deliver-immediately.
    pending_reads: std.AutoHashMapUnmanaged(u32, PendingRead) = .empty,
    defer_host_source_reads: bool = false,
    /// WASI 0.3 (ADR-0190): the readable end of a `future<result<_,error-code>>`
    /// that `write-via-stream`/`read-via-stream` returned. A host stream peer
    /// always succeeds, so the result future is "ok and ready" — a guest
    /// `future.read` on it COMPLETES with the `ok` discriminant (0) without a
    /// rendezvous.
    host_result_futures: std.AutoHashMapUnmanaged(u32, void) = .empty,

    /// Resource-type ids for the P2 resources the host models (`pub` for the
    /// in-tree tests that mint handles directly).
    pub const OUTPUT_STREAM_RT: u32 = 1;
    pub const DESCRIPTOR_RT: u32 = 2;
    pub const INPUT_STREAM_RT: u32 = 3;
    /// A `wasi:io/poll` pollable. Its rep is NOT a P1 fd (it carries no host
    /// resource for a synchronous always-ready host), so the generic drop must
    /// NOT `fd_close` it — see `p2ResourceDrop`.
    pub const POLLABLE_RT: u32 = 4;
    /// A `wasi:filesystem/types` directory-entry-stream. Its rep is an index
    /// into `dir_streams` (NOT a P1 fd — the stream shares the minting
    /// descriptor's fd, which the descriptor handle owns), so the generic drop
    /// must NOT `fd_close` it either.
    pub const DIR_STREAM_RT: u32 = 5;
    /// wasi:sockets (ADR-0180): a tcp-socket. Rep indexes `tcp_sockets`
    /// (NOT a P1 fd); its drop closes the OS socket via TcpSocket.deinit.
    pub const TCP_SOCKET_RT: u32 = 6;
    /// The `wasi:sockets/network` singleton (ambient network; rep unused).
    pub const NETWORK_RT: u32 = 7;
    /// Socket-backed input/output-streams minted by finish-connect. Rep
    /// indexes `tcp_sockets`; dropping a stream does NOT close the socket
    /// (the tcp-socket handle owns it).
    pub const SOCK_INPUT_STREAM_RT: u32 = 8;
    pub const SOCK_OUTPUT_STREAM_RT: u32 = 9;
    /// A socket-backed pollable (REAL readiness per ADR-0180). Rep packs
    /// `tcp_sockets` index (low 24 bits) | interest tag (high bits:
    /// 1 = read, 2 = write, 3 = either).
    pub const SOCK_POLLABLE_RT: u32 = 10;

    /// Iteration state of one live directory-entry-stream: the directory's
    /// P1 fd + the P1 readdir cookie to resume after.
    pub const DirStream = struct { fd: wasi_p1.Fd, cookie: u64 };

    pub fn init(alloc: Allocator, host: *wasi_host.Host) !WasiP2Ctx {
        return .{
            .alloc = alloc,
            .host = host,
            .resources = try resource_table.ResourceTable.init(alloc),
            .guest_resources = try resource_table.ResourceTable.init(alloc),
            .streams = try async_mod.StreamFutureTable.init(alloc),
            .shared = async_mod.SharedTable.init(alloc),
            .sets = try async_mod.WaitableSetTable.init(alloc),
        };
    }

    pub fn deinit(self: *WasiP2Ctx) void {
        if (self.host.io) |io| {
            for (self.tcp_sockets.items) |*sock| {
                if (sock.state != .closed) sock.deinit(io);
            }
        }
        self.tcp_sockets.deinit(self.alloc);
        self.dir_streams.deinit(self.alloc);
        self.resources.deinit();
        self.guest_resources.deinit();
        for (self.rb_ctxs.items) |p| self.alloc.destroy(p);
        self.rb_ctxs.deinit(self.alloc);
        self.guest_dtors.deinit(self.alloc);
        for (self.ab_ctxs.items) |p| self.alloc.destroy(p);
        self.ab_ctxs.deinit(self.alloc);
        self.host_sinks.deinit(self.alloc);
        self.host_sources.deinit(self.alloc);
        self.pending_reads.deinit(self.alloc);
        self.host_result_futures.deinit(self.alloc);
        self.streams.deinit();
        self.shared.deinit();
        self.sets.deinit();
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
        return .{ .backing = .{ .interp = rt } };
    }

    /// WAIT-path delivery (ADR-0191 E2c): for each member of `set` with a parked
    /// host-source read, copy the now-available bytes into the read's buffer and
    /// set the end's `STREAM_READ` pending event so `WaitableSet.poll` delivers
    /// it. The runner calls this just before polling at `waitOn`.
    pub fn deliverParkedReads(self: *WasiP2Ctx, set: *async_mod.WaitableSet) WasiP2Error!void {
        for (set.elems.items) |m| {
            const pr = self.pending_reads.get(m) orelse continue;
            const end = self.streams.get(m) catch continue;
            if (self.host_sources.get(end.shared) == null) continue;
            const mem = try self.memory();
            // D-335: cap is in ELEMENTS; slice cap*elem_size bytes, COMPLETE in elements.
            const buf = mem.sliceAt(pr.ptr, pr.cap * pr.elem_size) catch return WasiP2Error.OutOfBounds;
            const n: u32 = @intCast(wasi_fd.readStdinSlice(self.host, buf));
            end.state = .done;
            end.setPendingEvent(.{ .code = .stream_read, .index = m, .payload = (async_mod.ReturnCode{ .completed = @intCast(n / pr.elem_size) }).encode() });
            _ = self.pending_reads.remove(m);
        }
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

pub const WasiP2Error = error{ NoMemory, OutOfBounds, WriteFailed, NoRealloc, ReallocFailed, ProcExit, OutOfMemory, NoHostIo, Unreachable } ||
    resource_table.Error || Memory.Error || async_mod.Error;

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
        return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
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
        return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
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
    return inStreamReadImpl(caller, self_handle, len, retptr, false);
}

fn p2InStreamBlockingRead(caller: *Caller, self_handle: u32, len: u64, retptr: u32) WasiP2Error!void {
    return inStreamReadImpl(caller, self_handle, len, retptr, true);
}

fn inStreamReadImpl(caller: *Caller, self_handle: u32, len: u64, retptr: u32, blocking: bool) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const h = try ctx.resources.peek(self_handle);
    if (h.rt == WasiP2Ctx.SOCK_INPUT_STREAM_RT) return sockStreamRead(ctx, mem, h.rep, len, retptr, blocking);
    if (h.rt != WasiP2Ctx.INPUT_STREAM_RT) return resource_table.Error.TypeMismatch;
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

/// Socket-backed `input-stream.read` / `blocking-read` (ADR-0180): the
/// non-blocking read returns the EMPTY list when poll(2) reports no data
/// (the spec's would-block signal); the blocking variant waits on readiness
/// first. A 0-byte recv after readiness = peer EOF -> stream-error::closed.
fn sockStreamRead(ctx: *WasiP2Ctx, mem: Memory, rep: u32, len: u64, retptr: u32, blocking: bool) WasiP2Error!void {
    const sock = try ctxTcpSocket(ctx, rep);
    const io = try ctxIo(ctx);
    const n: u32 = @intCast(@min(len, std.math.maxInt(u32)));
    const readable = sock.ready(p2sock.POLL_IN) catch false;
    if (!readable) {
        if (!blocking) { // would-block -> ok(empty list)
            try mem.write(retptr, @as(u8, 0));
            try mem.write(retptr + 4, @as(u32, 0));
            try mem.write(retptr + 8, @as(u32, 0));
            return;
        }
        var waited: u32 = 0;
        while (!(sock.ready(p2sock.POLL_IN) catch true) and waited < 30_000) : (waited += 2) {
            io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake) catch break;
        }
    }
    const data_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    const dest = mem.sliceAt(data_ptr, n) catch return WasiP2Error.OutOfBounds;
    const got = sock.recv(io, dest) catch {
        try mem.write(retptr, @as(u8, 1)); // stream-error::closed (typed arm)
        try mem.write(retptr + 4, @as(u8, 1));
        return;
    };
    if (got == 0 and n != 0) { // EOF
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, @as(u8, 1)); // closed
        return;
    }
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, data_ptr);
    try mem.write(retptr + 8, @as(u32, @intCast(got)));
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
            return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
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
    const mem = try ctxMemory(caller);
    const bytes = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
    const h = try ctx.resources.peek(self_handle);
    if (h.rt == WasiP2Ctx.SOCK_OUTPUT_STREAM_RT) {
        // Socket-backed stream (ADR-0180): send on the connected socket; any
        // send failure surfaces as stream-error::closed (case 1, payload-free
        // — the lossy-but-typed arm; last-operation-failed needs an error
        // resource, Phase-2 scope).
        const sock = try ctxTcpSocket(ctx, h.rep);
        _ = sock.send(try ctxIo(ctx), bytes) catch {
            try mem.write(retptr, @as(u8, 1));
            try mem.write(retptr + 4, @as(u8, 1)); // stream-error::closed
            return;
        };
        try mem.write(retptr, @as(u8, 0));
        return;
    }
    if (h.rt != WasiP2Ctx.OUTPUT_STREAM_RT) return resource_table.Error.TypeMismatch;
    const fd: wasi_p1.Fd = @intCast(h.rep);
    if (wasi_fd.writeSlice(ctx.host, fd, bytes) != .success) return WasiP2Error.WriteFailed;
    try mem.write(retptr, @as(u8, 0));
}

/// The live `TcpSocket` a SOCK_* handle rep (low 24 bits) points at.
fn ctxTcpSocket(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*p2sock.TcpSocket {
    const idx = rep & 0x00FF_FFFF;
    if (idx >= ctx.tcp_sockets.items.len) return resource_table.Error.InvalidHandle;
    return &ctx.tcp_sockets.items[idx];
}

fn ctxIo(ctx: *WasiP2Ctx) WasiP2Error!std.Io {
    return ctx.host.io orelse WasiP2Error.NoHostIo;
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
        try writeP1Err(mem, retptr, 8, errno); // result align 8
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
    // carries no host fd and a directory-entry-stream borrows its descriptor's
    // fd (rep = `dir_streams` index), so those only release the handle slot.
    if (try ctx.resources.dropAny(self_handle)) |h| {
        switch (h.rt) {
            // Pollables / dir-entry-streams / networks / socket streams carry
            // no exclusively-owned host fd — only the handle slot is released.
            WasiP2Ctx.POLLABLE_RT, WasiP2Ctx.DIR_STREAM_RT, WasiP2Ctx.NETWORK_RT, WasiP2Ctx.SOCK_POLLABLE_RT, WasiP2Ctx.SOCK_INPUT_STREAM_RT, WasiP2Ctx.SOCK_OUTPUT_STREAM_RT => {},
            // The tcp-socket handle owns the OS socket.
            WasiP2Ctx.TCP_SOCKET_RT => {
                const sock = ctxTcpSocket(ctx, h.rep) catch return; // slot already gone
                if (sock.state != .closed) sock.deinit(try ctxIo(ctx));
            },
            else => _ = wasi_fd.fdClose(ctx.host, @intCast(h.rep)),
        }
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
        try writeP1Err(mem, retptr, 4, errno);
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
    const h = try ctx.resources.peek(self_handle); // validate handle (fd or socket stream)
    if (h.rt != WasiP2Ctx.OUTPUT_STREAM_RT and h.rt != WasiP2Ctx.SOCK_OUTPUT_STREAM_RT)
        return resource_table.Error.TypeMismatch;
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok (nothing buffered at this layer)
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
        try writeP1Err(mem, retptr, 1, errno);
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

const FilestatResult = union(enum) { ok: wasi_p1.Filestat, err: wasi_p1.Errno };

/// Stat the fd bound to `self` via P1 `fd_filestat_get` into a scratch buffer,
/// returning the raw `Filestat` (the shared P1→P2 front-half for stat/get-type).
fn descriptorFilestat(ctx: *WasiP2Ctx, mem: Memory, fd: wasi_p1.Fd) WasiP2Error!FilestatResult {
    const scratch = try ctx.reallocGuest(@sizeOf(wasi_p1.Filestat), 8);
    const errno = wasi_fd.fdFilestatGet(ctx.host, mem.slice(), fd, scratch);
    if (errno != .success) return .{ .err = errno };
    const bytes = mem.sliceAt(scratch, @sizeOf(wasi_p1.Filestat)) catch return WasiP2Error.OutOfBounds;
    return .{ .ok = std.mem.bytesToValue(wasi_p1.Filestat, bytes) };
}

/// Path-addressed variant: stat `path` relative to the directory fd via P1
/// `path_filestat_get` (the stat-at front-half).
fn pathFilestat(ctx: *WasiP2Ctx, mem: Memory, dirfd: wasi_p1.Fd, lookupflags: u32, path_ptr: u32, path_len: u32) WasiP2Error!FilestatResult {
    const scratch = try ctx.reallocGuest(@sizeOf(wasi_p1.Filestat), 8);
    const errno = wasi_path.pathFilestatGet(ctx.host, mem.slice(), dirfd, lookupflags, path_ptr, path_len, scratch);
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
        .err => |errno| try writeP1Err(mem, retptr, 1, errno),
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
    try writeStatResult(mem, retptr, try descriptorFilestat(ctx, mem, fd));
}

/// Store a `result<descriptor-stat, error-code>` at `retptr` (the shared
/// back-half for stat / stat-at; layout per `p2DescriptorStat`'s docstring).
fn writeStatResult(mem: Memory, retptr: u32, r: FilestatResult) WasiP2Error!void {
    switch (r) {
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
        .err => |errno| try writeP1Err(mem, retptr, 8, errno),
    }
}

/// `wasi:filesystem/types` `[method]descriptor.stat-at` (self, path_flags,
/// path_ptr, path_len, retptr): stat `path` relative to the directory
/// descriptor `self` via P1 `path_filestat_get`, honouring the P2
/// `path-flags{symlink-follow}` bit (1:1 with P1 lookupflags), then store
/// `result<descriptor-stat, error-code>` at `retptr` (same layout as `stat`).
fn p2DescriptorStatAt(caller: *Caller, self_handle: u32, path_flags: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeStatResult(mem, retptr, try pathFilestat(ctx, mem, dirfd, path_flags, path_ptr, path_len));
}

/// Write the err-arm of a filesystem `result<_, error-code>`: disc 1 at
/// `retptr`, then the D-307 P2 error-code ordinal at `retptr + off` (the
/// payload offset varies with the result's alignment: 1 / 4 / 8 across the
/// descriptor methods).
fn writeP1Err(mem: Memory, retptr: u32, off: u32, errno: wasi_p1.Errno) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + off, @intFromEnum(adapter.errnoToP2ErrorCode(errno)));
}

/// Store a `result<_, error-code>` at `retptr` — disc@0, error-code payload@1
/// (both align 1; the unit ok-arm carries no payload). The shared back-half
/// for the path-mutation `*-at` methods + `sync-data`.
fn writeUnitResult(mem: Memory, retptr: u32, errno: wasi_p1.Errno) WasiP2Error!void {
    if (errno == .success) {
        try mem.write(retptr, @as(u8, 0));
        return;
    }
    try writeP1Err(mem, retptr, 1, errno);
}

/// `wasi:filesystem/types` `[method]descriptor.create-directory-at`
/// (self, path_ptr, path_len, retptr) → P1 `path_create_directory`.
fn p2DescriptorCreateDirectoryAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathCreateDirectory(ctx.host, mem.slice(), dirfd, path_ptr, path_len));
}

/// `wasi:filesystem/types` `[method]descriptor.remove-directory-at`
/// (self, path_ptr, path_len, retptr) → P1 `path_remove_directory`.
fn p2DescriptorRemoveDirectoryAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathRemoveDirectory(ctx.host, mem.slice(), dirfd, path_ptr, path_len));
}

/// `wasi:filesystem/types` `[method]descriptor.unlink-file-at`
/// (self, path_ptr, path_len, retptr) → P1 `path_unlink_file`.
fn p2DescriptorUnlinkFileAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_fd.pathUnlinkFile(ctx.host, mem.slice(), dirfd, path_ptr, path_len));
}

/// `wasi:filesystem/types` `[method]descriptor.rename-at` (self, old_ptr,
/// old_len, new_desc, new_ptr, new_len, retptr): rename old (relative to
/// `self`) to new (relative to the borrowed `new_desc` directory descriptor)
/// via P1 `path_rename`.
fn p2DescriptorRenameAt(caller: *Caller, self_handle: u32, old_ptr: u32, old_len: u32, new_desc: u32, new_ptr: u32, new_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const old_dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const new_dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, new_desc));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathRename(ctx.host, mem.slice(), old_dirfd, old_ptr, old_len, new_dirfd, new_ptr, new_len));
}

/// `wasi:filesystem/types` `[method]descriptor.link-at` (self, old_flags,
/// old_ptr, old_len, new_desc, new_ptr, new_len, retptr): hard-link old
/// (relative to `self`, honouring `path-flags{symlink-follow}` = P1
/// lookupflags bit 0) as new (relative to `new_desc`) via P1 `path_link`.
fn p2DescriptorLinkAt(caller: *Caller, self_handle: u32, old_flags: u32, old_ptr: u32, old_len: u32, new_desc: u32, new_ptr: u32, new_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const old_dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const new_dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, new_desc));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathLink(ctx.host, mem.slice(), old_dirfd, old_flags, old_ptr, old_len, new_dirfd, new_ptr, new_len));
}

/// `wasi:filesystem/types` `[method]descriptor.symlink-at` (self, old_ptr,
/// old_len, new_ptr, new_len, retptr): create a symlink at new (relative to
/// `self`) pointing at the old-path TEXT via P1 `path_symlink`.
fn p2DescriptorSymlinkAt(caller: *Caller, self_handle: u32, old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_path.pathSymlink(ctx.host, mem.slice(), old_ptr, old_len, dirfd, new_ptr, new_len));
}

/// `wasi:filesystem/types` `[method]descriptor.sync-data` (self, retptr) →
/// P1 `fd_datasync`.
fn p2DescriptorSyncData(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    try writeUnitResult(mem, retptr, wasi_fd.fdDatasync(ctx.host, fd));
}

/// `wasi:filesystem/types` `[method]descriptor.readlink-at` (self, path_ptr,
/// path_len, retptr): read the symlink target into a `cabi_realloc`'d buffer
/// via P1 `path_readlink`, then store `result<string, error-code>` at `retptr`
/// (disc@0; ok string ptr@+4 len@+8; err code@+4).
fn p2DescriptorReadlinkAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const dirfd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const buf_len: u32 = 4096; // symlink-target cap (PATH_MAX class)
    const buf_ptr = try ctx.reallocGuest(buf_len, 1);
    const scratch = try ctx.reallocGuest(4, 4); // P1 bufused out-slot
    const errno = wasi_path.pathReadlink(ctx.host, mem.slice(), dirfd, path_ptr, path_len, buf_ptr, buf_len, scratch);
    if (errno != .success) {
        try writeP1Err(mem, retptr, 4, errno);
        return;
    }
    const used = try mem.read(u32, scratch);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 4, buf_ptr); // string data ptr
    try mem.write(retptr + 8, used); // string length
}

/// `wasi:filesystem/types` `[method]descriptor.read-directory` (self, retptr):
/// mint a directory-entry-stream over the directory descriptor `self` (state =
/// `{fd, cookie 0}` in `ctx.dir_streams`; the handle rep is the state index)
/// and store `result<own<directory-entry-stream>, error-code>` (ok handle@+4)
/// at `retptr`.
fn p2DescriptorReadDirectory(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const fd: wasi_p1.Fd = @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, self_handle));
    const mem = try ctxMemory(caller);
    const state_index: u32 = @intCast(ctx.dir_streams.items.len);
    ctx.dir_streams.append(ctx.alloc, .{ .fd = fd, .cookie = 0 }) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.DIR_STREAM_RT, state_index);
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 4, handle); // own<directory-entry-stream>
}

/// `wasi:filesystem/types` `[method]directory-entry-stream.read-directory-entry`
/// (self, retptr): read ONE entry via P1 `fd_readdir` at the stream's cookie,
/// skipping the P1-synthetic `.`/`..` (the P2 stream excludes them), then store
/// `result<option<directory-entry>, error-code>` at `retptr`: disc@0; ok option
/// disc@+4 (0 = stream end); entry record `%type`@+8, name ptr@+12, len@+16
/// (name in a fresh `cabi_realloc` backing); err code@+4.
fn p2DirEntryStreamReadEntry(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const state_index: u32 = @intCast(try ctx.resources.rep(WasiP2Ctx.DIR_STREAM_RT, self_handle));
    if (state_index >= ctx.dir_streams.items.len) return WasiP2Error.InvalidHandle;
    const state = &ctx.dir_streams.items[state_index];
    const mem = try ctxMemory(caller);
    // One dirent header (24 B) + a PATH-class name fits comfortably; P1 packs
    // as many entries as fit, we parse only the first per call.
    const buf_len: u32 = 4096;
    const buf_ptr = try ctx.reallocGuest(buf_len, 8);
    const used_ptr = try ctx.reallocGuest(4, 4);
    while (true) {
        const errno = wasi_fd.fdReaddir(ctx.host, mem.slice(), state.fd, buf_ptr, buf_len, state.cookie, used_ptr);
        if (errno != .success) {
            try writeP1Err(mem, retptr, 4, errno);
            return;
        }
        const used = try mem.read(u32, used_ptr);
        if (used < 24) { // not even one header — stream end
            try mem.write(retptr, @as(u8, 0)); // result disc: ok
            try mem.write(retptr + 4, @as(u8, 0)); // option disc: none
            return;
        }
        const d_next = try mem.read(u64, buf_ptr);
        const d_namlen = try mem.read(u32, buf_ptr + 16);
        const d_type = try mem.read(u8, buf_ptr + 20);
        if (used < 24 + d_namlen) return WasiP2Error.OutOfBounds; // truncated name (> 4 KiB path)
        state.cookie = d_next;
        const name = mem.sliceAt(buf_ptr + 24, d_namlen) catch return WasiP2Error.OutOfBounds;
        // P1 synthesizes "." / ".."; the P2 stream excludes them.
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const name_ptr = if (d_namlen == 0) 0 else try ctx.reallocGuest(d_namlen, 1);
        if (d_namlen != 0) {
            const dest = mem.sliceAt(name_ptr, d_namlen) catch return WasiP2Error.OutOfBounds;
            // Re-slice the source: reallocGuest may have moved/grown memory.
            const src = mem.sliceAt(buf_ptr + 24, d_namlen) catch return WasiP2Error.OutOfBounds;
            @memcpy(dest, src);
        }
        try mem.write(retptr, @as(u8, 0)); // result disc: ok
        try mem.write(retptr + 4, @as(u8, 1)); // option disc: some
        try mem.write(retptr + 8, filetypeToDescriptorType(@enumFromInt(d_type)));
        try mem.write(retptr + 12, name_ptr); // directory-entry.name ptr
        try mem.write(retptr + 16, d_namlen); // directory-entry.name len
        return;
    }
}

/// `wasi:random/random` `get-random-u64` `() -> u64`: 8 secure-random bytes
/// as the lowered `i64` return (no guest allocation).
fn p2RandomGetU64(caller: *Caller) WasiP2Error!i64 {
    const ctx = caller.data(WasiP2Ctx);
    var buf: [8]u8 = undefined;
    if (wasi_clocks.randomFill(ctx.host, &buf) != .success)
        return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
    return @bitCast(std.mem.readInt(u64, &buf, .little));
}

/// `wasi:random/insecure-seed` `insecure-seed` `() -> tuple<u64, u64>`: a
/// 128-bit seed for hashing. The contract permits a non-crypto source, so the
/// host's secure fill over-satisfies it. The tuple flattens past
/// MAX_FLAT_RESULTS=1 → the two u64 land at `retptr` (+0, +8).
fn p2RandomInsecureSeed(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    var buf: [16]u8 = undefined;
    if (wasi_clocks.randomFill(ctx.host, &buf) != .success)
        return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
    try mem.write(retptr, std.mem.readInt(u64, buf[0..8], .little));
    try mem.write(retptr + 8, std.mem.readInt(u64, buf[8..16], .little));
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
        try writeP1Err(mem, retptr, 4, errno);
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
fn p2Subscribe(caller: *Caller, self_handle: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    // A socket-backed stream subscribes a REAL readiness pollable (ADR-0180);
    // every other resource keeps the synchronous host's always-ready handle.
    const h = ctx.resources.peek(self_handle) catch return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
    if (h.rt == WasiP2Ctx.SOCK_INPUT_STREAM_RT)
        return ctx.resources.new(WasiP2Ctx.SOCK_POLLABLE_RT, (h.rep & 0x00FF_FFFF) | (1 << 24));
    if (h.rt == WasiP2Ctx.SOCK_OUTPUT_STREAM_RT)
        return ctx.resources.new(WasiP2Ctx.SOCK_POLLABLE_RT, (h.rep & 0x00FF_FFFF) | (2 << 24));
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

/// True iff the SOCK_POLLABLE_RT rep's socket is ready for its packed
/// interest (1 = read, 2 = write, 3 = either).
fn sockPollableReady(ctx: *WasiP2Ctx, rep: u32) bool {
    const sock = ctxTcpSocket(ctx, rep) catch return true; // dead handle never blocks a waiter
    const tag = rep >> 24;
    const interest: i16 = switch (tag) {
        1 => p2sock.POLL_IN,
        2 => p2sock.POLL_OUT,
        else => p2sock.POLL_IN | p2sock.POLL_OUT,
    };
    return sock.ready(interest) catch true;
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
    const h = try ctx.resources.peek(self_handle);
    if (h.rt == WasiP2Ctx.SOCK_POLLABLE_RT) return @intFromBool(sockPollableReady(ctx, h.rep));
    if (h.rt != WasiP2Ctx.POLLABLE_RT) return resource_table.Error.TypeMismatch;
    return 1;
}

/// `wasi:io/poll` `[method]pollable.block` (self): a synchronous host never
/// blocks — return immediately once the handle is validated.
fn p2PollableBlock(caller: *Caller, self_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const h = try ctx.resources.peek(self_handle);
    if (h.rt == WasiP2Ctx.SOCK_POLLABLE_RT) {
        const io = try ctxIo(ctx);
        var waited: u32 = 0;
        while (!sockPollableReady(ctx, h.rep) and waited < 30_000) : (waited += 2) {
            io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake) catch break;
        }
        return;
    }
    if (h.rt != WasiP2Ctx.POLLABLE_RT) return resource_table.Error.TypeMismatch;
}

/// `wasi:io/poll` `poll(in: list<borrow<pollable>>) -> list<u32>` (in_ptr,
/// in_len, retptr): every pollable is always ready, so return the full index
/// set `[0, in_len)` as a freshly `cabi_realloc`'d `list<u32>` and write
/// `(data_ptr, in_len)` at `retptr`. Each input handle is validated.
fn p2Poll(caller: *Caller, in_ptr: u32, in_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const data_ptr: u32 = if (in_len == 0) 0 else try ctx.reallocGuest(in_len * 4, 4);
    // Spec: block until >= 1 pollable is ready, then return the ready index
    // set. Non-socket pollables are always ready (synchronous host);
    // socket-backed entries consult poll(2) (ADR-0180) — so the wait loop
    // only ever engages when EVERY entry is socket-backed and idle.
    var waited: u32 = 0;
    while (true) {
        var ready_n: u32 = 0;
        var i: u32 = 0;
        while (i < in_len) : (i += 1) {
            const h = try ctx.resources.peek(try mem.read(u32, in_ptr + i * 4));
            const is_ready = if (h.rt == WasiP2Ctx.SOCK_POLLABLE_RT) sockPollableReady(ctx, h.rep) else true;
            if (is_ready) {
                try mem.write(data_ptr + ready_n * 4, i);
                ready_n += 1;
            }
        }
        if (ready_n > 0 or in_len == 0 or waited >= 30_000) {
            try mem.write(retptr, data_ptr); // list data ptr
            try mem.write(retptr + 4, ready_n); // list length
            return;
        }
        const io = try ctxIo(ctx);
        io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake) catch break;
        waited += 2;
    }
    try mem.write(retptr, data_ptr);
    try mem.write(retptr + 4, @as(u32, 0));
}

// ---- wasi:cli/environment + terminal-* + output-stream.check-write (E2) ----
//
// A sandboxed, non-tty, always-writable host. get-environment / get-arguments
// return the empty list; initial-cwd + get-terminal-* return `none`;
// check-write reports a large byte permit so the guest proceeds to write.

/// Copy `s` into a fresh `cabi_realloc` backing, returning (ptr, len).
fn allocGuestString(ctx: *WasiP2Ctx, mem: Memory, s: []const u8) WasiP2Error!struct { ptr: u32, len: u32 } {
    const n: u32 = @intCast(s.len);
    const ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n, 1);
    if (n != 0) {
        const dest = mem.sliceAt(ptr, n) catch return WasiP2Error.OutOfBounds;
        @memcpy(dest, s);
    }
    return .{ .ptr = ptr, .len = n };
}

/// `wasi:cli/environment` `get-arguments` -> `list<string>` of the host argv
/// (set via `Host.setArgs` / CLI trailing args; empty when unset).
fn p2GetArguments(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const args = ctx.host.args;
    const n: u32 = @intCast(args.len);
    const list_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n * 8, 4);
    for (args, 0..) |arg, i| {
        const str = try allocGuestString(ctx, mem, arg);
        const elem = list_ptr + @as(u32, @intCast(i)) * 8;
        try mem.write(elem, str.ptr);
        try mem.write(elem + 4, str.len);
    }
    try mem.write(retptr, list_ptr);
    try mem.write(retptr + 4, n);
}

/// `wasi:cli/environment` `get-environment` -> `list<tuple<string, string>>`
/// of the host env entries (set via `Host.setEnvs` / `--env`).
fn p2GetEnvironment(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const envs = ctx.host.envs;
    const n: u32 = @intCast(envs.len);
    const list_ptr: u32 = if (n == 0) 0 else try ctx.reallocGuest(n * 16, 4);
    for (envs, 0..) |e, i| {
        const k = try allocGuestString(ctx, mem, e.key);
        const v = try allocGuestString(ctx, mem, e.value);
        const elem = list_ptr + @as(u32, @intCast(i)) * 16;
        try mem.write(elem, k.ptr);
        try mem.write(elem + 4, k.len);
        try mem.write(elem + 8, v.ptr);
        try mem.write(elem + 12, v.len);
    }
    try mem.write(retptr, list_ptr);
    try mem.write(retptr + 4, n);
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
    const h = try ctx.resources.peek(self_handle);
    const mem = try ctxMemory(caller);
    if (h.rt == WasiP2Ctx.SOCK_OUTPUT_STREAM_RT) {
        // Socket permit is REAL (ADR-0180): writable now -> a page; else 0
        // (the guest subscribes + polls).
        const sock = try ctxTcpSocket(ctx, h.rep);
        const writable = sock.ready(p2sock.POLL_OUT) catch false;
        try mem.write(retptr, @as(u8, 0));
        try mem.write(retptr + 8, @as(u64, if (writable) 4096 else 0));
        return;
    }
    if (h.rt != WasiP2Ctx.OUTPUT_STREAM_RT) return resource_table.Error.TypeMismatch;
    try mem.write(retptr, @as(u8, 0)); // result disc: ok
    try mem.write(retptr + 8, @as(u64, 4096)); // bytes the guest may write now
}

// ---- wasi:sockets (ADR-0180 Phase 1) ----

/// `wasi:sockets/instance-network` `instance-network()` -> the ambient
/// network singleton resource.
fn p2InstanceNetwork(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.NETWORK_RT, 0);
}

/// `wasi:sockets/tcp-create-socket` `create-tcp-socket(address-family)`
/// (family, retptr) -> result<own<tcp-socket>, error-code> (ok handle@+4 /
/// err code@+4).
fn p2CreateTcpSocket(caller: *Caller, family: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fam: p2sock.AddressFamily = if (family == 0) .ipv4 else .ipv6;
    const idx: u32 = @intCast(ctx.tcp_sockets.items.len);
    ctx.tcp_sockets.append(ctx.alloc, p2sock.TcpSocket.create(fam)) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.TCP_SOCKET_RT, idx);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

/// Decode the flattened `ip-socket-address` variant (disc + 11 joined flat
/// params; ipv4 uses p0..p4, ipv6 all 11) into a host `IpAddress`.
fn decodeIpSocketAddress(disc: u32, p: [11]u32) ?std.Io.net.IpAddress {
    switch (disc) {
        0 => return .{ .ip4 = .{
            .port = @truncate(p[0]),
            .bytes = .{ @truncate(p[1]), @truncate(p[2]), @truncate(p[3]), @truncate(p[4]) },
        } },
        1 => {
            var bytes: [16]u8 = undefined;
            for (0..8) |i| {
                const seg: u16 = @truncate(p[2 + i]);
                bytes[i * 2] = @intCast(seg >> 8); // big-endian segments
                bytes[i * 2 + 1] = @truncate(seg);
            }
            return .{ .ip6 = .{ .port = @truncate(p[0]), .bytes = bytes, .flow = p[1] } };
        },
        else => return null,
    }
}

/// Write the err-arm of a sockets `result<_, error-code>`: disc 1 at `retptr`,
/// then the `wasi:sockets/network` error-code ordinal at `retptr + off` (the
/// payload offset varies with the result's alignment across the tcp methods).
fn writeSockErr(mem: Memory, retptr: u32, off: u32, e: anyerror) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + off, @intFromEnum(p2sock.errorToCode(e)));
}

/// Store a `result<_, error-code>` for a sockets op at `retptr` (disc@0,
/// `wasi:sockets/network` error-code@+1).
fn writeSockUnitResult(mem: Memory, retptr: u32, err: ?anyerror) WasiP2Error!void {
    if (err) |e| return writeSockErr(mem, retptr, 1, e);
    try mem.write(retptr, @as(u8, 0));
}

/// `tcp.start-bind` (self, network, addr-disc, p0..p10, retptr) ->
/// result<_, error-code> (err@+1).
fn p2TcpStartBind(caller: *Caller, self: u32, network: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    _ = try ctx.resources.rep(WasiP2Ctx.NETWORK_RT, network);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSockUnitResult(mem, retptr, error.InvalidArgument);
    sock.startBind(try ctxIo(ctx), addr) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.finish-bind` (self, retptr) -> result<_, error-code>.
fn p2TcpFinishBind(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    sock.finishBind() catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.start-connect` (same flat shape as start-bind) -> result<_, error-code>.
fn p2TcpStartConnect(caller: *Caller, self: u32, network: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    _ = try ctx.resources.rep(WasiP2Ctx.NETWORK_RT, network);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSockUnitResult(mem, retptr, error.InvalidArgument);
    sock.startConnect(try ctxIo(ctx), addr) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.finish-connect` (self, retptr) -> result<(own<input-stream>,
/// own<output-stream>), error-code> (ok in@+4 out@+8; err@+4). Mints the
/// socket-backed stream pair on success.
fn p2TcpFinishConnect(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    const sock = try ctxTcpSocket(ctx, rep);
    sock.finishConnect() catch |e| return writeSockErr(mem, retptr, 4, e);
    const in_h = try ctx.resources.new(WasiP2Ctx.SOCK_INPUT_STREAM_RT, rep);
    const out_h = try ctx.resources.new(WasiP2Ctx.SOCK_OUTPUT_STREAM_RT, rep);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, in_h);
    try mem.write(retptr + 8, out_h);
}

/// `tcp.subscribe` (self) -> pollable watching the socket for any activity.
fn p2TcpSubscribe(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    return ctx.resources.new(WasiP2Ctx.SOCK_POLLABLE_RT, (rep & 0x00FF_FFFF) | (3 << 24));
}

/// `tcp.shutdown` (self, how, retptr) -> result<_, error-code>. `how`:
/// 0 = receive, 1 = send, 2 = both (spec `shutdown-type` ordinals).
fn p2TcpShutdown(caller: *Caller, self: u32, how: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const dir: std.Io.net.ShutdownHow = switch (how) {
        0 => .recv,
        1 => .send,
        else => .both,
    };
    sock.shutdown(try ctxIo(ctx), dir) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.is-listening` (self) -> bool.
fn p2TcpIsListening(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    return @intFromBool(sock.state == .listening);
}

/// `tcp.start-listen` (self, retptr) -> result<_, error-code>. The OS
/// socket+bind+listen runs here (ADR-0180 Phase-2 defer-bind divergence).
fn p2TcpStartListen(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    sock.startListen(try ctxIo(ctx)) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.finish-listen` (self, retptr) -> result<_, error-code>.
fn p2TcpFinishListen(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    sock.finishListen() catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.set-listen-backlog-size` (self, value:u64, retptr) ->
/// result<_, error-code>.
fn p2TcpSetListenBacklog(caller: *Caller, self: u32, value: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    sock.setListenBacklog(value) catch |e| return writeSockUnitResult(mem, retptr, e);
    try writeSockUnitResult(mem, retptr, null);
}

/// `tcp.accept` (self, retptr) -> result<tuple<own<tcp-socket>,
/// own<input-stream>, own<output-stream>>, error-code> (ok handles
/// @+4/+8/+12; err@+4). Registers the accepted connection as a fresh
/// connected tcp-socket resource and mints its socket-backed stream pair
/// (the finish-connect shape).
fn p2TcpAccept(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const accepted = sock.accept(try ctxIo(ctx)) catch |e| return writeSockErr(mem, retptr, 4, e);
    // NOTE: append AFTER the last `sock` deref — it may move the list.
    const idx: u32 = @intCast(ctx.tcp_sockets.items.len);
    ctx.tcp_sockets.append(ctx.alloc, accepted) catch return WasiP2Error.OutOfMemory;
    const sock_h = try ctx.resources.new(WasiP2Ctx.TCP_SOCKET_RT, idx);
    const in_h = try ctx.resources.new(WasiP2Ctx.SOCK_INPUT_STREAM_RT, idx);
    const out_h = try ctx.resources.new(WasiP2Ctx.SOCK_OUTPUT_STREAM_RT, idx);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, sock_h);
    try mem.write(retptr + 8, in_h);
    try mem.write(retptr + 12, out_h);
}

/// Store a `result<ip-socket-address, error-code>` at `retptr` per the
/// canonical ABI in-memory layout: result disc@0, payload@+4; the
/// ip-socket-address variant disc@+4, case record@+8 (ipv4: port:u16@8,
/// addr bytes@10..14; ipv6: port:u16@8, flow:u32@12, segments 8*u16
/// @16..32, scope-id:u32@32).
fn writeIpSocketAddressResult(mem: Memory, retptr: u32, addr: std.Io.net.IpAddress) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 0));
    switch (addr) {
        .ip4 => |a| {
            try mem.write(retptr + 4, @as(u8, 0));
            try mem.write(retptr + 8, a.port);
            for (a.bytes, 0..) |b, i| try mem.write(retptr + 10 + @as(u32, @intCast(i)), b);
        },
        .ip6 => |a| {
            try mem.write(retptr + 4, @as(u8, 1));
            try mem.write(retptr + 8, a.port);
            try mem.write(retptr + 12, a.flow);
            for (0..8) |i| {
                const seg: u16 = (@as(u16, a.bytes[i * 2]) << 8) | a.bytes[i * 2 + 1];
                try mem.write(retptr + 16 + @as(u32, @intCast(i * 2)), seg);
            }
            try mem.write(retptr + 32, @as(u32, 0)); // scope-id (not modeled)
        },
    }
}

/// `tcp.local-address` (self, retptr) -> result<ip-socket-address, error-code>.
fn p2TcpLocalAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const addr = sock.localAddress() catch |e| return writeSockErr(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

/// `tcp.remote-address` (self, retptr) -> result<ip-socket-address, error-code>.
fn p2TcpRemoteAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
    const addr = sock.remoteAddress() catch |e| return writeSockErr(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

// -- not-supported stubs (ADR-0180 phased scope): the spec's TYPED signal --
// Each writes result.err(not-supported) at the shape's err-payload offset.

fn sockStubWriteErr(caller: *Caller, retptr: u32, comptime off: u32) WasiP2Error!void {
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + off, @intFromEnum(p2sock.ErrorCode.not_supported));
}

fn p2SockStubUnit2(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubUnit3i(caller: *Caller, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubUnit3l(caller: *Caller, _: u32, _: u64, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubUnit15(caller: *Caller, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubVal1(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 1);
}
fn p2SockStubVal4(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 4);
}
fn p2SockStubVal8(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 8);
}
fn p2SockStubVal15_4(caller: *Caller, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 4);
}
fn p2SockStubResolve(caller: *Caller, _: u32, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 4);
}
fn p2SockStubRecv(caller: *Caller, _: u32, _: u64, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 4);
}
fn p2SockStubSend(caller: *Caller, _: u32, _: u32, _: u32, retptr: u32) WasiP2Error!void {
    return sockStubWriteErr(caller, retptr, 8);
}
/// wasi:filesystem not-supported stubs (rust-std links the *-via-stream /
/// metadata methods; a CLI/TCP guest never calls them) — err(unsupported),
/// the FILESYSTEM error-code ordinal, at the shape's payload offset.
fn fsStubWriteUnsupported(caller: *Caller, retptr: u32, comptime off: u32) WasiP2Error!void {
    const mem = try ctxMemory(caller);
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + off, @intFromEnum(adapter.P2ErrorCode.unsupported));
}

fn p2FsStubViaStreamOffset(caller: *Caller, _: u32, _: u64, retptr: u32) WasiP2Error!void {
    return fsStubWriteUnsupported(caller, retptr, 4);
}
fn p2FsStubViaStream(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return fsStubWriteUnsupported(caller, retptr, 4);
}
fn p2FsStubGetFlags(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return fsStubWriteUnsupported(caller, retptr, 1);
}
fn p2FsStubMetadataHash(caller: *Caller, _: u32, retptr: u32) WasiP2Error!void {
    return fsStubWriteUnsupported(caller, retptr, 8);
}

fn p2SockStubSubscribe(caller: *Caller, _: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.resources.new(WasiP2Ctx.POLLABLE_RT, 0);
}

/// Bind the trampoline for `op` under the core import `name` in namespace
/// `module`. The name is whatever the core module imports; the trampoline is
/// chosen by the classified `op`, not by the name.
fn defineClassifiedFunc(lk: *Linker, module: []const u8, name: []const u8, op: adapter.P2Op, ctx: *WasiP2Ctx) !void {
    switch (op) {
        .cli_get_stdout => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2GetStdout),
        .cli_get_stderr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2GetStderr),
        .cli_stdout_write_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2StdoutWriteViaStream),
        .cli_stderr_write_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2StderrWriteViaStream),
        .cli_stdin_read_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2StdinReadViaStream),
        .out_stream_write, .out_stream_blocking_write_and_flush => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2OutStreamWrite),
        // Any classified `canon resource.drop` (classifyCoreExport returns
        // out_stream_drop for all) routes to the generic drop — correct for both
        // output-stream and descriptor handles (both rep = a P1 fd).
        .out_stream_drop, .fs_descriptor_drop, .in_stream_drop => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ResourceDrop),
        .cli_get_stdin => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2GetStdin),
        .in_stream_read => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2InStreamRead),
        .in_stream_blocking_read => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2InStreamBlockingRead),
        .fs_descriptor_write => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u64, u32) WasiP2Error!void, p2DescriptorWrite),
        .fs_get_directories => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2GetDirectories),
        .fs_descriptor_open_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorOpenAt),
        .cli_exit => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2Exit),
        .clocks_monotonic_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2MonotonicNow),
        .clocks_wall_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2WallNow),
        // insecure shares the secure handler: identical signature, and the host's
        // secure fill over-satisfies the insecure contract (no separate RNG state).
        .random_get_bytes, .random_insecure_get_bytes => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u64, u32) WasiP2Error!void, p2RandomGetBytes),
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
        .cli_get_environment => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2GetEnvironment),
        .cli_get_arguments => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2GetArguments),
        .cli_initial_cwd, .cli_get_terminal_stdin, .cli_get_terminal_stdout, .cli_get_terminal_stderr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ReturnNone),
        .out_stream_check_write => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2CheckWrite),
        .random_get_u64, .random_insecure_get_u64 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2RandomGetU64),
        .random_insecure_seed => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2RandomInsecureSeed),
        .fs_descriptor_stat_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorStatAt),
        .fs_descriptor_create_directory_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorCreateDirectoryAt),
        .fs_descriptor_remove_directory_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorRemoveDirectoryAt),
        .fs_descriptor_unlink_file_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorUnlinkFileAt),
        .fs_descriptor_rename_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorRenameAt),
        .fs_descriptor_link_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorLinkAt),
        .fs_descriptor_symlink_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorSymlinkAt),
        .fs_descriptor_sync_data => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorSyncData),
        .fs_descriptor_readlink_at => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorReadlinkAt),
        .fs_descriptor_read_directory => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DescriptorReadDirectory),
        .fs_dir_entry_stream_read => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2DirEntryStreamReadEntry),
        .fs_dir_entry_stream_drop => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ResourceDrop),
        .io_resource_drop => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ResourceDrop),
        .fs_stub_via_stream_offset => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2FsStubViaStreamOffset),
        .fs_stub_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2FsStubViaStream),
        .fs_stub_get_flags => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2FsStubGetFlags),
        .fs_stub_metadata_hash => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2FsStubMetadataHash),
        .sock_instance_network => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, p2InstanceNetwork),
        .sock_create_tcp => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2CreateTcpSocket),
        .sock_tcp_start_bind => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2TcpStartBind),
        .sock_tcp_finish_bind => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpFinishBind),
        .sock_tcp_start_connect => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2TcpStartConnect),
        .sock_tcp_finish_connect => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpFinishConnect),
        .sock_tcp_subscribe => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2TcpSubscribe),
        .sock_tcp_shutdown => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, p2TcpShutdown),
        .sock_tcp_is_listening => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2TcpIsListening),
        .sock_tcp_start_listen => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpStartListen),
        .sock_tcp_finish_listen => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpFinishListen),
        .sock_tcp_accept => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpAccept),
        .sock_tcp_local_address => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpLocalAddress),
        .sock_tcp_remote_address => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2TcpRemoteAddress),
        .sock_tcp_set_backlog => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2TcpSetListenBacklog),
        .sock_tcp_drop => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ResourceDrop),
        .sock_stub_unit2 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2SockStubUnit2),
        .sock_stub_unit3i => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, p2SockStubUnit3i),
        .sock_stub_unit3l => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2SockStubUnit3l),
        .sock_stub_unit15 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2SockStubUnit15),
        .sock_stub_val1 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2SockStubVal1),
        .sock_stub_val4 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2SockStubVal4),
        .sock_stub_val8 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2SockStubVal8),
        .sock_stub_val15_4 => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2SockStubVal15_4),
        .sock_stub_resolve => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2SockStubResolve),
        .sock_stub_recv => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, p2SockStubRecv),
        .sock_stub_send => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2SockStubSend),
        .sock_stub_subscribe => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2SockStubSubscribe),
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
    /// A synthesized `canon resource.new/drop/rep` builtin for a
    /// GUEST-defined resource (D-322); `type_index` keys the handle table.
    resource_builtin: struct { kind: ResourceBuiltinKind, type_index: u32 },
    /// `canon task.return` (WASI 0.3, ADR-0189 ζ2): the async task's
    /// result-delivery import; the trampoline records the value in
    /// `WasiP2Ctx.task_return`.
    task_return_builtin,
    /// A `canon stream.*`/`future.*` builtin (WASI 0.3, ADR-0189 ζ2). `op`
    /// selects the trampoline; `type_index` is the stream/future type. Slice 2
    /// wires `stream.new`/`future.new`; the rest are a later slice.
    async_builtin: struct { op: ctypes.StreamFutureOp, type_index: u32, elem_size: u32 = 1 },
    /// A `canon waitable-set.new` / `waitable.join` builtin (WASI 0.3, ADR-0190
    /// E2b) on the per-task `WaitableSetTable`. `wait`/`poll`/`drop` defer.
    waitable_set_builtin: ctypes.WaitableSetOp,
};

/// Per-definition context for a synthesized async builtin (mirrors
/// `ResourceBuiltinCtx`): the heap-stable ctx + the stream/future type index.
pub const AsyncBuiltinCtx = struct { ctx: *WasiP2Ctx, type_index: u32, elem_size: u32 = 1 };

const ResourceBuiltinKind = enum { new, drop, rep };

pub const ResourceBuiltinCtx = struct { ctx: *WasiP2Ctx, type_index: u32 };

pub const GuestDtor = struct { type_index: u32, inst: *Instance, name: []const u8 };

/// Is type-space entry `ti` a locally-DEFINED resource type (vs an
/// imported/host one)?
fn isGuestResourceType(info: *const ctypes.TypeInfo, ti: u32) bool {
    if (ti >= info.type_space.items.len) return false;
    return switch (info.type_space.items[ti]) {
        .def => |d| info.deftypes.items[d] == .resource,
        .named => false,
    };
}
/// D-335: lowered byte size of a `stream<T>`/`future<T>`'s element type `T`,
/// for typed multi-byte marshalling. Returns 1 (byte semantics) for a
/// payload-less stream/future, a non-stream `type_index`, or any resolution
/// failure. `arena` (the build's synth_arena) owns any compound CanonType.
fn streamElemByteSize(arena: Allocator, info: *const ctypes.TypeInfo, type_index: u32) u32 {
    const resolved = canon.resolveTypeIndex(arena, info, type_index) catch return 1;
    const payload: ?ctypes.ValType = switch (resolved.dt) {
        .stream => |s| s.payload,
        .future => |f| f.payload,
        else => return 1,
    };
    const p = payload orelse return 1;
    const ct = canon.canonTypeFromDecoded(arena, info, p) catch return 1;
    const sz = canon.sizeOf(ct);
    return if (sz == 0) 1 else @intCast(sz);
}

const SynthExport = struct { name: []const u8, def: Def };
const Built = union(enum) { guest: *Instance, synthetic: []const SynthExport };

/// Resolve one `core:inlineexport` to the `Def` an importer should bind, or
/// null when it is not a host-relevant export (skipped). `built` holds the
/// already-constructed earlier instances (aliases only reference those).
fn synthDef(arena: Allocator, info: *const ctypes.TypeInfo, built: []const ?Built, ex: ctypes.CoreInlineExport) !?Def {
    switch (ex.sort) {
        .func => switch (info.coreFunc(ex.index) orelse return null) {
            .lower => |cfn| {
                const ref = info.resolveComponentImport(cfn) orelse return null;
                const op = adapter.classifyImport(ref.interface, ref.func) orelse return error.UnsupportedWasiImport;
                return .{ .host_op = op };
            },
            .resource_new => |ti| return .{ .resource_builtin = .{ .kind = .new, .type_index = ti } },
            .resource_rep => |ti| return .{ .resource_builtin = .{ .kind = .rep, .type_index = ti } },
            // A drop of a GUEST-defined resource goes through its own handle
            // table (+ dtor); drops of imported host resources keep the
            // generic stream-drop route.
            .resource_drop => |ti| {
                if (isGuestResourceType(info, ti)) return .{ .resource_builtin = .{ .kind = .drop, .type_index = ti } };
                return .{ .host_op = .out_stream_drop };
            },
            // task.return (CM-async) is satisfied by the P3 runner's host
            // builtin (ADR-0189 ζ2); it records the task's delivered result.
            .task_return => return .task_return_builtin,
            // waitable-set.new/join are host-wired (ADR-0190 E2b); wait/poll are
            // the stackful path (zwasm stackless re-enters via the callback WAIT
            // return, not a guest wait call), drop defers — fail loudly.
            .waitable_set => |ws| switch (ws.op) {
                .new, .join => return .{ .waitable_set_builtin = ws.op },
                .wait, .poll, .drop => return error.UnsupportedWasiImport,
            },
            // stream.new/future.new are wired (ADR-0189 ζ2 Slice 2); the rest of
            // the stream/future builtins (read/write/cancel/drop) land in a later
            // slice — fail loudly rather than silently mis-bind until then.
            // all stream/future builtins are now host-satisfied (ADR-0189 ζ2);
            // a guest-to-guest read/write COMPLETION still needs a peer (Unit E).
            // D-335: `type_index` is the `stream<T>`/`future<T>` TYPE; resolve
            // its payload T's lowered byte size for typed multi-byte marshalling
            // (default 1 = payload-less / u8 / unresolvable).
            .stream_future => |sf| return .{ .async_builtin = .{ .op = sf.op, .type_index = sf.type_index, .elem_size = streamElemByteSize(arena, info, sf.type_index) } },
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

/// `canon resource.new` for a guest-defined resource: store the rep, mint
/// an OWN handle in the component's guest table.
fn p2GuestResourceNew(caller: *Caller, rep_val: u32) WasiP2Error!u32 {
    const rbc = caller.data(ResourceBuiltinCtx);
    return rbc.ctx.guest_resources.new(rbc.type_index, rep_val);
}

/// `canon resource.rep`: handle -> stored representation.
fn p2GuestResourceRep(caller: *Caller, handle: u32) WasiP2Error!u32 {
    const rbc = caller.data(ResourceBuiltinCtx);
    return rbc.ctx.guest_resources.rep(rbc.type_index, handle);
}

/// `canon resource.drop`: remove the handle; an OWN handle additionally
/// runs the resource's declared destructor over the rep.
fn p2GuestResourceDrop(caller: *Caller, handle: u32) WasiP2Error!void {
    const rbc = caller.data(ResourceBuiltinCtx);
    const rep_opt = try rbc.ctx.guest_resources.drop(rbc.type_index, handle);
    if (rep_opt) |rep_val| {
        for (rbc.ctx.guest_dtors.items) |gd| {
            if (gd.type_index != rbc.type_index) continue;
            var args = [_]Value{.{ .i32 = @bitCast(rep_val) }};
            gd.inst.invoke(gd.name, &args, &.{}) catch return WasiP2Error.WriteFailed;
            break;
        }
    }
}

/// `canon task.return` (WASI 0.3, ADR-0189 ζ2): record the value the async task
/// delivered as its result. Minimal single-`i32`-lowered-result form; the P3
/// runner reads `ctx.task_return` after the callback loop exits.
fn p2TaskReturn(caller: *Caller, val: i32) WasiP2Error!void {
    caller.data(WasiP2Ctx).task_return = @bitCast(val);
}

/// `canon stream.new` (ADR-0189 ζ2): mint a readable+writable end pair over a
/// fresh shared rendezvous; return the spec's packed `ri | (wi << 32)`.
fn p2StreamNew(caller: *Caller) WasiP2Error!u64 {
    const abc = caller.data(AsyncBuiltinCtx);
    const pair = try async_mod.newStreamPair(&abc.ctx.streams, &abc.ctx.shared, abc.type_index);
    return @as(u64, pair.readable) | (@as(u64, pair.writable) << 32);
}

/// `canon future.new` — symmetric to `p2StreamNew`.
fn p2FutureNew(caller: *Caller) WasiP2Error!u64 {
    const abc = caller.data(AsyncBuiltinCtx);
    const pair = try async_mod.newFuturePair(&abc.ctx.streams, &abc.ctx.shared, abc.type_index);
    return @as(u64, pair.readable) | (@as(u64, pair.writable) << 32);
}

/// `wasi:cli/stdout.write-via-stream` (WASI 0.3, ADR-0190): the host becomes the
/// readable end's reader, sinking to a P1 fd. Register the host sink keyed by
/// the stream's `SharedStream` handle (a guest `stream.write` then COMPLETES into
/// it), and return a fresh future handle (the spec's `future<result<_, error>>`;
/// its resolution is a later E-slice — the guest may drop it).
fn p2WriteViaStream(caller: *Caller, stream_handle: u32, fd: wasi_p1.Fd) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const end = try ctx.streams.get(stream_handle);
    try ctx.host_sinks.put(ctx.alloc, end.shared, fd);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, {}); // host always succeeds → ok future
    return fut.readable;
}

fn p2StdoutWriteViaStream(caller: *Caller, stream_handle: u32) WasiP2Error!u32 {
    return p2WriteViaStream(caller, stream_handle, 1);
}

fn p2StderrWriteViaStream(caller: *Caller, stream_handle: u32) WasiP2Error!u32 {
    return p2WriteViaStream(caller, stream_handle, 2);
}

/// `wasi:cli/stdin.read-via-stream` (WASI 0.3, ADR-0190): the host becomes the
/// stream's WRITER (supplying bytes from a P1 fd). Mint a stream pair + a future
/// and write the `tuple<stream<u8>, future<result<_,error-code>>>` result to the
/// guest's return pointer `retptr` (the tuple flattens past MAX_FLAT_RESULTS=1 →
/// a memory return: `ri` at `retptr`, the future handle at `retptr+4`). The
/// readable end is registered as a host source so a guest `stream.read` pulls
/// bytes from `fd` (stdin).
fn p2StdinReadViaStream(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    try ctx.host_sources.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, 0); // fd 0 = stdin
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, {}); // host always succeeds → ok future
    const mem = try ctx.memory();
    try mem.write(retptr, pair.readable);
    try mem.write(retptr + 4, fut.readable);
}

/// `canon waitable-set.new` (ADR-0190 E2b): mint an empty waitable set.
fn p2WaitableSetNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.sets.add(async_mod.WaitableSet.init(ctx.alloc));
}

/// `canon waitable.join` (ADR-0190 E2b): add a waitable handle to a set.
fn p2WaitableJoin(caller: *Caller, set_handle: u32, waitable: u32) WasiP2Error!void {
    return p2WaitableJoinInner(caller, set_handle, waitable) catch |e| mapAsyncFault(e);
}
fn p2WaitableJoinInner(caller: *Caller, set_handle: u32, waitable: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const set = try ctx.sets.get(set_handle); // bad set handle = guest fault → trap
    try set.join(waitable);
}

/// Map a WASI-P2 async-builtin error to the host-fn surface (D-445). A guest
/// supplies the handle/ptr, so a bad handle, illegal drop/cancel sequencing,
/// an exhausted table, or an out-of-bounds buffer is a GUEST fault → surface
/// the canonical guest trap (`error.Unreachable`), which `mapDispatchErr`
/// narrows cleanly. Without this those un-narrowed variants would hit
/// `mapDispatchErr`'s `else => @panic` and abort the host on guest input.
/// Genuine host failures (NoMemory, realloc, host I/O, OOM) propagate unchanged.
fn mapAsyncFault(e: WasiP2Error) WasiP2Error {
    return switch (e) {
        error.InvalidHandle,
        error.TableFull,
        error.CopyInProgress,
        error.NotCopying,
        error.InvalidCallbackCode,
        error.FutureDropBeforeWrite,
        error.CopyNotIdle,
        error.OutOfBounds,
        => error.Unreachable,
        else => |other| other,
    };
}

/// `canon stream.read`/`stream.write` (+ future) (ADR-0189 ζ2, re-scoped per
/// lesson 2026-06-16): drive one rendezvous step on the end named by `handle`
/// (`StreamFutureEnd.copy` dispatches read vs write on the end's side) and
/// return the packed `ReturnCode`. Single-task reaches only BLOCKED (no peer
/// ready) or DROPPED (peer dropped first); a count > 0 COMPLETION needs a host
/// stream peer (Unit E) — that path also wires the element marshalling at
/// `ptr`, so it traps here until then (unreachable single-task).
fn p2StreamFutureCopy(caller: *Caller, handle: u32, ptr: u32, count: u32) WasiP2Error!u32 {
    return p2StreamFutureCopyInner(caller, handle, ptr, count) catch |e| mapAsyncFault(e);
}
fn p2StreamFutureCopyInner(caller: *Caller, handle: u32, ptr: u32, count: u32) WasiP2Error!u32 {
    const abc = caller.data(AsyncBuiltinCtx);
    const end = try abc.ctx.streams.get(handle);
    // Host result future (ADR-0190): the `future<result<_,error-code>>` returned
    // by write/read-via-stream. A host stream peer always succeeds → a guest
    // `future.read` COMPLETES with the `ok` discriminant (0, 1 byte) — no
    // rendezvous, no general typed marshalling.
    if (abc.ctx.host_result_futures.contains(handle)) {
        const mem = try abc.ctx.memory();
        const buf = mem.sliceAt(ptr, 1) catch return WasiP2Error.OutOfBounds;
        buf[0] = 0; // result<_, error-code> ok
        return (async_mod.ReturnCode{ .completed = 1 }).encode();
    }
    // Host stream peer (Unit E, ADR-0190): the host is the always-ready reader,
    // so a guest write COMPLETES immediately — marshal the `count` u8s from guest
    // memory at `ptr` to the sink fd (the deferred ζ2 COMPLETION + marshalling).
    if (end.side == .writable) {
        if (abc.ctx.host_sinks.get(end.shared)) |fd| {
            const mem = try abc.ctx.memory();
            // D-335: `count` is in ELEMENTS; the byte span is count * elem_size.
            const bytes = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
            if (wasi_fd.writeSlice(abc.ctx.host, fd, bytes) != .success) return WasiP2Error.WriteFailed;
            return (async_mod.ReturnCode{ .completed = @intCast(count) }).encode();
        }
    }
    // Host stream SOURCE (Unit E3, the read direction): the host supplies bytes
    // from `fd` (stdin) → a guest read COMPLETES with the available count copied
    // into guest memory at `ptr`.
    if (end.side == .readable) {
        if (abc.ctx.host_sources.get(end.shared)) |_| {
            // WAIT-path (ADR-0191 E2c): when the source is "not ready", PARK —
            // record the read + return BLOCKED; the bytes are delivered at the
            // next `waitOn` (the guest reaches it after returning WAIT).
            if (abc.ctx.defer_host_source_reads) {
                try abc.ctx.pending_reads.put(abc.ctx.alloc, handle, .{ .ptr = ptr, .cap = count, .elem_size = abc.elem_size });
                end.state = .async_copying;
                return (async_mod.ReturnCode{ .blocked = {} }).encode();
            }
            const mem = try abc.ctx.memory();
            // D-335: `count` is in ELEMENTS; slice count*elem_size bytes, and
            // COMPLETE in elements (n bytes read / elem_size).
            const buf = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
            const n: u32 = @intCast(wasi_fd.readStdinSlice(abc.ctx.host, buf));
            return (async_mod.ReturnCode{ .completed = @intCast(n / abc.elem_size) }).encode();
        }
    }
    const sh = try abc.ctx.shared.get(end.shared);
    const step = switch (sh.*) {
        .stream => |*s| try end.copy(s, &abc.ctx.streams, handle, count),
        .future => |*f| try end.copy(f, &abc.ctx.streams, handle, count),
    };
    return switch (step.caller) {
        .blocked => (async_mod.ReturnCode{ .blocked = {} }).encode(),
        .dropped => (async_mod.ReturnCode{ .dropped = 0 }).encode(),
        // n==0 moves no bytes; n>0 needs marshalling at `ptr` (Unit E) and is
        // unreachable in the single-task model (no concurrent peer with data).
        .completed => |n| if (n == 0) (async_mod.ReturnCode{ .completed = 0 }).encode() else error.OutOfBounds,
    };
}

/// `canon stream.cancel-{read,write}` / `future.cancel-{read,write}` (ADR-0189
/// ζ2): cancel an async copy in flight on the end named by `handle`
/// (`StreamFutureEnd.cancel` traps `NotCopying` unless the end is async-copying)
/// and return the packed `ReturnCode.cancelled` (count of elements transferred
/// before cancel — 0 for a still-blocked copy).
fn p2StreamFutureCancel(caller: *Caller, handle: u32) WasiP2Error!u32 {
    return p2StreamFutureCancelInner(caller, handle) catch |e| mapAsyncFault(e);
}
fn p2StreamFutureCancelInner(caller: *Caller, handle: u32) WasiP2Error!u32 {
    const abc = caller.data(AsyncBuiltinCtx);
    const end = try abc.ctx.streams.get(handle);
    const sh = try abc.ctx.shared.get(end.shared);
    const n = switch (sh.*) {
        .stream => |*s| try end.cancel(s),
        .future => |*f| try end.cancel(f),
    };
    return (async_mod.ReturnCode{ .cancelled = @intCast(n) }).encode();
}

/// `canon stream.drop-{readable,writable}` / `future.drop-{readable,writable}`
/// (ADR-0189 ζ2): mark the shared rendezvous dropped (so a blocked peer observes
/// DROPPED — traps if a copy is mid-flight) then release the end + its shared ref
/// (freed when the second end drops).
fn p2StreamFutureDrop(caller: *Caller, handle: u32) WasiP2Error!void {
    return p2StreamFutureDropInner(caller, handle) catch |e| mapAsyncFault(e);
}
fn p2StreamFutureDropInner(caller: *Caller, handle: u32) WasiP2Error!void {
    const abc = caller.data(AsyncBuiltinCtx);
    // Shared drop contract: future-writable-before-write traps
    // (FutureDropBeforeWrite, mapAsyncFault → guest trap) + marks the rendezvous
    // DROPPED for the surviving peer (same helper the graph path uses).
    try async_mod.dropEndGuarded(&abc.ctx.streams, &abc.ctx.shared, handle);
}

/// Pour one synthetic export into `lk` under namespace `ns` as import `e.name`.
fn defineSynth(lk: *Linker, ns: []const u8, e: SynthExport, ctx: *WasiP2Ctx) !void {
    switch (e.def) {
        .host_op => |op| try defineClassifiedFunc(lk, ns, e.name, op, ctx),
        .resource_builtin => |rb| {
            const rbc = try ctx.alloc.create(ResourceBuiltinCtx);
            errdefer ctx.alloc.destroy(rbc);
            rbc.* = .{ .ctx = ctx, .type_index = rb.type_index };
            try ctx.rb_ctxs.append(ctx.alloc, rbc);
            switch (rb.kind) {
                .new => try lk.defineFuncCtx(ns, e.name, @ptrCast(rbc), fn (*Caller, u32) WasiP2Error!u32, p2GuestResourceNew),
                .drop => try lk.defineFuncCtx(ns, e.name, @ptrCast(rbc), fn (*Caller, u32) WasiP2Error!void, p2GuestResourceDrop),
                .rep => try lk.defineFuncCtx(ns, e.name, @ptrCast(rbc), fn (*Caller, u32) WasiP2Error!u32, p2GuestResourceRep),
            }
        },
        .task_return_builtin => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, i32) WasiP2Error!void, p2TaskReturn),
        .waitable_set_builtin => |op| switch (op) {
            .new => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller) WasiP2Error!u32, p2WaitableSetNew),
            .join => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2WaitableJoin),
            .wait, .poll, .drop => unreachable, // synthDef rejects these
        },
        .async_builtin => |ab| {
            const abc = try ctx.alloc.create(AsyncBuiltinCtx);
            errdefer ctx.alloc.destroy(abc);
            abc.* = .{ .ctx = ctx, .type_index = ab.type_index, .elem_size = ab.elem_size };
            try ctx.ab_ctxs.append(ctx.alloc, abc);
            switch (ab.op) {
                .stream_new => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller) WasiP2Error!u64, p2StreamNew),
                .future_new => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller) WasiP2Error!u64, p2FutureNew),
                .stream_drop_readable, .stream_drop_writable, .future_drop_readable, .future_drop_writable => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller, u32) WasiP2Error!void, p2StreamFutureDrop),
                .stream_read, .stream_write, .future_read, .future_write => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller, u32, u32, u32) WasiP2Error!u32, p2StreamFutureCopy),
                .stream_cancel_read, .stream_cancel_write, .future_cancel_read, .future_cancel_write => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller, u32) WasiP2Error!u32, p2StreamFutureCancel),
            }
        },
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

/// A fully-BUILT component instance graph (ADR-0175) with its WASI-P2 host
/// wiring intact — the reusable seam under `runWasiP2Main` and the typed
/// embedder invoke (ADR-0183 F3: real-toolchain components import wasi, so
/// typed calls need the same build the CLI run uses).
/// REQ-5 — the failure set of `BuiltComponent.dropResource`: the resource
/// table's own errors (stale handle / still-borrowed) plus a guest
/// destructor trap.
pub const DropResourceError = resource_table.Error || error{DestructorTrapped};

pub const BuiltComponent = struct {
    alloc: Allocator,
    /// Owned copy of the component bytes — `decoded`, its `info` names, and the
    /// core `modules` slice it, so the build is self-contained vs the caller's
    /// load buffer (REQ-7 / D-326).
    owned_bytes: []const u8,
    decoded: decode.Component,
    info: ctypes.TypeInfo,
    /// Heap-stable: trampolines hold this pointer for the build's lifetime.
    ctx: *WasiP2Ctx,
    modules: std.ArrayList(*Module) = .empty,
    instances: std.ArrayList(*Instance) = .empty,
    linkers: std.ArrayList(*Linker) = .empty,
    synth_arena: std.heap.ArenaAllocator,
    built: []?Built,

    pub fn deinit(self: *BuiltComponent) void {
        const alloc = self.alloc;
        for (self.instances.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (self.linkers.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (self.modules.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        self.instances.deinit(alloc);
        self.linkers.deinit(alloc);
        self.modules.deinit(alloc);
        alloc.free(self.built);
        self.synth_arena.deinit();
        self.ctx.deinit();
        alloc.destroy(self.ctx);
        self.info.deinit();
        self.decoded.deinit(alloc);
        alloc.free(self.owned_bytes);
    }

    /// REQ-3 (cw CM-API) — introspect a func export's full typed signature
    /// to the `WitType` tree (specialization-preserving + labels). `arena`
    /// owns the tree; names borrow from this build's `TypeInfo`. Mirrors
    /// `ComponentInstance.resolveFuncSig` for the WASI-P2 graph path.
    pub fn resolveFuncSig(self: *const BuiltComponent, arena: Allocator, name: []const u8) wit_type.Error!?wit_type.FuncSig {
        return wit_type.resolveFuncSig(arena, &self.info, name);
    }

    /// REQ-5 (cw CM-API) — host-facing drop of a guest-defined resource
    /// `handle` (typically an `own` handle a host cached from a constructor
    /// result and frees in a finaliser). Removes it from the guest resource
    /// table and, for an `own` handle, runs the resource's declared
    /// destructor over its rep — the same effect as the guest calling
    /// `canon resource.drop`, but driven from the host without knowing the
    /// resource type (the table's stored `rt` selects the destructor).
    /// Traps on a stale/double-drop or a still-borrowed owning handle.
    pub fn dropResource(self: *BuiltComponent, handle: u32) DropResourceError!void {
        const removed = try self.ctx.guest_resources.dropAny(handle);
        if (removed) |h| {
            for (self.ctx.guest_dtors.items) |gd| {
                if (gd.type_index != h.rt) continue;
                var args = [_]Value{.{ .i32 = @bitCast(h.rep) }};
                gd.inst.invoke(gd.name, &args, &.{}) catch return DropResourceError.DestructorTrapped;
                break;
            }
        }
    }

    /// The guest `*Instance` a core-instance index resolved to (null for
    /// synthetic instances / out of range).
    pub fn guestInstance(self: *const BuiltComponent, index: u32) ?*Instance {
        if (index >= self.built.len) return null;
        const b = self.built[index] orelse return null;
        return switch (b) {
            .guest => |gi| gi,
            .synthetic => null,
        };
    }
};

/// Decode + validate + build EVERY core instance of `bytes` in definition
/// order with the WASI-P2 host wiring (the ADR-0175 general engine,
/// extracted from `runWasiP2Main`). Caller owns the result (`deinit`).
/// `opts` is the per-instance budget applied to every guest instance
/// (REQ-4, cw CM-API); pass `.{}` for the default budget.
pub fn buildWasiP2Component(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: Module.InstantiateOpts) anyerror!BuiltComponent {
    // Own the bytes so the build is self-contained (REQ-7 / D-326).
    const owned_bytes = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned_bytes);

    var decoded = try decode.decode(alloc, owned_bytes);
    errdefer decoded.deinit(alloc);
    var info = try ctypes.decodeTypeInfo(alloc, &decoded);
    errdefer info.deinit();
    try cvalidate.validate(&info); // ADR-0176: reject invalid components pre-instantiate

    const cis = info.core_instances.items;

    const ctx = try alloc.create(WasiP2Ctx);
    errdefer alloc.destroy(ctx);
    ctx.* = try WasiP2Ctx.init(alloc, host);
    errdefer ctx.deinit();

    var self: BuiltComponent = .{
        .alloc = alloc,
        .owned_bytes = owned_bytes,
        .decoded = decoded,
        .info = info,
        .ctx = ctx,
        .synth_arena = std.heap.ArenaAllocator.init(alloc),
        .built = try alloc.alloc(?Built, cis.len),
    };
    @memset(self.built, null);
    errdefer {
        // Tear down only what THIS fn built; decoded/info/ctx have their own
        // errdefers above (self.deinit would double-free them on early error).
        for (self.instances.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (self.linkers.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        for (self.modules.items) |p| {
            p.deinit();
            alloc.destroy(p);
        }
        self.instances.deinit(alloc);
        self.linkers.deinit(alloc);
        self.modules.deinit(alloc);
        alloc.free(self.built);
        self.synth_arena.deinit();
    }

    for (cis, 0..) |ci, i| {
        self.built[i] = switch (ci) {
            .inline_exports => |exps| blk: {
                const list = try self.synth_arena.allocator().alloc(SynthExport, exps.len);
                var n: usize = 0;
                for (exps) |ex| {
                    const def = (try synthDef(self.synth_arena.allocator(), &self.info, self.built, ex)) orelse continue;
                    list[n] = .{ .name = ex.name, .def = def };
                    n += 1;
                }
                break :blk .{ .synthetic = list[0..n] };
            },
            .instantiate => |it| blk: {
                const mb = nthCoreModule(&self.decoded, it.module) orelse return error.NoCoreModule;
                const mod = try alloc.create(Module);
                mod.* = try engine.compile(mb);
                try self.modules.append(alloc, mod);

                const lk = try alloc.create(Linker);
                lk.* = engine.linker();
                try self.linkers.append(alloc, lk);

                // Pour each `with` argument's instance into the linker under
                // its namespace, satisfying this module's imports.
                for (it.args) |arg| {
                    if (arg.instance >= cis.len) return error.ImportUnsatisfied;
                    const provider = self.built[arg.instance] orelse return error.ImportUnsatisfied;
                    switch (provider) {
                        .guest => |gi| try lk.defineInstance(arg.name, gi),
                        .synthetic => |se| for (se) |e| try defineSynth(lk, arg.name, e, ctx),
                    }
                }

                const gi = try alloc.create(Instance);
                gi.* = try lk.instantiate(mod, opts);
                try self.instances.append(alloc, gi);
                // The instance exporting cabi_realloc is the list/string
                // return-area allocator the trampolines call via nested
                // invoke; the memory-exporting instance is the lowers' bound
                // memory.
                if (ctx.realloc_instance == null and instanceExportsFunc(gi, ctx.realloc_name))
                    ctx.realloc_instance = gi;
                if (ctx.mem_instance == null and instanceExportsMemory(gi))
                    ctx.mem_instance = gi;
                break :blk .{ .guest = gi };
            },
        };
    }

    // Resolve guest-resource destructors (D-322): a resource deftype's
    // `dtor` is a core-func index — chase it to the exporting guest
    // instance so `canon resource.drop` can run it on own-handle drops.
    for (info.type_space.items, 0..) |entry, ti| {
        const d = switch (entry) {
            .def => |d| d,
            .named => continue,
        };
        const rt = switch (info.deftypes.items[d]) {
            .resource => |r| r,
            else => continue,
        };
        const dtor_idx = rt.dtor orelse continue;
        const cf = info.coreFunc(dtor_idx) orelse continue;
        switch (cf) {
            .alias => |t| switch (t) {
                .core_export => |ce| {
                    const prov = self.built[ce.instance] orelse continue;
                    switch (prov) {
                        .guest => |gi| try ctx.guest_dtors.append(alloc, .{
                            .type_index = @intCast(ti),
                            .inst = gi,
                            .name = ce.name,
                        }),
                        .synthetic => {},
                    }
                },
                else => {},
            },
            else => {},
        }
    }
    return self;
}

pub fn runWasiP2Main(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: Module.InstantiateOpts) anyerror!void {
    var built = try buildWasiP2Component(engine, alloc, bytes, host, opts);
    defer built.deinit();
    try runWasiP2MainBuilt(&built);
}

/// The post-build half of `runWasiP2Main` (the sync `wasi:cli/run` path):
/// invoke the first `canon lift` export. Split out so the unified
/// `runWasiMain` dispatcher (P3) can reuse it after building once.
pub fn runWasiP2MainBuilt(built: *BuiltComponent) anyerror!void {
    const run_ref = firstLiftCoreExport(&built.info) orelse return error.NoRunExport;
    const main_inst = built.guestInstance(run_ref.instance) orelse return error.NoRunExport;
    var results = [_]Value{.{ .i32 = 0 }};
    main_inst.invoke(run_ref.name, &.{}, &results) catch |err| {
        // wasi:cli/exit unwinds with ProcExit after recording host.exit_code —
        // a clean termination, not a failure.
        if (err == error.ProcExit) return;
        return err;
    };
}

/// The unified WASI-component entry (D-335 Unit F): build once, then dispatch —
/// an **async-lifted** export (a `canon lift` with `opts.is_async`) goes through
/// the P3 stackless callback loop, else the sync `wasi:cli/run` path. This is
/// the surface the CLI / embedders call so an async P3 component "just runs".
///
/// ADR-0193 P3: the async branch is `comptime build_options.enable_wasi_p3`-gated
/// (relocated here from `component_wasi_p3.zig` so a `wasi_level < .p3` build
/// never references the P3 driver — `component_wasi_p3.zig` is then unimported).
/// At a p2 build an async component falls through to the sync runner, which
/// surfaces `NoRunExport` if it has no sync `wasi:cli/run` export.
pub fn runWasiMain(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: Module.InstantiateOpts) anyerror!void {
    var built = try buildWasiP2Component(engine, alloc, bytes, host, opts);
    defer built.deinit();
    if (comptime build_options.enable_wasi_p3) {
        const cwasi3 = @import("component_wasi_p3.zig");
        for (built.info.canons.items) |c| {
            if (c == .lift and c.lift.opts.is_async) return cwasi3.driveAsyncMain(&built);
        }
    }
    return runWasiP2MainBuilt(&built);
}
