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
const dbg = @import("../support/dbg.zig");

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
const p3http = @import("../wasi/p3_http.zig");
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
const zir_mod = @import("../ir/zir.zig");
const rt_value = @import("../runtime/value.zig");
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
pub const PendingWrite = struct { ptr: u32, count: u32, elem_size: u32 = 1 };
/// A socket read (accept / tcp-rx) that returned BLOCKED: the tcp socket rep
/// plus the parked destination span, executed at readiness by
/// `pollBlockedSockets` (the socket analogue of `PendingRead`).
pub const ParkedSockRead = struct { rep: u32, ptr: u32, cap: u32, elem_size: u32 = 1 };
/// A `tcp.send` sink: the tcp socket rep + the send's result-future handle,
/// so a drain failure (peer reset / shutdown) flips the future to err before
/// the guest awaits it (official sockets-tcp-receive test_drop_read_half).
pub const TcpTxRole = struct { rep: u32, fut: u32 };
/// A parked `udp.receive` subtask: the udp socket rep + the async call's
/// retptr, completed (recvfrom + marshal + SUBTASK event) at readiness by
/// `pollBlockedUdpReceives` — the timer-subtask pattern (ADR-0205 D2).
pub const ParkedUdpReceive = struct { rep: u32, retptr: u32 };
/// Harness-supplied request-body bytes served to guest stream reads.
pub const HostBodyBytes = struct { data: []u8, pos: usize = 0 };
/// A parked `wasi:http/client.send` (ADR-0205 D-5): the request rep, the
/// async call's retptr, its subtask waitable, and the request body being
/// collected via a capture sink. The blocking HTTP exchange runs once the
/// guest closes its body stream (`pollPendingClientSends`). Heap-allocated
/// — the capture sink holds a pointer to `body`.
pub const PendingClientSend = struct {
    req_rep: u32,
    retptr: u32,
    subtask: u32,
    body: std.ArrayList(u8) = .empty,
    body_shared: ?u32 = null,
};

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
    /// The ok-payload slot of a raw task.return (e.g. the response handle
    /// the http handler delivered); valid when `task_return == 0`.
    task_return_payload: ?u32 = null,
    /// CM-async per-task state (ADR-0189 ζ2): the stream/future end handle table,
    /// the shared-rendezvous arena, and the waitable-set table. Lives here (not
    /// in the P3 runner's frame) so the canon async builtins reach it via
    /// `Caller.data`. Empty for a P2 component (P2 mints no async builtins).
    streams: async_mod.StreamFutureTable,
    shared: async_mod.SharedTable,
    sets: async_mod.WaitableSetTable,
    /// Per-definition contexts for the synthesized async builtins.
    ab_ctxs: std.ArrayList(*AsyncBuiltinCtx) = .empty,
    /// Per-definition contexts for the `canon context.{get,set}` builtins.
    cb_ctxs: std.ArrayList(*ContextBuiltinCtx) = .empty,
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
    /// WASI 0.3 (ADR-0190/ADR-0205): the readable end of a
    /// `future<result<_,error-code>>` that a `*-via-stream` func returned,
    /// mapped to its outcome — null = ok (the peer succeeded / is still
    /// clean), else the 0.3 `error-code` ordinal a failed file stream
    /// recorded. A guest `future.read` COMPLETES immediately either way.
    host_result_futures: std.AutoHashMapUnmanaged(u32, ?u8) = .empty,
    /// `insecure-seed`'s cached 128-bit value — a moral value import: every
    /// call must observe the same seed (official random.wasm asserts it).
    insecure_seed: ?[2]u64 = null,
    /// WASI-0.3 filesystem via-stream roles (ADR-0205 phase B): a stream whose
    /// peer is a host FILE at a tracked byte position — `read-via-stream`
    /// (guest reads → host preads + advances) and `write/append-via-stream`
    /// (guest writes → host pwrites + advances). Keyed by the stream's SHARED
    /// id (like `host_sinks`); scrubbed on last-end drop.
    host_file_streams: std.AutoHashMapUnmanaged(u32, FileStreamRole) = .empty,
    /// WASI-0.3 `read-directory` stream roles: shared id → index into
    /// `dir_streams` (the same P1 readdir cursor the 0.2 entry-stream uses).
    host_dir_streams: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// A guest `stream.write` that BLOCKED (no peer yet): the source span it
    /// offered, keyed by the writable end handle — a host role registered
    /// AFTERWARDS (`write-via-stream(data, ...)` arrives while `write_all` is
    /// already parked under `futures::join!`) drains it at registration.
    pending_writes: std.AutoHashMapUnmanaged(u32, PendingWrite) = .empty,
    /// WASI-0.3 sockets (ADR-0205 phase C): live UDP sockets (a
    /// UDP_SOCKET3_RT handle's rep indexes this list) + the socket stream
    /// roles, all keyed by the stream's SHARED id like the file roles:
    /// `host_accept_streams` (listen → stream<tcp-socket>), `host_tcp_rx`
    /// (receive → stream<u8>), `host_tcp_tx` (send's drained data stream).
    /// Values = the tcp socket list index (rep).
    udp_sockets: std.ArrayList(p2sock.UdpSocket) = .empty,
    /// WASI-0.3 `wasi:http/types` `fields` resources (ADR-0205 phase D);
    /// a HTTP_FIELDS_RT handle's rep indexes this list. Dropped entries are
    /// deinit'ed in place (slot stays; reps are never reused).
    http_fields: std.ArrayList(p3http.HttpFields) = .empty,
    http_requests: std.ArrayList(p3http.HttpRequest) = .empty,
    http_responses: std.ArrayList(p3http.HttpResponse) = .empty,
    http_reqopts: std.ArrayList(p3http.HttpRequestOptions) = .empty,
    /// Host-resolved trailers futures (keyed by READABLE handle): a guest
    /// read completes immediately with `ok(none)` — the shape a
    /// harness-built request's `consume-body` hands out (ADR-0205 D-3).
    host_trailer_ok_futures: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Harness-supplied request-body bytes (keyed by the stream's SHARED
    /// id): a guest read drains from the buffer, then observes DROPPED.
    host_body_bytes: std.AutoHashMapUnmanaged(u32, HostBodyBytes) = .empty,
    /// Harness capture sinks (keyed by SHARED id): a guest WRITE into the
    /// stream appends to the harness's buffer and completes — how the
    /// harness collects a response body without a host-side stream reader.
    host_capture_sinks: std.AutoHashMapUnmanaged(u32, *std.ArrayList(u8)) = .empty,
    /// Parked `client.send` calls awaiting their request body (ADR-0205
    /// D-5); resolved by `pollPendingClientSends`.
    pending_client_sends: std.ArrayList(*PendingClientSend) = .empty,
    host_accept_streams: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    host_tcp_rx: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    host_tcp_tx: std.AutoHashMapUnmanaged(u32, TcpTxRole) = .empty,
    /// Socket-read stream ends (accept / rx) that returned BLOCKED and now
    /// await socket readiness — the scheduler's no-progress hook polls them
    /// (mirrors the D2 timer path) and EXECUTES the parked read. Key = the
    /// readable end HANDLE (the waitable a set joins).
    blocked_socket_reads: std.AutoHashMapUnmanaged(u32, ParkedSockRead) = .empty,
    /// Parked `udp.receive` subtasks awaiting datagram readiness, keyed by
    /// the subtask waitable handle.
    blocked_udp_receives: std.AutoHashMapUnmanaged(u32, ParkedUdpReceive) = .empty,
    /// Optional external-actor seam (official sockets-echo: the conformance
    /// harness plays the REMOTE CLIENT — connect / send — while the guest
    /// is parked): called at the scheduler's no-progress point; returns
    /// true if it performed an action (the scheduler retries).
    external_sock_step: ?*const fn (*anyopaque) bool = null,
    external_sock_ctx: ?*anyopaque = null,
    /// WASI-0.3 `open-at`'s REQUESTED `descriptor-flags` per descriptor
    /// handle — `get-flags` reflects the request (official
    /// filesystem-flags-and-type.wasm: an empty-flags open reads back READ
    /// alone), not the host's actual open mode.
    descriptor_open_flags: std.AutoHashMapUnmanaged(u32, u8) = .empty,
    /// CM-async `canon context.{get,set}` task-local storage (ADR-0205 phase A;
    /// spec `ContextLocalStorage`). One pair per TASK — valid while every
    /// runner keeps ≤ 1 live task per ctx (the single-component runner seeds
    /// exactly one; the graph runner gives each child component its own ctx).
    /// When a runner ever multiplexes tasks over one ctx, this moves into
    /// `TaskDescriptor`.
    task_context: [2]u64 = .{ 0, 0 },

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
    /// WASI-0.3 `udp-socket` (rep = index into `udp_sockets`).
    pub const UDP_SOCKET3_RT: u32 = 11;
    /// WASI-0.3 `wasi:http/types` `fields` (rep = index into `http_fields`;
    /// drop frees the entry's pair storage — no OS handle).
    pub const HTTP_FIELDS_RT: u32 = 12;
    /// A BORROWED view onto a fields rep (minted by `request.get-headers` /
    /// `response.get-headers`): drop releases only the handle — the parent
    /// request/response owns the storage.
    pub const HTTP_FIELDS_VIEW_RT: u32 = 13;
    /// `request` (rep = index into `http_requests`).
    pub const HTTP_REQUEST_RT: u32 = 14;
    /// `response` (rep = index into `http_responses`).
    pub const HTTP_RESPONSE_RT: u32 = 15;
    /// `request-options` (rep = index into `http_reqopts`; plain values, no
    /// heap) and its borrowed view (`request.get-options`).
    pub const HTTP_REQOPTS_RT: u32 = 16;
    pub const HTTP_REQOPTS_VIEW_RT: u32 = 17;

    /// Iteration state of one live directory-entry-stream: the directory's
    /// P1 fd + the P1 readdir cookie to resume after.
    pub const DirStream = struct { fd: wasi_p1.Fd, cookie: u64 };

    /// A WASI-0.3 file via-stream peer: the P1 fd + the tracked byte position
    /// the next pread/pwrite uses (advanced per completed copy).
    pub const FileStreamRole = struct { fd: wasi_p1.Fd, pos: u64, result_future: u32 = 0 };

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
        if (self.host.io) |io2| {
            for (self.udp_sockets.items) |*u| u.deinit(io2);
        }
        self.udp_sockets.deinit(self.alloc);
        for (self.http_fields.items) |*f| f.deinit(self.alloc);
        self.http_fields.deinit(self.alloc);
        for (self.http_requests.items) |*r| r.deinit(self.alloc);
        self.http_requests.deinit(self.alloc);
        self.http_responses.deinit(self.alloc);
        self.http_reqopts.deinit(self.alloc);
        self.host_trailer_ok_futures.deinit(self.alloc);
        var body_it = self.host_body_bytes.iterator();
        while (body_it.next()) |e| self.alloc.free(e.value_ptr.data);
        self.host_body_bytes.deinit(self.alloc);
        self.host_capture_sinks.deinit(self.alloc);
        for (self.pending_client_sends.items) |pcs| {
            pcs.body.deinit(self.alloc);
            self.alloc.destroy(pcs);
        }
        self.pending_client_sends.deinit(self.alloc);
        self.host_accept_streams.deinit(self.alloc);
        self.host_tcp_rx.deinit(self.alloc);
        self.host_tcp_tx.deinit(self.alloc);
        self.blocked_socket_reads.deinit(self.alloc);
        self.blocked_udp_receives.deinit(self.alloc);
        self.dir_streams.deinit(self.alloc);
        self.resources.deinit();
        self.guest_resources.deinit();
        for (self.rb_ctxs.items) |p| self.alloc.destroy(p);
        self.rb_ctxs.deinit(self.alloc);
        self.guest_dtors.deinit(self.alloc);
        for (self.ab_ctxs.items) |p| self.alloc.destroy(p);
        self.ab_ctxs.deinit(self.alloc);
        for (self.cb_ctxs.items) |p| self.alloc.destroy(p);
        self.cb_ctxs.deinit(self.alloc);
        self.host_file_streams.deinit(self.alloc);
        self.host_dir_streams.deinit(self.alloc);
        self.descriptor_open_flags.deinit(self.alloc);
        self.pending_writes.deinit(self.alloc);
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

    /// The host monotonic clock (P1 clock id 1) in ns — the time base for
    /// `monotonic-clock.now` AND the timer subtask deadlines, so `wait-until`
    /// comparisons are exact.
    pub fn monotonicNowNs(self: *WasiP2Ctx) WasiP2Error!u64 {
        return wasi_clocks.clockTimeNs(self.host, 1) catch WasiP2Error.NoHostIo;
    }

    /// Resolve every due timer subtask against the clock now (ADR-0205 D2).
    /// Returns the nearest still-future deadline (the scheduler's sleep bound).
    /// No armed timer → no clock read (hosts without `io` never need one).
    pub fn fireDueTimers(self: *WasiP2Ctx) WasiP2Error!?u64 {
        if (!self.streams.hasArmedTimer()) return null;
        return self.streams.fireDueTimers(try self.monotonicNowNs());
    }

    /// Poll blocked socket-read ends (accept / tcp-rx); a now-ready socket's
    /// PARKED READ EXECUTES here (accept / recv into the parked destination)
    /// and the event completes with the real element count — the socket
    /// analogue of `deliverParkedReads`. A bare "re-read" poke (payload 0)
    /// is NOT an option: the guest stream runtime reads a 0-element
    /// completion as end-of-stream (`accept.next()` → None). Returns true
    /// if any completed (the scheduler retries).
    pub fn pollBlockedSockets(self: *WasiP2Ctx) WasiP2Error!bool {
        if (self.blocked_socket_reads.count() == 0) return false;
        var progressed = false;
        var it = self.blocked_socket_reads.iterator();
        var ready_handles: [64]u32 = undefined;
        var n_ready: usize = 0;
        while (it.next()) |entry| {
            const sock = self.tcpSocketRep(entry.value_ptr.rep) orelse continue;
            if (sock.ready(p2sock.POLL_IN) catch false) {
                if (n_ready < ready_handles.len) {
                    ready_handles[n_ready] = entry.key_ptr.*;
                    n_ready += 1;
                }
            }
        }
        for (ready_handles[0..n_ready]) |h| {
            const pr = self.blocked_socket_reads.get(h) orelse continue;
            const end = self.streams.get(h) catch continue;
            const mem = try self.memory();
            const io = try ctxIo(self);
            if (dbg.on("async.host")) std.debug.print("[host] sock-ready handle={d} cap={d}\n", .{ h, pr.cap });
            if (self.host_accept_streams.get(end.shared) != null) {
                // Accept stream: mint an own<tcp-socket> handle per queued
                // connection (elements are u32 handles).
                var filled: u32 = 0;
                while (filled < pr.cap) {
                    const listener = self.tcpSocketRep(pr.rep) orelse break;
                    const conn = listener.accept(io) catch break;
                    const idx: u32 = @intCast(self.tcp_sockets.items.len);
                    self.tcp_sockets.append(self.alloc, conn) catch return WasiP2Error.OutOfMemory;
                    const nh = try self.resources.new(TCP_SOCKET_RT, idx);
                    try mem.write(pr.ptr + filled * 4, nh);
                    filled += 1;
                }
                if (filled == 0) continue; // spurious readiness — stay parked
                end.state = .done;
                end.setPendingEvent(.{ .code = .stream_read, .index = h, .payload = (async_mod.ReturnCode{ .completed = @intCast(filled) }).encode() });
            } else if (self.host_tcp_rx.get(end.shared) != null) {
                const sock = self.tcpSocketRep(pr.rep) orelse continue;
                const buf = mem.sliceAt(pr.ptr, pr.cap * pr.elem_size) catch return WasiP2Error.OutOfBounds;
                const n = sock.recv(io, buf) catch 0;
                if (n == 0) {
                    // Ready-then-zero = peer FIN → the stream closes.
                    switch ((try self.shared.get(end.shared)).*) {
                        .stream => |*sh_s| sh_s.dropped = true,
                        .future, .subtask => continue,
                    }
                    end.state = .done;
                    end.setPendingEvent(.{ .code = .stream_read, .index = h, .payload = (async_mod.ReturnCode{ .dropped = 0 }).encode() });
                } else {
                    end.state = .done;
                    end.setPendingEvent(.{ .code = .stream_read, .index = h, .payload = (async_mod.ReturnCode{ .completed = @intCast(n / pr.elem_size) }).encode() });
                }
                if (dbg.on("async.host")) std.debug.print("[host] sock-rx-complete handle={d} n={d}\n", .{ h, n });
            } else continue;
            _ = self.blocked_socket_reads.remove(h);
            progressed = true;
        }
        return progressed;
    }

    /// Poll parked `udp.receive` subtasks; a ready socket's receive EXECUTES
    /// (recvfrom + marshal at the saved retptr) and the subtask flips to
    /// RETURNED with its SUBTASK event pending (the timer-fire shape).
    pub fn pollBlockedUdpReceives(self: *WasiP2Ctx) WasiP2Error!bool {
        if (self.blocked_udp_receives.count() == 0) return false;
        var progressed = false;
        var it = self.blocked_udp_receives.iterator();
        var ready_handles: [64]u32 = undefined;
        var n_ready: usize = 0;
        while (it.next()) |entry| {
            const sock = ctxUdpSocket(self, entry.value_ptr.rep) catch continue;
            if (sock.readyIn() catch false) {
                if (n_ready < ready_handles.len) {
                    ready_handles[n_ready] = entry.key_ptr.*;
                    n_ready += 1;
                }
            }
        }
        for (ready_handles[0..n_ready]) |h| {
            const pr = self.blocked_udp_receives.get(h) orelse continue;
            const end = self.streams.get(h) catch continue;
            try sock3UdpReceiveComplete(self, pr.rep, pr.retptr);
            end.subtask_state = .returned;
            end.setPendingEvent(.{ .code = .subtask, .index = h, .payload = @intFromEnum(async_mod.SubtaskState.returned) });
            _ = self.blocked_udp_receives.remove(h);
            progressed = true;
        }
        return progressed;
    }

    fn tcpSocketRep(self: *WasiP2Ctx, rep: u32) ?*p2sock.TcpSocket {
        const idx = rep & 0x00FF_FFFF;
        if (idx >= self.tcp_sockets.items.len) return null;
        return &self.tcp_sockets.items[idx];
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

pub const WasiP2Error = error{ NoMemory, OutOfBounds, WriteFailed, NoRealloc, ReallocFailed, ProcExit, OutOfMemory, NoHostIo, Unreachable, UnsupportedAsyncBuiltin } ||
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

/// `wasi:cli/exit@0.3.0` `exit-with-code(status-code: u8)` — the arbitrary-code
/// sibling of `exit` (official 0.3.0 addition). The u8 lowers to an i32; pass
/// it through as the recorded exit code and unwind like `exit`.
fn p2ExitWithCode(caller: *Caller, code: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    _ = wasi_proc.procExit(ctx.host, code & 0xff);
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

/// `wasi:clocks/system-clock` `now()` → instant{seconds: s64, nanoseconds: u32}
/// (official WASI 0.3.0 — the renamed 0.2 `wall-clock`, reading the same host
/// realtime clock; the record's seconds field became SIGNED). Writes the
/// 12-byte record to the return area at `retptr` (seconds @ 0, ns @ 8).
fn p2SystemNow(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const ns = wasi_clocks.clockTimeNsSigned(ctx.host, 0) catch
        return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
    const inst = instantFromNs(ns);
    try mem.write(retptr, inst.seconds);
    try mem.write(retptr + 8, inst.nanoseconds);
}

/// Split signed epoch-nanoseconds into the WIT `instant` encoding: FLOORED
/// seconds + a non-negative sub-second remainder (the spec's example — 1 ns
/// before the epoch — is `{-1 seconds, 999_999_999 nanoseconds}`). Seconds
/// beyond the i64 domain clamp (mirrors `clockTimeNs`'s u64 clamp).
fn instantFromNs(ns: i96) struct { seconds: i64, nanoseconds: u32 } {
    const secs = @divFloor(ns, std.time.ns_per_s);
    const min_s: i96 = std.math.minInt(i64);
    const max_s: i96 = std.math.maxInt(i64);
    return .{
        .seconds = @intCast(std.math.clamp(secs, min_s, max_s)),
        .nanoseconds = @intCast(@mod(ns, std.time.ns_per_s)),
    };
}

test "instantFromNs: floored split incl. the WIT pre-epoch example" {
    // The system-clock.wit example: 1 ns before the epoch.
    try std.testing.expectEqual(@as(i64, -1), instantFromNs(-1).seconds);
    try std.testing.expectEqual(@as(u32, 999_999_999), instantFromNs(-1).nanoseconds);
    // Positive path + exact-second boundaries.
    try std.testing.expectEqual(@as(i64, 1), instantFromNs(1_500_000_000).seconds);
    try std.testing.expectEqual(@as(u32, 500_000_000), instantFromNs(1_500_000_000).nanoseconds);
    try std.testing.expectEqual(@as(i64, -2), instantFromNs(-2_000_000_000).seconds);
    try std.testing.expectEqual(@as(u32, 0), instantFromNs(-2_000_000_000).nanoseconds);
}

/// `wasi:clocks/{system,monotonic}-clock` `get-resolution()` → duration(u64)
/// (official WASI 0.3.0): the host clock granularity in ns, returned directly
/// as the lowered `i64`. WIT declares it infallible, so a host that cannot
/// report a resolution surfaces a loud error (never a fabricated value).
fn clockGetResolution(caller: *Caller, clock_id: u32) WasiP2Error!i64 {
    const ctx = caller.data(WasiP2Ctx);
    const ns = wasi_clocks.clockResNs(ctx.host, clock_id) catch |err| switch (err) {
        error.Inval => unreachable, // clock id is hardcoded 0/1 at the call sites
        error.NoSys, error.NotSup, error.Io => return WasiP2Error.NoHostIo,
    };
    return @bitCast(ns);
}

fn p2SystemGetResolution(caller: *Caller) WasiP2Error!i64 {
    return clockGetResolution(caller, 0);
}

fn p2MonotonicGetResolution(caller: *Caller) WasiP2Error!i64 {
    return clockGetResolution(caller, 1);
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
            // The udp-socket handle owns the OS socket (rep = udp_sockets
            // index, NOT a P1 fd — the else-branch fdClose would close an
            // unrelated host fd).
            WasiP2Ctx.UDP_SOCKET3_RT => {
                const sock = ctxUdpSocket(ctx, h.rep) catch return;
                if (sock.socket != null) sock.deinit(try ctxIo(ctx));
            },
            // The fields handle owns its (name, value) pair storage.
            WasiP2Ctx.HTTP_FIELDS_RT => {
                if (h.rep < ctx.http_fields.items.len)
                    ctx.http_fields.items[h.rep].deinit(ctx.alloc);
            },
            // Borrowed views / plain-value resources: handle slot only.
            WasiP2Ctx.HTTP_FIELDS_VIEW_RT, WasiP2Ctx.HTTP_REQOPTS_RT, WasiP2Ctx.HTTP_REQOPTS_VIEW_RT => {},
            // The response owns its headers fields storage + transferred
            // body ends (same writer-task unblock as the request).
            WasiP2Ctx.HTTP_RESPONSE_RT => {
                if (h.rep < ctx.http_responses.items.len) {
                    const resp = &ctx.http_responses.items[h.rep];
                    if (resp.headers_rep < ctx.http_fields.items.len)
                        ctx.http_fields.items[resp.headers_rep].deinit(ctx.alloc);
                    http3DropTransferredEnd(ctx, resp.trailers_future);
                    if (resp.contents_stream) |s| http3DropTransferredEnd(ctx, s);
                }
            },
            // The request owns its uri strings, its headers fields storage,
            // and the TRANSFERRED body ends — dropping the trailers-future
            // readable unblocks the guest's writer task (else its
            // wit_future closure waits forever → AsyncDeadlock).
            WasiP2Ctx.HTTP_REQUEST_RT => {
                if (h.rep < ctx.http_requests.items.len) {
                    const req = &ctx.http_requests.items[h.rep];
                    if (req.headers_rep < ctx.http_fields.items.len)
                        ctx.http_fields.items[req.headers_rep].deinit(ctx.alloc);
                    http3DropTransferredEnd(ctx, req.trailers_future);
                    if (req.contents_stream) |s| http3DropTransferredEnd(ctx, s);
                    req.deinit(ctx.alloc);
                }
            },
            else => _ = wasi_fd.fdClose(ctx.host, @intCast(h.rep)),
        }
    }
}

test "D-444 II: p2ResourceDrop(HTTP_REQUEST_RT) — releases transferred ends + owned storage" {
    const Runtime = @import("../runtime/runtime.zig").Runtime;
    const testing = std.testing;
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var caller: Caller = .{ .rt = &rt, .host_data = &ctx };

    // A request carrying transferred body ends + owned headers/uri storage,
    // exactly the state a guest hands over before dropping the resource.
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    const strm = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    try ctx.pending_reads.put(ctx.alloc, strm.readable, .{ .ptr = 0, .cap = 0 });
    var flds: p3http.HttpFields = .{};
    try flds.entries.append(ctx.alloc, .{
        .name = try ctx.alloc.dupe(u8, "x"),
        .value = try ctx.alloc.dupe(u8, "y"),
    });
    try ctx.http_fields.append(ctx.alloc, flds);
    try ctx.http_requests.append(ctx.alloc, .{
        .path_with_query = try ctx.alloc.dupe(u8, "/probe?q=1"),
        .headers_rep = 0,
        .contents_stream = strm.readable,
        .trailers_future = fut.readable,
    });
    const h = try ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, 0);

    try p2ResourceDrop(&caller, h);

    // The trailers-future / contents-stream ends are gone from every side
    // table (the writer-task unblock invariant) and the handle slot is freed.
    try testing.expect(ctx.host_result_futures.get(fut.readable) == null);
    try testing.expect(ctx.pending_reads.get(strm.readable) == null);
    try testing.expectError(async_mod.Error.InvalidHandle, ctx.streams.get(fut.readable));
    try testing.expectError(async_mod.Error.InvalidHandle, ctx.streams.get(strm.readable));
    try testing.expectError(resource_table.Error.InvalidHandle, ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, h));
    // Owned storage (headers pair + uri string) is freed — enforced by the
    // testing allocator's leak check at ctx.deinit.

    // A request with NO transferred ends (trailers_future = 0) drops benignly.
    try ctx.http_requests.append(ctx.alloc, .{ .headers_rep = 99 });
    const h2 = try ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, 1);
    try p2ResourceDrop(&caller, h2);
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
/// host's secure fill over-satisfies it — but the value is morally a VALUE
/// IMPORT ("should return the same values each time it is called"), so the
/// first fill is cached per ctx. The tuple flattens past MAX_FLAT_RESULTS=1 →
/// the two u64 land at `retptr` (+0, +8).
fn p2RandomInsecureSeed(caller: *Caller, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const seed = ctx.insecure_seed orelse blk: {
        var buf: [16]u8 = undefined;
        if (wasi_clocks.randomFill(ctx.host, &buf) != .success)
            return WasiP2Error.NoHostIo; // precondition: the component-run path plants host.io
        const s: [2]u64 = .{ std.mem.readInt(u64, buf[0..8], .little), std.mem.readInt(u64, buf[8..16], .little) };
        ctx.insecure_seed = s;
        break :blk s;
    };
    try mem.write(retptr, seed[0]);
    try mem.write(retptr + 8, seed[1]);
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

test "D-444 II: decodeIpSocketAddress — ipv4/ipv6 flat decode, u16 truncation, invalid disc" {
    // ipv4: p0=port (u16 truncation is the CABI i32→u16 lowering), p1..p4=octets.
    const v4 = decodeIpSocketAddress(0, .{ 0x0001_2345, 192, 168, 1, 2, 0, 0, 0, 0, 0, 0 }).?;
    try std.testing.expectEqual(@as(u16, 0x2345), v4.ip4.port);
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 1, 2 }, &v4.ip4.bytes);
    // ipv6: p0=port, p1=flow, p2..p9=segments packed big-endian into bytes.
    const v6 = decodeIpSocketAddress(1, .{ 0xBEEF, 0x1122_3344, 0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1, 0 }).?;
    try std.testing.expectEqual(@as(u16, 0xBEEF), v6.ip6.port);
    try std.testing.expectEqual(@as(u32, 0x1122_3344), v6.ip6.flow);
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x01, 0x0D, 0xB8 }, v6.ip6.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01 }, v6.ip6.bytes[14..16]);
    // Variant has exactly 2 cases; anything else is a decode failure, not a trap.
    try std.testing.expectEqual(@as(?std.Io.net.IpAddress, null), decodeIpSocketAddress(2, @splat(0)));
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

test "D-444 II: writeIpSocketAddressResult — CABI in-memory layout for both address cases" {
    const Runtime = @import("../runtime/runtime.zig").Runtime;
    var rt = Runtime.init(std.testing.allocator);
    defer rt.deinit();
    rt.memory = try std.testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0xAA); // poison so untouched bytes are visible
    const mem: Memory = .{ .backing = .{ .interp = &rt } };

    try writeIpSocketAddressResult(mem, 0, .{ .ip4 = .{ .port = 0x1234, .bytes = .{ 192, 168, 1, 2 } } });
    try std.testing.expectEqual(@as(u8, 0), try mem.read(u8, 0)); // result disc = ok
    try std.testing.expectEqual(@as(u8, 0), try mem.read(u8, 4)); // variant disc = ipv4
    try std.testing.expectEqual(@as(u16, 0x1234), try mem.read(u16, 8));
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 1, 2 }, mem.slice()[10..14]);

    var b16: [16]u8 = undefined;
    for (0..16) |i| b16[i] = @intCast(i + 1);
    try writeIpSocketAddressResult(mem, 0, .{ .ip6 = .{ .port = 0xBEEF, .bytes = b16, .flow = 0x1122_3344 } });
    try std.testing.expectEqual(@as(u8, 1), try mem.read(u8, 4)); // variant disc = ipv6
    try std.testing.expectEqual(@as(u16, 0xBEEF), try mem.read(u16, 8));
    try std.testing.expectEqual(@as(u32, 0x1122_3344), try mem.read(u32, 12));
    // Segments re-compose big-endian from byte pairs: seg0 = 0x0102, seg7 = 0x0F10.
    try std.testing.expectEqual(@as(u16, 0x0102), try mem.read(u16, 16));
    try std.testing.expectEqual(@as(u16, 0x0F10), try mem.read(u16, 30));
    try std.testing.expectEqual(@as(u32, 0), try mem.read(u32, 32)); // scope-id fixed 0

    // Decode/write agree on the big-endian segment convention (round-trip).
    const back = decodeIpSocketAddress(1, .{ 0xBEEF, 0x1122_3344, 0x0102, 0x0304, 0x0506, 0x0708, 0x090A, 0x0B0C, 0x0D0E, 0x0F10, 0 }).?;
    try std.testing.expectEqualSlices(u8, &b16, &back.ip6.bytes);
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
        .cli_exit_with_code => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2ExitWithCode),
        // The async wait funcs under a SYNC lower: the call blocks in the host.
        .clocks_wait_until => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, i64) WasiP2Error!void, p2WaitUntilSync),
        .clocks_wait_for => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, i64) WasiP2Error!void, p2WaitForSync),
        .clocks_monotonic_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2MonotonicNow),
        .clocks_wall_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2WallNow),
        .clocks_system_now => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!void, p2SystemNow),
        .clocks_system_get_resolution => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2SystemGetResolution),
        .clocks_monotonic_get_resolution => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!i64, p2MonotonicGetResolution),
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
        // wasi:sockets@0.3.0 plain funcs (sync-lowered by wit-bindgen).
        .sock3_tcp_create => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpCreate),
        .sock3_tcp_bind => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, sock3TcpBind),
        .sock3_tcp_listen => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpListen),
        .sock3_tcp_send => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!u32, sock3TcpSend),
        .sock3_tcp_receive => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpReceive),
        .sock3_tcp_local_addr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpLocalAddress),
        .sock3_tcp_remote_addr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpRemoteAddress),
        .sock3_tcp_is_listening => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, sock3TcpIsListening),
        .sock3_tcp_family => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, sock3TcpFamily),
        .sock3_tcp_set_backlog => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u64, u32) WasiP2Error!void, sock3TcpSetBacklog),
        .sock3_tcp_ka_enabled_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpKaEnabledGet),
        .sock3_tcp_ka_enabled_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, sock3TcpKaEnabledSet),
        .sock3_tcp_ka_idle_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpKaIdleGet),
        .sock3_tcp_ka_idle_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3TcpKaIdleSet),
        .sock3_tcp_ka_interval_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpKaIntervalGet),
        .sock3_tcp_ka_interval_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3TcpKaIntervalSet),
        .sock3_tcp_ka_count_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpKaCountGet),
        .sock3_tcp_ka_count_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, sock3TcpKaCountSet),
        .sock3_tcp_hop_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpHopGet),
        .sock3_tcp_hop_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, sock3TcpHopSet),
        .sock3_tcp_rcvbuf_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpRcvbufGet),
        .sock3_tcp_rcvbuf_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3TcpRcvbufSet),
        .sock3_tcp_sndbuf_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3TcpSndbufGet),
        .sock3_tcp_sndbuf_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3TcpSndbufSet),
        .sock3_udp_create => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpCreate),
        .sock3_udp_bind => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, sock3UdpBind),
        .sock3_udp_connect => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, sock3UdpConnect),
        .sock3_udp_disconnect => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpDisconnect),
        .sock3_udp_local_addr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpLocalAddress),
        .sock3_udp_remote_addr => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpRemoteAddress),
        .sock3_udp_family => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, sock3UdpFamily),
        .sock3_udp_hop_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpHopGet),
        .sock3_udp_hop_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, sock3UdpHopSet),
        .sock3_udp_rcvbuf_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpRcvbufGet),
        .sock3_udp_rcvbuf_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3UdpRcvbufSet),
        .sock3_udp_sndbuf_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, sock3UdpSndbufGet),
        .sock3_udp_sndbuf_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, sock3UdpSndbufSet),
        // The async-func sockets surface (connect / udp send / udp receive /
        // resolve-addresses) arrives ASYNC-lowered — sync lowers unreached.
        .sock3_tcp_connect, .sock3_udp_send, .sock3_udp_receive, .sock3_resolve_addresses => return error.UnsupportedWasiImport,
        // wasi:http/types@0.3.0 `fields` (sync plain funcs; ADR-0205 phase D).
        .http3_fields_new => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, http3FieldsNew),
        .http3_fields_from_list => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, http3FieldsFromList),
        .http3_fields_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http3FieldsGet),
        .http3_fields_has => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!u32, http3FieldsHas),
        .http3_fields_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http3FieldsSet),
        .http3_fields_delete => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http3FieldsDelete),
        .http3_fields_get_and_delete => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, http3FieldsGetAndDelete),
        .http3_fields_append => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http3FieldsAppend),
        .http3_fields_copy_all => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3FieldsCopyAll),
        .http3_fields_clone => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3FieldsClone),
        .http3_request_new => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, http3RequestNew),
        .http3_request_get_method => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetMethod),
        .http3_request_set_method => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetMethod),
        .http3_request_get_pwq => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetPwq),
        .http3_request_set_pwq => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetPwq),
        .http3_request_get_scheme => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetScheme),
        .http3_request_set_scheme => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetScheme),
        .http3_request_get_authority => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetAuthority),
        .http3_request_set_authority => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, http3RequestSetAuthority),
        .http3_request_get_options => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3RequestGetOptions),
        .http3_request_get_headers => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3RequestGetHeaders),
        .http3_response_new => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!void, http3ResponseNew),
        .http3_response_get_status => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3ResponseGetStatus),
        .http3_response_set_status => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!u32, http3ResponseSetStatus),
        .http3_response_get_headers => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3ResponseGetHeaders),
        .http3_reqopts_new => try lk.defineFuncCtx(module, name, ctx, fn (*Caller) WasiP2Error!u32, http3ReqoptsNew),
        .http3_reqopts_connect_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3ReqoptsConnectGet),
        .http3_reqopts_connect_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, i64, u32) WasiP2Error!void, http3ReqoptsConnectSet),
        .http3_reqopts_first_byte_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3ReqoptsFirstByteGet),
        .http3_reqopts_first_byte_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, i64, u32) WasiP2Error!void, http3ReqoptsFirstByteSet),
        .http3_reqopts_between_bytes_get => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, http3ReqoptsBetweenBytesGet),
        .http3_reqopts_between_bytes_set => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, i64, u32) WasiP2Error!void, http3ReqoptsBetweenBytesSet),
        .http3_reqopts_clone => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32) WasiP2Error!u32, http3ReqoptsClone),
        .http3_request_consume_body => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, http3RequestConsumeBody),
        .http3_response_consume_body => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, u32) WasiP2Error!void, http3ResponseConsumeBody),
        // client.send arrives ASYNC-lowered; a sync lower is unreached.
        .http3_client_send => return error.UnsupportedWasiImport,
        // wasi:filesystem@0.3.0 plain funcs (sync-lowered by wit-bindgen).
        .fs3_read_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, i64, u32) WasiP2Error!void, fs3ReadViaStream),
        .fs3_write_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32, i64) WasiP2Error!u32, fs3WriteViaStream),
        .fs3_append_via_stream => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!u32, fs3AppendViaStream),
        .fs3_read_directory => try lk.defineFuncCtx(module, name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, fs3ReadDirectory),
        // The fs3 async-func surface arrives ASYNC-lowered (defineAsyncLoweredOp);
        // a sync lower of it is unreached by the conformance corpus — fail loudly.
        .fs3_stat, .fs3_stat_at, .fs3_get_type, .fs3_get_flags, .fs3_set_times, .fs3_set_times_at, .fs3_set_size, .fs3_advise, .fs3_sync, .fs3_sync_data, .fs3_open_at, .fs3_create_directory_at, .fs3_remove_directory_at, .fs3_unlink_file_at, .fs3_readlink_at, .fs3_rename_at, .fs3_symlink_at, .fs3_link_at, .fs3_is_same_object, .fs3_metadata_hash, .fs3_metadata_hash_at => return error.UnsupportedWasiImport,
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
    /// `canon task.return` whose result flattens to >1 core param (e.g. the
    /// http handler's result<own<response>, error-code> = 8): bound via
    /// `defineFuncRaw` with the exact flat signature; the trampoline records
    /// disc + payload.
    task_return_raw: []const zir_mod.ValType,
    /// A `canon stream.*`/`future.*` builtin (WASI 0.3, ADR-0189 ζ2). `op`
    /// selects the trampoline; `type_index` is the stream/future type. Slice 2
    /// wires `stream.new`/`future.new`; the rest are a later slice.
    async_builtin: struct { op: ctypes.StreamFutureOp, type_index: u32, elem_size: u32 = 1 },
    /// A `canon waitable-set.new/join/poll/drop` builtin (WASI 0.3, ADR-0190
    /// E2b + ADR-0205 phase A) on the per-task `WaitableSetTable`. `wait`
    /// stays rejected (stackless: a guest blocks via the callback WAIT return).
    waitable_set_builtin: ctypes.WaitableSetOp,
    /// An ASYNC-lowered host import (`canon lower ... async`, ADR-0205 phase
    /// A): the trampoline returns the packed subtask status. Only ops with a
    /// genuine async host path bind here; the rest are async-EAGER via their
    /// sync trampolines (D5) or rejected until their phase lands.
    host_op_async: adapter.P2Op,
    /// A `canon context.{get,set}` builtin over `WasiP2Ctx.task_context`.
    context_builtin: struct { is_set: bool, slot: ctypes.ContextSlot },
    /// `canon task.cancel` / `subtask.{cancel,drop}` / `thread.yield` (ADR-0205
    /// phase A): linkable; unimplemented ones fail loudly at CALL time.
    async_support_builtin: AsyncSupportOp,
};

const AsyncSupportOp = enum { task_cancel, subtask_cancel, subtask_drop, thread_yield };

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
            .lower => |l| {
                const ref = info.resolveComponentImport(l.func) orelse return null;
                const op = adapter.classifyImport(ref.interface, ref.func, ref.gen) orelse return error.UnsupportedWasiImport;
                if (l.opts.is_async) return .{ .host_op_async = op };
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
            // A result flattening to >1 core param (payload-carrying variants
            // like the http handler's result<own<response>, error-code>)
            // takes the raw-signature route (ADR-0205 D-3).
            .task_return => |tr| {
                if (tr.result) |vt| {
                    var flat_types: std.ArrayList(canon.CoreType) = .empty;
                    const ct = canon.canonTypeFromDecoded(arena, info, vt) catch return .task_return_builtin;
                    canon.flattenType(arena, ct, &flat_types) catch return .task_return_builtin;
                    if (flat_types.items.len > 1) {
                        const params = try arena.alloc(zir_mod.ValType, flat_types.items.len);
                        for (flat_types.items, 0..) |ft, i| params[i] = switch (ft) {
                            .i32 => .i32,
                            .i64 => .i64,
                            .f32 => .f32,
                            .f64 => .f64,
                        };
                        return .{ .task_return_raw = params };
                    }
                }
                return .task_return_builtin;
            },
            // waitable-set.new/join/poll/drop are host-wired (ADR-0190 E2b +
            // ADR-0205 phase A); `wait` is the stackful path (zwasm stackless
            // re-enters via the callback WAIT return, not a guest wait call).
            .waitable_set => |ws| switch (ws.op) {
                .new, .join, .poll, .drop => return .{ .waitable_set_builtin = ws.op },
                .wait => return error.UnsupportedWasiImport,
            },
            .task_cancel => return .{ .async_support_builtin = .task_cancel },
            .subtask_cancel => return .{ .async_support_builtin = .subtask_cancel },
            .subtask_drop => return .{ .async_support_builtin = .subtask_drop },
            .context_get => |cg| return .{ .context_builtin = .{ .is_set = false, .slot = cg } },
            .context_set => |cs| return .{ .context_builtin = .{ .is_set = true, .slot = cs } },
            .thread_yield => return .{ .async_support_builtin = .thread_yield },
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

/// The raw-signature `task.return` (result flattens to >1 core param):
/// slot 0 is the result discriminant, slot 1 the ok-payload (e.g. the
/// response handle of the http `handler.handle` export); the error-case
/// junk slots are ignored — the harness reads the payload only when
/// disc == 0.
fn p2TaskReturnRaw(caller: *Caller, args: []const rt_value.Value, results: []rt_value.Value) anyerror!void {
    _ = results;
    const ctx = caller.data(WasiP2Ctx);
    ctx.task_return = if (args.len > 0) @bitCast(args[0].i32) else 0;
    ctx.task_return_payload = if (args.len > 1) @as(u32, @bitCast(args[1].i32)) else null;
    if (dbg.on("async.host")) std.debug.print("[host] task-return-raw n={d} disc={?d} payload={?d}\n", .{ args.len, ctx.task_return, ctx.task_return_payload });
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
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null); // ok unless a stream failure records an error
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
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null); // ok unless a stream failure records an error
    const mem = try ctx.memory();
    try mem.write(retptr, pair.readable);
    try mem.write(retptr + 4, fut.readable);
}

/// `canon waitable-set.new` (ADR-0190 E2b): mint an empty waitable set.
fn p2WaitableSetNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return ctx.sets.add(async_mod.WaitableSet.init(ctx.alloc));
}

/// `canon waitable.join` (ADR-0190 E2b; `CanonicalABI.md canon_waitable_join`):
/// core args are `(waitable, set)` — set 0 = LEAVE the current set; a join
/// always moves (a waitable belongs to at most one set).
fn p2WaitableJoin(caller: *Caller, waitable: u32, set_handle: u32) WasiP2Error!void {
    return p2WaitableJoinInner(caller, waitable, set_handle) catch |e| mapAsyncFault(e);
}
fn p2WaitableJoinInner(caller: *Caller, waitable: u32, set_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    ctx.sets.unjoin(waitable);
    if (set_handle == 0) return;
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

/// Packed return of an async-lowered import call (`CanonicalABI.md`
/// `canon_lower`, async case): `state | (subtask_handle << 4)`; an eager
/// completion returns bare `RETURNED` with no handle minted.
const SUBTASK_RETURNED: u32 = @intFromEnum(async_mod.SubtaskState.returned);

/// `wasi:clocks/monotonic-clock@0.3.0` `wait-until: async func(when: mark)`
/// under an async `canon lower` (ADR-0205 phase A). Already-elapsed deadline →
/// eager RETURNED (no subtask). Otherwise mint a TIMER subtask waitable; the
/// scheduler's poll path (`fireDueTimers`) resolves it and delivers the
/// SUBTASK event through the set the guest joins it into.
fn p2WaitUntil(caller: *Caller, when_raw: i64) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return p2WaitDeadlineAsync(ctx, @bitCast(when_raw)) catch |e| mapAsyncFault(e);
}

/// `wait-for: async func(how-long: duration)` — the relative-form sibling.
fn p2WaitFor(caller: *Caller, dur_raw: i64) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const now = try ctx.monotonicNowNs();
    const dur: u64 = @bitCast(dur_raw);
    return p2WaitDeadlineAsync(ctx, now +| dur) catch |e| mapAsyncFault(e);
}

fn p2WaitDeadlineAsync(ctx: *WasiP2Ctx, deadline_ns: u64) WasiP2Error!u32 {
    const now = try ctx.monotonicNowNs();
    if (deadline_ns <= now) return SUBTASK_RETURNED;
    const h = try ctx.streams.add(.{
        .kind = .subtask,
        .side = .readable,
        .elem_type = null,
        .subtask_state = .started,
        .deadline_ns = deadline_ns,
    });
    return @intFromEnum(async_mod.SubtaskState.started) | (h << 4);
}

/// The SYNC-lowered form of the async wait funcs (the Canonical ABI lets a
/// guest lower an `async func` synchronously — the call then blocks).
fn p2WaitUntilSync(caller: *Caller, when_raw: i64) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    return p2WaitDeadlineSync(ctx, @bitCast(when_raw));
}

fn p2WaitForSync(caller: *Caller, dur_raw: i64) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const now = try ctx.monotonicNowNs();
    const dur: u64 = @bitCast(dur_raw);
    return p2WaitDeadlineSync(ctx, now +| dur);
}

fn p2WaitDeadlineSync(ctx: *WasiP2Ctx, deadline_ns: u64) WasiP2Error!void {
    const now = try ctx.monotonicNowNs();
    if (deadline_ns <= now) return;
    const io = ctx.host.io orelse return WasiP2Error.NoHostIo;
    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(deadline_ns - now)), .awake) catch |err| switch (err) {
        error.Canceled => {}, // a cancelled sleep just wakes early
    };
}

/// `canon waitable-set.poll` (non-blocking; `CanonicalABI.md`
/// `canon_waitable_set_poll` + `unpack_event`): deliver parked host-source
/// reads + fire due timers (the make-progress hooks), then poll the set. An
/// event writes `(p1, p2)` at `ptr`/`ptr+4` and returns its code; no event
/// returns NONE (0). Writes target the canon-lower-bound memory (`ctxMemory`),
/// matching every other retptr-writing trampoline here.
fn p2WaitableSetPoll(caller: *Caller, set_handle: u32, ptr: u32) WasiP2Error!u32 {
    return p2WaitableSetPollInner(caller, set_handle, ptr) catch |e| mapAsyncFault(e);
}
fn p2WaitableSetPollInner(caller: *Caller, set_handle: u32, ptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const set = try ctx.sets.get(set_handle);
    try ctx.deliverParkedReads(set);
    _ = try ctx.fireDueTimers();
    if (dbg.on("async.host")) std.debug.print("[host] poll set={d} members={d}\n", .{ set_handle, set.elems.items.len });
    const ev = (try set.poll(&ctx.streams)) orelse return 0; // EventCode.none
    const mem = try ctxMemory(caller);
    try mem.write(ptr, ev.index);
    try mem.write(ptr + 4, ev.payload);
    return @intFromEnum(ev.code);
}

/// `canon waitable-set.drop` — remove the set from the table (tearing down its
/// member list). Members themselves stay live (they just leave the set).
fn p2WaitableSetDrop(caller: *Caller, set_handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    ctx.sets.remove(set_handle) catch |e| return mapAsyncFault(e);
}

/// `canon subtask.drop` — release a resolved subtask handle. Dropping an
/// UNRESOLVED subtask is a guest fault per spec (`Subtask.drop` traps before
/// `on_resolve` delivered), surfaced as the canonical guest trap.
fn p2SubtaskDrop(caller: *Caller, handle: u32) WasiP2Error!void {
    return p2SubtaskDropInner(caller, handle) catch |e| mapAsyncFault(e);
}
fn p2SubtaskDropInner(caller: *Caller, handle: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const end = try ctx.streams.get(handle);
    if (end.kind != .subtask) return WasiP2Error.InvalidHandle;
    switch (end.subtask_state) {
        .returned, .cancelled_before_started, .cancelled_before_returned => {},
        .starting, .started => return WasiP2Error.Unreachable, // drop before resolve = guest fault
    }
    _ = try ctx.streams.remove(handle);
}

/// `canon task.cancel` / `canon subtask.cancel` — CM-async cancellation is not
/// implemented (no current caller in the conformance corpus exercises it);
/// linking succeeds, a CALL fails loudly (never a silent no-op).
fn p2TaskCancel(caller: *Caller) WasiP2Error!void {
    _ = caller;
    return WasiP2Error.UnsupportedAsyncBuiltin;
}

fn p2SubtaskCancel(caller: *Caller, handle: u32) WasiP2Error!u32 {
    _ = caller;
    _ = handle;
    return WasiP2Error.UnsupportedAsyncBuiltin;
}

/// `canon thread.yield` — cooperative yield point; same not-implemented
/// posture as cancellation (fail loudly at call, not at link).
fn p2ThreadYield(caller: *Caller) WasiP2Error!u32 {
    _ = caller;
    return WasiP2Error.UnsupportedAsyncBuiltin;
}

/// Per-definition ctx for a `canon context.{get,set}` builtin: the slot index
/// into `WasiP2Ctx.task_context` (mirrors `ResourceBuiltinCtx`).
pub const ContextBuiltinCtx = struct { ctx: *WasiP2Ctx, slot: u32 };

fn p2ContextGet32(caller: *Caller) WasiP2Error!u32 {
    const cbc = caller.data(ContextBuiltinCtx);
    return @truncate(cbc.ctx.task_context[cbc.slot]);
}

fn p2ContextSet32(caller: *Caller, v: u32) WasiP2Error!void {
    const cbc = caller.data(ContextBuiltinCtx);
    cbc.ctx.task_context[cbc.slot] = v;
}

fn p2ContextGet64(caller: *Caller) WasiP2Error!i64 {
    const cbc = caller.data(ContextBuiltinCtx);
    return @bitCast(cbc.ctx.task_context[cbc.slot]);
}

fn p2ContextSet64(caller: *Caller, v: i64) WasiP2Error!void {
    const cbc = caller.data(ContextBuiltinCtx);
    cbc.ctx.task_context[cbc.slot] = @bitCast(v);
}

/// `canon stream.read`/`stream.write` (+ future) (ADR-0189 ζ2, re-scoped per
/// lesson 2026-06-16): drive one rendezvous step on the end named by `handle`
/// (`StreamFutureEnd.copy` dispatches read vs write on the end's side) and
/// return the packed `ReturnCode`. Single-task reaches only BLOCKED (no peer
/// ready) or DROPPED (peer dropped first); a count > 0 COMPLETION needs a host
/// stream peer (Unit E) — that path also wires the element marshalling at
/// `ptr`, so it traps here until then (unreachable single-task).
/// The future-copy trampoline: same rendezvous step, but the core ABI carries
/// no count (a future moves exactly one value).
fn p2FutureCopy(caller: *Caller, handle: u32, ptr: u32) WasiP2Error!u32 {
    return p2StreamFutureCopyInner(caller, handle, ptr, 1) catch |e| mapAsyncFault(e);
}

fn p2StreamFutureCopy(caller: *Caller, handle: u32, ptr: u32, count: u32) WasiP2Error!u32 {
    const r = p2StreamFutureCopyInner(caller, handle, ptr, count) catch |e| return mapAsyncFault(e);
    if (dbg.on("async.host")) std.debug.print("[host] copy -> 0x{x}\n", .{r});
    return r;
}
fn p2StreamFutureCopyInner(caller: *Caller, handle: u32, ptr: u32, count: u32) WasiP2Error!u32 {
    const abc = caller.data(AsyncBuiltinCtx);
    const end = try abc.ctx.streams.get(handle);
    if (dbg.on("async.host")) std.debug.print("[host] copy handle={d} kind={s} side={s} count={d}\n", .{ handle, @tagName(end.kind), @tagName(end.side), count });
    // Host result future (ADR-0190): the `future<result<_,error-code>>` returned
    // by write/read-via-stream. A host stream peer always succeeds → a guest
    // `future.read` COMPLETES with the `ok` discriminant (0, 1 byte) — no
    // rendezvous, no general typed marshalling.
    // Harness-resolved trailers future (ADR-0205 D-3): completes with
    // `ok(none)` — result disc @0 AND the option disc must both be
    // written (a bare ok byte leaves the option disc as garbage). The
    // payload offset is 8: `error-code` carries u64 cases (align 8).
    if (abc.ctx.host_trailer_ok_futures.contains(handle)) {
        const mem = try abc.ctx.memory();
        const buf = mem.sliceAt(ptr, 9) catch return WasiP2Error.OutOfBounds;
        buf[0] = 0;
        buf[8] = 0;
        _ = abc.ctx.host_trailer_ok_futures.remove(handle);
        return (async_mod.ReturnCode{ .completed = 0 }).encode();
    }
    if (abc.ctx.host_result_futures.get(handle)) |outcome| {
        const mem = try abc.ctx.memory();
        if (outcome) |code| {
            // result<_, error-code> err: disc@0, error-code variant @4
            // (disc u8 @4, `other`'s option<string> @8 → none).
            const buf = mem.sliceAt(ptr, 9) catch return WasiP2Error.OutOfBounds;
            buf[0] = 1;
            buf[4] = code;
            buf[8] = 0;
        } else {
            const buf = mem.sliceAt(ptr, 1) catch return WasiP2Error.OutOfBounds;
            buf[0] = 0; // ok
        }
        // Future events never pack a count (CanonicalABI `future_event`:
        // "the number of elements copied ... always zero").
        return (async_mod.ReturnCode{ .completed = 0 }).encode();
    }
    // WASI-0.3 FILE via-stream peer (ADR-0205 phase B): positional
    // pread/pwrite at the role's tracked position, advanced per copy.
    if (abc.ctx.host_file_streams.getPtr(end.shared)) |role| {
        const mem = try abc.ctx.memory();
        // A position past i64 range would be an UNEXPECTED EINVAL inside
        // std.Io (debug panic); surface it as a failed stream + an
        // err(invalid) result future instead (official filesystem-io.wasm
        // preads at u64::MAX and expects error-code::invalid).
        const pos_invalid = role.pos > std.math.maxInt(i64);
        if (end.side == .writable) {
            const bytes = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
            const errno: wasi_p1.Errno = if (pos_invalid) .inval else wasi_fd.pwriteSlice(abc.ctx.host, role.fd, bytes, role.pos);
            if (errno != .success) return fs3FailFileStream(abc.ctx, end, role, errno);
            role.pos += bytes.len;
            return (async_mod.ReturnCode{ .completed = @intCast(count) }).encode();
        }
        const buf = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
        var n: usize = 0;
        const errno: wasi_p1.Errno = if (pos_invalid) .inval else wasi_fd.preadSlice(abc.ctx.host, role.fd, buf, role.pos, &n);
        if (errno != .success) return fs3FailFileStream(abc.ctx, end, role, errno);
        if (n == 0) {
            // EOF: the writer (host) side drops, so the guest observes a
            // CLOSED stream instead of retrying a 0-byte completion forever.
            switch ((try abc.ctx.shared.get(end.shared)).*) {
                .stream => |*sh_s| sh_s.dropped = true,
                .future, .subtask => return WasiP2Error.InvalidHandle,
            }
            end.state = .done;
            return (async_mod.ReturnCode{ .dropped = 0 }).encode();
        }
        role.pos += n;
        return (async_mod.ReturnCode{ .completed = @intCast(n / abc.elem_size) }).encode();
    }
    // WASI-0.3 TCP accept stream (ADR-0205 phase C): each element is a fresh
    // `own<tcp-socket>` handle for an accepted connection; ready connections
    // batch. No connection queued → PARK (blocked + readiness-hook
    // registration below) — waiting here would starve the guest's own
    // concurrent connecting task (the `futures::join!` shape of the official
    // tcp-listen / echo tests) and livelock the single-threaded runtime.
    if (abc.ctx.host_accept_streams.get(end.shared)) |rep| {
        if (end.side != .readable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const io = try ctxIo(abc.ctx);
        var filled: u32 = 0;
        while (filled < count) {
            const listener = try ctxTcpSocket(abc.ctx, rep);
            const conn = listener.accept(io) catch break;
            const idx: u32 = @intCast(abc.ctx.tcp_sockets.items.len);
            abc.ctx.tcp_sockets.append(abc.ctx.alloc, conn) catch return WasiP2Error.OutOfMemory;
            const h = try abc.ctx.resources.new(WasiP2Ctx.TCP_SOCKET_RT, idx);
            try mem.write(ptr + filled * 4, h);
            filled += 1;
        }
        if (filled == 0) {
            try abc.ctx.blocked_socket_reads.put(abc.ctx.alloc, handle, .{ .rep = rep, .ptr = ptr, .cap = count, .elem_size = abc.elem_size });
            end.state = .async_copying;
            return (async_mod.ReturnCode{ .blocked = {} }).encode();
        }
        _ = abc.ctx.blocked_socket_reads.remove(handle);
        return (async_mod.ReturnCode{ .completed = @intCast(filled) }).encode();
    }
    // WASI-0.3 TCP receive stream (phase C): bytes recv'd from the connected
    // socket; a 0-byte read (peer FIN) closes the stream.
    if (abc.ctx.host_tcp_rx.get(end.shared)) |rep| {
        if (end.side != .readable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const io = try ctxIo(abc.ctx);
        const sock = try ctxTcpSocket(abc.ctx, rep);
        // Not ready yet → BLOCKED + register for the readiness hook (do NOT
        // recv, which would block the whole runtime).
        if (!(sock.ready(p2sock.POLL_IN) catch true)) {
            try abc.ctx.blocked_socket_reads.put(abc.ctx.alloc, handle, .{ .rep = rep, .ptr = ptr, .cap = count, .elem_size = abc.elem_size });
            end.state = .async_copying;
            return (async_mod.ReturnCode{ .blocked = {} }).encode();
        }
        _ = abc.ctx.blocked_socket_reads.remove(handle);
        const buf = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
        const n = sock.recv(io, buf) catch 0;
        if (n == 0) {
            // Ready-then-zero = peer FIN → close the stream.
            switch ((try abc.ctx.shared.get(end.shared)).*) {
                .stream => |*sh_s| sh_s.dropped = true,
                .future, .subtask => return WasiP2Error.InvalidHandle,
            }
            end.state = .done;
            return (async_mod.ReturnCode{ .dropped = 0 }).encode();
        }
        return (async_mod.ReturnCode{ .completed = @intCast(n / abc.elem_size) }).encode();
    }
    // Harness request-body source (ADR-0205 D-3): serve bytes from the
    // stored buffer; exhausted → the stream closes (DROPPED).
    if (abc.ctx.host_body_bytes.getPtr(end.shared)) |body| {
        if (end.side != .readable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const remaining = body.data.len - body.pos;
        if (remaining == 0) {
            switch ((try abc.ctx.shared.get(end.shared)).*) {
                .stream => |*sh_s| sh_s.dropped = true,
                .future, .subtask => return WasiP2Error.InvalidHandle,
            }
            end.state = .done;
            return (async_mod.ReturnCode{ .dropped = 0 }).encode();
        }
        const n = @min(remaining, count * abc.elem_size);
        const buf = mem.sliceAt(ptr, @intCast(n)) catch return WasiP2Error.OutOfBounds;
        @memcpy(buf, body.data[body.pos..][0..n]);
        body.pos += n;
        return (async_mod.ReturnCode{ .completed = @intCast(n / abc.elem_size) }).encode();
    }
    // Harness capture sink (ADR-0205 D-3): a guest write appends to the
    // harness's buffer and completes — the response-body collector.
    if (abc.ctx.host_capture_sinks.get(end.shared)) |cap| {
        if (end.side != .writable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const bytes = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
        cap.appendSlice(abc.ctx.alloc, bytes) catch return WasiP2Error.OutOfMemory;
        return (async_mod.ReturnCode{ .completed = @intCast(count) }).encode();
    }
    // WASI-0.3 TCP send sink (phase C): drain the guest's bytes into the
    // connected socket.
    if (abc.ctx.host_tcp_tx.get(end.shared)) |role| {
        if (end.side != .writable) return WasiP2Error.InvalidHandle;
        const mem = try abc.ctx.memory();
        const io = try ctxIo(abc.ctx);
        const bytes = mem.sliceAt(ptr, count * abc.elem_size) catch return WasiP2Error.OutOfBounds;
        const sock = try ctxTcpSocket(abc.ctx, role.rep);
        var off: usize = 0;
        while (off < bytes.len) {
            const n = sock.send(io, bytes[off..]) catch |e| {
                // Peer reset / shutdown: the send's result future carries
                // the error to the guest's `.await`.
                try sock3ResolveSendFuture(abc.ctx, role.fut, sockErrToFs3Code(e));
                break;
            };
            if (n == 0) break;
            off += n;
        }
        return (async_mod.ReturnCode{ .completed = @intCast(count) }).encode();
    }
    // WASI-0.3 `read-directory` stream (ADR-0205 phase B): marshal
    // `directory-entry` records from the registered P1 readdir cursor.
    if (abc.ctx.host_dir_streams.get(end.shared)) |state_index| {
        if (end.side != .readable) return WasiP2Error.InvalidHandle;
        return fs3DirStreamRead(abc.ctx, state_index, end, ptr, count);
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
        .subtask => unreachable, // SharedTable never stores .subtask (subtask ends stay unlinked)
    };
    return switch (step.caller) {
        .blocked => blk: {
            // Remember a parked WRITE's source span: a host file role
            // registered after the fact (write-via-stream under
            // futures::join!) completes it at registration.
            if (end.kind == .stream and end.side == .writable)
                try abc.ctx.pending_writes.put(abc.ctx.alloc, handle, .{ .ptr = ptr, .count = count, .elem_size = abc.elem_size });
            // Remember a parked future READ's destination: a late host
            // resolution (tcp.send outcome at tx-drop / drain-error)
            // completes it in place (sock3ResolveSendFuture).
            if (end.kind == .future and end.side == .readable)
                try abc.ctx.pending_reads.put(abc.ctx.alloc, handle, .{ .ptr = ptr, .cap = count, .elem_size = abc.elem_size });
            break :blk (async_mod.ReturnCode{ .blocked = {} }).encode();
        },
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
        .subtask => unreachable, // SharedTable never stores .subtask (subtask ends stay unlinked)
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
    const ctx = abc.ctx;
    // Handle + shared slot ids are free-list-reused: scrub the host-role side
    // tables BEFORE the drop, or a reused slot inherits the old role (a reused
    // result-future handle short-circuited a fresh stream's writes to
    // completed(0) — the official cli-stdio-roundtrip hang).
    if (ctx.streams.get(handle)) |end| {
        // Guest closed the write half of a `tcp.send` data stream =
        // `shutdown(SHUT_WR)` per the WIT ("closing the stream is
        // equivalent to shutdown(SHUT_WR)") — the peer must observe FIN or
        // its `receive` collect hangs (official sockets-tcp-send
        // test_drop_write_half).
        if (end.kind == .stream and end.side == .writable) {
            if (ctx.host_tcp_tx.get(end.shared)) |role| blk: {
                // The stream is exhausted: resolve the send future (ok
                // unless a drain error resolved it first).
                try sock3ResolveSendFuture(ctx, role.fut, null);
                const sock = ctx.tcpSocketRep(role.rep) orelse break :blk;
                const io = ctxIo(ctx) catch break :blk;
                if (dbg.on("async.host")) std.debug.print("[host] tx-drop shutdown(WR) handle={d} rep={d}\n", .{ handle, role.rep });
                // Destructor path — a shutdown failure (socket already
                // closed / reset) has no guest-visible surface; the peer
                // observes the close at socket teardown instead.
                // EXEMPT-FALLBACK: destructor, no guest surface (D-568)
                sock.shutdown(io, .send) catch {};
            }
        }
        // Dropping the read half of a `tcp.receive` stream =
        // `shutdown(SHUT_RD)` per the same WIT note (official
        // sockets-tcp-receive test_drop_read_half: a peer write after this
        // must surface an error).
        if (end.kind == .stream and end.side == .readable) {
            if (ctx.host_tcp_rx.get(end.shared)) |rep| blk: {
                const sock = ctx.tcpSocketRep(rep) orelse break :blk;
                const io = ctxIo(ctx) catch break :blk;
                // EXEMPT-FALLBACK: destructor, no guest surface (D-568)
                sock.shutdown(io, .recv) catch {};
            }
        }
        _ = ctx.host_result_futures.remove(handle);
        _ = ctx.pending_reads.remove(handle);
        _ = ctx.pending_writes.remove(handle);
        if (end.shared != 0 and (ctx.shared.refcountOf(end.shared) orelse 0) == 1) {
            _ = ctx.host_sinks.remove(end.shared);
            _ = ctx.host_sources.remove(end.shared);
            _ = ctx.host_file_streams.remove(end.shared);
            _ = ctx.host_dir_streams.remove(end.shared);
            _ = ctx.host_accept_streams.remove(end.shared);
            _ = ctx.host_tcp_rx.remove(end.shared);
            _ = ctx.host_tcp_tx.remove(end.shared);
            _ = ctx.blocked_socket_reads.remove(handle);
        }
    } else |_| {
        // Stale handle: dropEndGuarded below surfaces the guest fault.
    }
    // Shared drop contract: future-writable-before-write traps
    // (FutureDropBeforeWrite, mapAsyncFault → guest trap) + marks the rendezvous
    // DROPPED for the surviving peer (same helper the graph path uses).
    try async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, handle);
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
        .task_return_raw => |params| try lk.defineFuncRaw(ns, e.name, @ptrCast(ctx), params, &.{}, p2TaskReturnRaw),
        .waitable_set_builtin => |op| switch (op) {
            .new => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller) WasiP2Error!u32, p2WaitableSetNew),
            .join => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32, u32) WasiP2Error!void, p2WaitableJoin),
            .poll => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32, u32) WasiP2Error!u32, p2WaitableSetPoll),
            .drop => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32) WasiP2Error!void, p2WaitableSetDrop),
            .wait => unreachable, // synthDef rejects it
        },
        .host_op_async => |op| try defineAsyncLoweredOp(lk, ns, e.name, op, ctx),
        .context_builtin => |cb| {
            if (cb.slot.slot >= 2) return error.UnsupportedWasiImport; // spec ContextLocalStorage bound
            const cbc = try ctx.alloc.create(ContextBuiltinCtx);
            errdefer ctx.alloc.destroy(cbc);
            cbc.* = .{ .ctx = ctx, .slot = cb.slot.slot };
            try ctx.cb_ctxs.append(ctx.alloc, cbc);
            if (cb.is_set) {
                if (cb.slot.is_i64) {
                    try lk.defineFuncCtx(ns, e.name, @ptrCast(cbc), fn (*Caller, i64) WasiP2Error!void, p2ContextSet64);
                } else {
                    try lk.defineFuncCtx(ns, e.name, @ptrCast(cbc), fn (*Caller, u32) WasiP2Error!void, p2ContextSet32);
                }
            } else {
                if (cb.slot.is_i64) {
                    try lk.defineFuncCtx(ns, e.name, @ptrCast(cbc), fn (*Caller) WasiP2Error!i64, p2ContextGet64);
                } else {
                    try lk.defineFuncCtx(ns, e.name, @ptrCast(cbc), fn (*Caller) WasiP2Error!u32, p2ContextGet32);
                }
            }
        },
        .async_support_builtin => |op| switch (op) {
            .task_cancel => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller) WasiP2Error!void, p2TaskCancel),
            .subtask_cancel => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32) WasiP2Error!u32, p2SubtaskCancel),
            .subtask_drop => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller, u32) WasiP2Error!void, p2SubtaskDrop),
            .thread_yield => try lk.defineFuncCtx(ns, e.name, ctx, fn (*Caller) WasiP2Error!u32, p2ThreadYield),
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
                .stream_read, .stream_write => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller, u32, u32, u32) WasiP2Error!u32, p2StreamFutureCopy),
                // future.{read,write} core ABI is (handle, ptr) — no count (a
                // future carries exactly one value; CanonicalABI `future_copy`).
                .future_read, .future_write => try lk.defineFuncCtx(ns, e.name, @ptrCast(abc), fn (*Caller, u32, u32) WasiP2Error!u32, p2FutureCopy),
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
    // `run: func() -> result` — an `err` return (flat discriminant 1) is exit
    // code 1 per the wasi:cli command contract (official run-with-err.wasm).
    if (results[0].i32 != 0 and built.ctx.host.exit_code == null) built.ctx.host.exit_code = 1;
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

// ============================================================
// wasi:filesystem@0.3.0 (ADR-0205 phase B)
// ============================================================
// The 0.3 descriptor surface. Async funcs arrive ASYNC-LOWERED from
// wit-bindgen guests and complete eagerly (ADR-0205 D5): flat params ≤ 4 stay
// flat (+ retptr), larger signatures spill to ONE args pointer (+ retptr);
// results always land at retptr; the trampoline returns the packed subtask
// status (eager = RETURNED). The via-stream/read-directory funcs are PLAIN
// funcs (sync-lowered) minting host-peer streams like the ADR-0190 stdio
// pattern, but against file fds at tracked positions.

/// 0.3 `error-code` variant ordinals (0.2's `would-block` was REMOVED, so the
/// generations renumber; 36 = the `other(option<string>)` catch-all).
fn errnoToFs3ErrorCode(errno: wasi_p1.Errno) u8 {
    return switch (errno) {
        .acces => 0,
        .already => 1,
        .badf => 2,
        .busy => 3,
        .deadlk => 4,
        .dquot => 5,
        .exist => 6,
        .fbig => 7,
        .ilseq => 8,
        .inprogress => 9,
        .intr => 10,
        .inval => 11,
        .io => 12,
        .isdir => 13,
        .loop => 14,
        .mlink => 15,
        .msgsize => 16,
        .nametoolong => 17,
        .nodev => 18,
        .noent => 19,
        .nolck => 20,
        .nomem => 21,
        .nospc => 22,
        .notdir => 23,
        .notempty => 24,
        .notrecoverable => 25,
        .notsup => 26,
        .notty => 27,
        .nxio => 28,
        .overflow => 29,
        .perm => 30,
        .pipe => 31,
        .rofs => 32,
        .spipe => 33,
        .txtbsy => 34,
        .xdev => 35,
        // P1's sandbox-escape errno; 0.3 names the same condition
        // `not-permitted` ("reaches a directory outside of the base
        // directory ... fails with error-code::not-permitted").
        .notcapable => 30,
        else => 36,
    };
}

/// 0.3 `descriptor-type` VARIANT ordinals (0.2 was an enum with `unknown` at
/// 0; 0.3 drops it and appends `other(option<string>)` = 7).
fn filetypeToFs3DescriptorType(ft: wasi_p1.Filetype) u8 {
    return switch (ft) {
        .block_device => 0,
        .character_device => 1,
        .directory => 2,
        .symbolic_link => 4,
        .regular_file => 5,
        .socket_dgram, .socket_stream => 6,
        else => 7,
    };
}

/// Store `result.err(error-code)` at `retptr` for a 0.3 result whose payload
/// slot sits at `payload_off` (8 for align-8 ok payloads, 4 otherwise).
/// error-code = variant{disc u8 @0, `other`'s option<string> @4 → none}.
fn writeFs3Err(mem: Memory, retptr: u32, payload_off: u32, errno: wasi_p1.Errno) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1)); // result disc: err
    try mem.write(retptr + payload_off, errnoToFs3ErrorCode(errno));
    try mem.write(retptr + payload_off + 4, @as(u8, 0)); // option<string>: none
}

/// Write a 0.3 `descriptor-type` variant (16 B, align 4) at `ptr`.
fn writeFs3DescriptorType(mem: Memory, ptr: u32, ft: wasi_p1.Filetype) WasiP2Error!void {
    try mem.write(ptr, filetypeToFs3DescriptorType(ft));
    try mem.write(ptr + 4, @as(u8, 0)); // `other`'s option<string>: none
}

/// Resolve a descriptor handle to its P1 fd (shared fs3 front-half).
fn fs3Fd(ctx: *WasiP2Ctx, handle: u32) WasiP2Error!wasi_p1.Fd {
    return @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, handle));
}

/// `[async-lower][method]descriptor.stat` (self, retptr) — store
/// `result<descriptor-stat, error-code>` in the 0.3 layout: disc@0, payload@8;
/// descriptor-stat = %type@0 (16 B variant), link-count@16, size@24, then
/// three `option<instant>` @32/56/80 (disc@0, instant{seconds s64@8, ns u32@16}).
fn fs3Stat(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    try writeFs3StatResult(mem, retptr, try descriptorFilestat(ctx, mem, fd));
    return SUBTASK_RETURNED;
}

fn fs3StatAt(caller: *Caller, self_handle: u32, path_flags: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const dirfd = try fs3Fd(ctx, self_handle);
    try writeFs3StatResult(mem, retptr, try pathFilestat(ctx, mem, dirfd, path_flags, path_ptr, path_len));
    return SUBTASK_RETURNED;
}

fn writeFs3StatResult(mem: Memory, retptr: u32, r: FilestatResult) WasiP2Error!void {
    switch (r) {
        .ok => |fs| {
            try mem.write(retptr, @as(u8, 0)); // result disc: ok
            const base = retptr + 8;
            try writeFs3DescriptorType(mem, base, fs.filetype);
            try mem.write(base + 16, @as(u64, fs.nlink));
            try mem.write(base + 24, @as(u64, fs.size));
            inline for (.{ .{ base + 32, fs.atim }, .{ base + 56, fs.mtim }, .{ base + 80, fs.ctim } }) |t| {
                try mem.write(t[0], @as(u8, 1)); // option disc: some
                try mem.write(t[0] + 8, @as(i64, @intCast(t[1] / std.time.ns_per_s)));
                try mem.write(t[0] + 16, @as(u32, @intCast(t[1] % std.time.ns_per_s)));
            }
        },
        .err => |errno| try writeFs3Err(mem, retptr, 8, errno),
    }
}

/// `get-type` (self, retptr) — `result<descriptor-type, error-code>`: disc@0,
/// payload@4 (align 4).
fn fs3GetType(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    switch (try descriptorFilestat(ctx, mem, fd)) {
        .ok => |fs| {
            try mem.write(retptr, @as(u8, 0));
            try writeFs3DescriptorType(mem, retptr + 4, fs.filetype);
        },
        .err => |errno| try writeFs3Err(mem, retptr, 4, errno),
    }
    return SUBTASK_RETURNED;
}

/// `get-flags` (self, retptr) — `result<descriptor-flags, error-code>`;
/// descriptor-flags = 6 flags → one byte (read=1, write=2,
/// mutate-directory=32). Derived from the object kind: files read+write,
/// directories read+mutate-directory (the host does not model O_RDONLY opens).
fn fs3GetFlags(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    switch (try descriptorFilestat(ctx, mem, fd)) {
        .ok => |fs| {
            // Reflect the open-time EFFECTIVE flags when recorded; preopens
            // and 0.2-opened descriptors derive from kind.
            const flags: u8 = if (ctx.descriptor_open_flags.get(self_handle)) |req|
                req & (1 | 2 | 32)
            else if (fs.filetype == .directory) 1 | 32 else 1 | 2;
            try mem.write(retptr, @as(u8, 0));
            try mem.write(retptr + 4, flags);
        },
        .err => |errno| try writeFs3Err(mem, retptr, 4, errno),
    }
    return SUBTASK_RETURNED;
}

/// `result<_, error-code>` writer (unit ok): disc@0, err payload@4.
fn writeFs3UnitResult(mem: Memory, retptr: u32, errno: wasi_p1.Errno) WasiP2Error!void {
    if (errno == .success) {
        try mem.write(retptr, @as(u8, 0));
    } else {
        try writeFs3Err(mem, retptr, 4, errno);
    }
}

fn fs3Sync(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_fd.fdSync(ctx.host, try fs3Fd(ctx, self_handle)));
    return SUBTASK_RETURNED;
}

fn fs3SyncData(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_fd.fdDatasync(ctx.host, try fs3Fd(ctx, self_handle)));
    return SUBTASK_RETURNED;
}

fn fs3SetSize(caller: *Caller, self_handle: u32, size_raw: i64, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    // A descriptor opened without WRITE must refuse resizing (WASI#712;
    // official filesystem-set-size.wasm asserts it).
    if (ctx.descriptor_open_flags.get(self_handle)) |req| {
        if (req & 2 == 0) {
            try writeFs3Err(mem, retptr, 4, .badf);
            return SUBTASK_RETURNED;
        }
    }
    try writeFs3UnitResult(mem, retptr, wasi_fd.fdFilestatSetSize(ctx.host, try fs3Fd(ctx, self_handle), @bitCast(size_raw)));
    return SUBTASK_RETURNED;
}

/// `advise` (self, offset, length, advice, retptr) — 0.3 advice ordinals
/// match P1's (normal..no-reuse).
fn fs3Advise(caller: *Caller, self_handle: u32, offset_raw: i64, len_raw: i64, advice: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const errno = wasi_fd.fdAdvise(ctx.host, try fs3Fd(ctx, self_handle), @bitCast(offset_raw), @bitCast(len_raw), @intCast(advice & 0xff));
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

fn fs3CreateDirectoryAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_path.pathCreateDirectory(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), path_ptr, path_len));
    return SUBTASK_RETURNED;
}

fn fs3RemoveDirectoryAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_path.pathRemoveDirectory(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), path_ptr, path_len));
    return SUBTASK_RETURNED;
}

fn fs3UnlinkFileAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3UnitResult(mem, retptr, wasi_fd.pathUnlinkFile(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), path_ptr, path_len));
    return SUBTASK_RETURNED;
}

/// `readlink-at` (self, path, retptr) → `result<string, error-code>`
/// (string align 4 → payload@4: ptr@4, len@8; target in fresh cabi_realloc
/// backing).
fn fs3ReadlinkAt(caller: *Caller, self_handle: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const dirfd = try fs3Fd(ctx, self_handle);
    const cap: u32 = 4096;
    const buf_ptr = try ctx.reallocGuest(cap, 1);
    const used_ptr = try ctx.reallocGuest(4, 4);
    const errno = wasi_path.pathReadlink(ctx.host, mem.slice(), dirfd, path_ptr, path_len, buf_ptr, cap, used_ptr);
    if (errno != .success) {
        try writeFs3Err(mem, retptr, 4, errno);
        return SUBTASK_RETURNED;
    }
    const used = try mem.read(u32, used_ptr);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, buf_ptr);
    try mem.write(retptr + 8, used);
    return SUBTASK_RETURNED;
}

// -- spilled-args family: the Canonical ABI passes > 4-flat async-lowered
// params through ONE args pointer; layouts are the params-record layouts.

/// `open-at` args record: self@0(u32), path-flags@4(u8 flags),
/// path@8(ptr,len), open-flags@16(u8), %flags@17(u8). Result:
/// `result<own<descriptor>, error-code>` (handle@4).
fn fs3OpenAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const path_ptr = try mem.read(u32, argsptr + 8);
    const path_len = try mem.read(u32, argsptr + 12);
    const open_flags = try mem.read(u8, argsptr + 16);
    const dirfd = try fs3Fd(ctx, self_handle);
    const oflags: wasi_p1.Oflags = @intCast(open_flags & 0x0F);
    const rights = wasi_p1.RIGHTS_FD_READ | wasi_p1.RIGHTS_FD_WRITE;
    const scratch = try ctx.reallocGuest(4, 4);
    const errno = wasi_fd.pathOpen(ctx.host, mem.slice(), dirfd, 0, path_ptr, path_len, oflags, rights, rights, 0, scratch);
    if (errno != .success) {
        try writeFs3Err(mem, retptr, 4, errno);
        return SUBTASK_RETURNED;
    }
    const opened_fd = try mem.read(u32, scratch);
    const handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, opened_fd);
    // The EFFECTIVE flags `get-flags` reads back (official
    // filesystem-flags-and-type.wasm): no read/write requested → READ by
    // default; CREATE/TRUNCATE imply WRITE (without implying READ).
    var dflags = try mem.read(u8, argsptr + 17);
    if (dflags & 3 == 0) dflags |= 1;
    if (open_flags & (0x1 | 0x8) != 0) dflags |= 2;
    try ctx.descriptor_open_flags.put(ctx.alloc, handle, dflags);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
    return SUBTASK_RETURNED;
}

/// One decoded `new-timestamp` (24 B variant, align 8: disc@0, instant@8).
const Fs3NewTimestamp = struct { ns: u64, set: bool, now: bool };

fn readFs3NewTimestamp(mem: Memory, ptr: u32) WasiP2Error!Fs3NewTimestamp {
    const disc = try mem.read(u8, ptr);
    return switch (disc) {
        0 => .{ .ns = 0, .set = false, .now = false }, // no-change
        1 => .{ .ns = 0, .set = false, .now = true }, // now
        else => blk: {
            const secs = try mem.read(i64, ptr + 8);
            const nanos = try mem.read(u32, ptr + 16);
            // Pre-epoch instants clamp to 0 (P1 timestamps are unsigned ns).
            const total: u64 = if (secs < 0) 0 else @as(u64, @intCast(secs)) *| std.time.ns_per_s +| nanos;
            break :blk .{ .ns = total, .set = true, .now = false };
        },
    };
}

fn fs3FstflagsOf(atim: Fs3NewTimestamp, mtim: Fs3NewTimestamp) wasi_p1.Fstflags {
    var f: u16 = 0;
    if (atim.set) f |= 1; // ATIM
    if (atim.now) f |= 2; // ATIM_NOW
    if (mtim.set) f |= 4; // MTIM
    if (mtim.now) f |= 8; // MTIM_NOW
    return @bitCast(f);
}

/// `set-times` args record: self@0, atim new-timestamp@8, mtim@32.
fn fs3SetTimes(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const atim = try readFs3NewTimestamp(mem, argsptr + 8);
    const mtim = try readFs3NewTimestamp(mem, argsptr + 32);
    const errno = wasi_fd.fdFilestatSetTimes(ctx.host, try fs3Fd(ctx, self_handle), atim.ns, mtim.ns, fs3FstflagsOf(atim, mtim));
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `set-times-at` args record: self@0, path-flags@4(u8), path@8(8),
/// atim@16(24, align 8), mtim@40(24).
fn fs3SetTimesAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const path_flags = try mem.read(u8, argsptr + 4);
    const path_ptr = try mem.read(u32, argsptr + 8);
    const path_len = try mem.read(u32, argsptr + 12);
    const atim = try readFs3NewTimestamp(mem, argsptr + 16);
    const mtim = try readFs3NewTimestamp(mem, argsptr + 40);
    const errno = wasi_path.pathFilestatSetTimes(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), path_flags, path_ptr, path_len, atim.ns, mtim.ns, fs3FstflagsOf(atim, mtim));
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `rename-at` args record: self@0, old-path@4(8), new-descriptor@12(u32),
/// new-path@16(8).
fn fs3RenameAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const old_ptr = try mem.read(u32, argsptr + 4);
    const old_len = try mem.read(u32, argsptr + 8);
    const new_desc = try mem.read(u32, argsptr + 12);
    const new_ptr = try mem.read(u32, argsptr + 16);
    const new_len = try mem.read(u32, argsptr + 20);
    const errno = wasi_path.pathRename(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), old_ptr, old_len, try fs3Fd(ctx, new_desc), new_ptr, new_len);
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `symlink-at` args record: self@0, old-path@4(8), new-path@12(8).
fn fs3SymlinkAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const old_ptr = try mem.read(u32, argsptr + 4);
    const old_len = try mem.read(u32, argsptr + 8);
    const new_ptr = try mem.read(u32, argsptr + 12);
    const new_len = try mem.read(u32, argsptr + 16);
    const errno = wasi_path.pathSymlink(ctx.host, mem.slice(), old_ptr, old_len, try fs3Fd(ctx, self_handle), new_ptr, new_len);
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `link-at` args record: self@0, old-path-flags@4(u8), old-path@8(8),
/// new-descriptor@16(u32), new-path@20(8).
fn fs3LinkAt(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self_handle = try mem.read(u32, argsptr);
    const old_flags = try mem.read(u8, argsptr + 4);
    const old_ptr = try mem.read(u32, argsptr + 8);
    const old_len = try mem.read(u32, argsptr + 12);
    const new_desc = try mem.read(u32, argsptr + 16);
    const new_ptr = try mem.read(u32, argsptr + 20);
    const new_len = try mem.read(u32, argsptr + 24);
    const errno = wasi_path.pathLink(ctx.host, mem.slice(), try fs3Fd(ctx, self_handle), old_flags, old_ptr, old_len, try fs3Fd(ctx, new_desc), new_ptr, new_len);
    try writeFs3UnitResult(mem, retptr, errno);
    return SUBTASK_RETURNED;
}

/// `is-same-object` (self, other, retptr) → bool (no error case): P1 dev+ino
/// equality.
fn fs3IsSameObject(caller: *Caller, self_handle: u32, other_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const a = try descriptorFilestat(ctx, mem, try fs3Fd(ctx, self_handle));
    const b = try descriptorFilestat(ctx, mem, try fs3Fd(ctx, other_handle));
    const same = switch (a) {
        .ok => |fa| switch (b) {
            .ok => |fb| fa.dev == fb.dev and fa.ino == fb.ino,
            .err => false,
        },
        .err => false,
    };
    try mem.write(retptr, @as(u8, @intFromBool(same)));
    return SUBTASK_RETURNED;
}

/// `metadata-hash` family → `result<metadata-hash-value{lower,upper},
/// error-code>` (payload@8): a Wyhash over (dev, ino, size, mtim) — stable
/// while the object is unmodified, changes when it changes (the spec's
/// encouraged properties; none is required).
fn fs3HashOf(fs: wasi_p1.Filestat) [2]u64 {
    var h = std.hash.Wyhash.init(0x7a77_6173_6d5f_6673); // "zwasm_fs"
    h.update(std.mem.asBytes(&fs.dev));
    h.update(std.mem.asBytes(&fs.ino));
    h.update(std.mem.asBytes(&fs.size));
    h.update(std.mem.asBytes(&fs.mtim));
    const lo = h.final();
    var h2 = std.hash.Wyhash.init(lo);
    h2.update(std.mem.asBytes(&fs.ino));
    return .{ lo, h2.final() };
}

fn writeFs3HashResult(mem: Memory, retptr: u32, r: FilestatResult) WasiP2Error!void {
    switch (r) {
        .ok => |fs| {
            const hv = fs3HashOf(fs);
            try mem.write(retptr, @as(u8, 0));
            try mem.write(retptr + 8, hv[0]);
            try mem.write(retptr + 16, hv[1]);
        },
        .err => |errno| try writeFs3Err(mem, retptr, 8, errno),
    }
}

fn fs3MetadataHash(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3HashResult(mem, retptr, try descriptorFilestat(ctx, mem, try fs3Fd(ctx, self_handle)));
    return SUBTASK_RETURNED;
}

fn fs3MetadataHashAt(caller: *Caller, self_handle: u32, path_flags: u32, path_ptr: u32, path_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeFs3HashResult(mem, retptr, try pathFilestat(ctx, mem, try fs3Fd(ctx, self_handle), path_flags, path_ptr, path_len));
    return SUBTASK_RETURNED;
}

// -- via-stream data plane (plain funcs, sync-lowered) --

/// `read-via-stream` (self, offset, retptr) → tuple<stream<u8>,
/// future<result<_,error-code>>> (stream handle@retptr, future@retptr+4):
/// the host is the stream's WRITER, supplying bytes preread from the file at
/// the tracked position (ADR-0190 pattern on a positional fd).
fn fs3ReadViaStream(caller: *Caller, self_handle: u32, offset_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try ctx.host_file_streams.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, .{ .fd = fd, .pos = @bitCast(offset_raw), .result_future = fut.readable });
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    try mem.write(retptr, pair.readable);
    try mem.write(retptr + 4, fut.readable);
}

/// `write-via-stream` (self, data readable-stream, offset) → future handle:
/// the guest hands over the READABLE end of its data stream; the host drains
/// it as a positional file sink.
fn fs3WriteViaStream(caller: *Caller, self_handle: u32, data_handle: u32, offset_raw: i64) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const fd = try fs3Fd(ctx, self_handle);
    return fs3RegisterFileSink(ctx, fd, data_handle, @bitCast(offset_raw)) catch |e| mapAsyncFault(e);
}

/// `append-via-stream` (self, data) → future handle: the sink position starts
/// at the current file size.
fn fs3AppendViaStream(caller: *Caller, self_handle: u32, data_handle: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    const size: u64 = switch (try descriptorFilestat(ctx, mem, fd)) {
        .ok => |fs| fs.size,
        .err => 0,
    };
    return fs3RegisterFileSink(ctx, fd, data_handle, size) catch |e| mapAsyncFault(e);
}

fn fs3RegisterFileSink(ctx: *WasiP2Ctx, fd: wasi_p1.Fd, data_handle: u32, pos: u64) WasiP2Error!u32 {
    // Copy the shared id out BEFORE minting the future pair — the mint grows
    // the end table and invalidates `get`'s pointer.
    const shared_id = blk: {
        const end = try ctx.streams.get(data_handle);
        if (end.kind != .stream) return WasiP2Error.InvalidHandle;
        break :blk end.shared;
    };
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try ctx.host_file_streams.put(ctx.alloc, shared_id, .{ .fd = fd, .pos = pos, .result_future = fut.readable });
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    try fs3DrainParkedWrite(ctx, shared_id);
    return fut.readable;
}

/// A writer PARKED on this stream before the host role existed
/// (`futures::join!` ordering): drain its recorded span into the file now and
/// deliver its STREAM_WRITE completion event.
fn fs3DrainParkedWrite(ctx: *WasiP2Ctx, shared_id: u32) WasiP2Error!void {
    const sh = try ctx.shared.get(shared_id);
    const pending = switch (sh.*) {
        .stream => |*st| st.pending orelse return,
        .future, .subtask => return,
    };
    if (pending.side != .writable) return;
    const pw = ctx.pending_writes.get(pending.waitable) orelse return;
    const role = ctx.host_file_streams.getPtr(shared_id) orelse return;
    const mem = try ctx.memory();
    const bytes = mem.sliceAt(pw.ptr, pw.count * pw.elem_size) catch return WasiP2Error.OutOfBounds;
    const errno = wasi_fd.pwriteSlice(ctx.host, role.fd, bytes, role.pos);
    const writer = try ctx.streams.get(pending.waitable);
    if (errno != .success) {
        _ = try fs3FailFileStream(ctx, writer, role, errno);
        return;
    }
    role.pos += bytes.len;
    writer.state = .idle;
    writer.setPendingEvent(.{ .code = .stream_write, .index = pending.waitable, .payload = (async_mod.ReturnCode{ .completed = @intCast(pw.count) }).encode() });
    switch (sh.*) {
        .stream => |*st| st.pending = null,
        .future, .subtask => {},
    }
    _ = ctx.pending_writes.remove(pending.waitable);
}

/// A file via-stream copy failed: record the 0.3 error-code on the stream's
/// result future, close the stream (DROPPED), and report the drop to the
/// caller — the guest then reads the error from the future.
fn fs3FailFileStream(ctx: *WasiP2Ctx, end: *async_mod.StreamFutureEnd, role: *WasiP2Ctx.FileStreamRole, errno: wasi_p1.Errno) WasiP2Error!u32 {
    if (role.result_future != 0) {
        if (ctx.host_result_futures.getPtr(role.result_future)) |v| v.* = errnoToFs3ErrorCode(errno);
    }
    switch ((try ctx.shared.get(end.shared)).*) {
        .stream => |*sh_s| sh_s.dropped = true,
        .future, .subtask => return WasiP2Error.InvalidHandle,
    }
    end.state = .done;
    return (async_mod.ReturnCode{ .dropped = 0 }).encode();
}

/// `read-directory` (self, retptr) → tuple<stream<directory-entry>, future>:
/// register a P1 readdir cursor under the stream's shared id; the stream-read
/// path marshals `directory-entry` records (24 B, align 4: %type@0 (16),
/// name string@16 (ptr,len)) with names in fresh cabi_realloc backings.
fn fs3ReadDirectory(caller: *Caller, self_handle: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fd = try fs3Fd(ctx, self_handle);
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    const state_index: u32 = @intCast(ctx.dir_streams.items.len);
    ctx.dir_streams.append(ctx.alloc, .{ .fd = fd, .cookie = 0 }) catch return WasiP2Error.OutOfMemory;
    try ctx.host_dir_streams.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, state_index);
    try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    try mem.write(retptr, pair.readable);
    try mem.write(retptr + 4, fut.readable);
}

/// Bind one ASYNC-lowered host import (`canon lower ... async`): the timer
/// waits (genuinely async) + the wasi:filesystem@0.3.0 async funcs
/// (async-EAGER per ADR-0205 D5; flat params ≤ 4 stay flat + retptr, larger
/// signatures spill to one args-ptr + retptr; each returns the packed subtask
/// status). Any op outside this table completes eagerly through its SYNC
/// trampoline only — an async lower of it is unreached by the conformance
/// corpus, so reject until its phase (C sockets / D http) binds it.
fn defineAsyncLoweredOp(lk: *Linker, ns: []const u8, name: []const u8, op: adapter.P2Op, ctx: *WasiP2Ctx) !void {
    const binds = .{
        .{ adapter.P2Op.clocks_wait_until, fn (*Caller, i64) WasiP2Error!u32, p2WaitUntil },
        .{ adapter.P2Op.clocks_wait_for, fn (*Caller, i64) WasiP2Error!u32, p2WaitFor },
        .{ adapter.P2Op.fs3_stat, fn (*Caller, u32, u32) WasiP2Error!u32, fs3Stat },
        .{ adapter.P2Op.fs3_get_type, fn (*Caller, u32, u32) WasiP2Error!u32, fs3GetType },
        .{ adapter.P2Op.fs3_get_flags, fn (*Caller, u32, u32) WasiP2Error!u32, fs3GetFlags },
        .{ adapter.P2Op.fs3_sync, fn (*Caller, u32, u32) WasiP2Error!u32, fs3Sync },
        .{ adapter.P2Op.fs3_sync_data, fn (*Caller, u32, u32) WasiP2Error!u32, fs3SyncData },
        .{ adapter.P2Op.fs3_metadata_hash, fn (*Caller, u32, u32) WasiP2Error!u32, fs3MetadataHash },
        .{ adapter.P2Op.fs3_set_size, fn (*Caller, u32, i64, u32) WasiP2Error!u32, fs3SetSize },
        .{ adapter.P2Op.fs3_advise, fn (*Caller, u32, i64, i64, u32, u32) WasiP2Error!u32, fs3Advise },
        .{ adapter.P2Op.fs3_stat_at, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!u32, fs3StatAt },
        .{ adapter.P2Op.fs3_metadata_hash_at, fn (*Caller, u32, u32, u32, u32, u32) WasiP2Error!u32, fs3MetadataHashAt },
        .{ adapter.P2Op.fs3_create_directory_at, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, fs3CreateDirectoryAt },
        .{ adapter.P2Op.fs3_remove_directory_at, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, fs3RemoveDirectoryAt },
        .{ adapter.P2Op.fs3_unlink_file_at, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, fs3UnlinkFileAt },
        .{ adapter.P2Op.fs3_readlink_at, fn (*Caller, u32, u32, u32, u32) WasiP2Error!u32, fs3ReadlinkAt },
        .{ adapter.P2Op.fs3_is_same_object, fn (*Caller, u32, u32, u32) WasiP2Error!u32, fs3IsSameObject },
        .{ adapter.P2Op.fs3_open_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3OpenAt },
        .{ adapter.P2Op.fs3_set_times, fn (*Caller, u32, u32) WasiP2Error!u32, fs3SetTimes },
        .{ adapter.P2Op.fs3_set_times_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3SetTimesAt },
        .{ adapter.P2Op.fs3_rename_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3RenameAt },
        .{ adapter.P2Op.fs3_symlink_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3SymlinkAt },
        .{ adapter.P2Op.fs3_link_at, fn (*Caller, u32, u32) WasiP2Error!u32, fs3LinkAt },
        .{ adapter.P2Op.sock3_tcp_connect, fn (*Caller, u32, u32) WasiP2Error!u32, sock3TcpConnect },
        .{ adapter.P2Op.sock3_udp_send, fn (*Caller, u32, u32) WasiP2Error!u32, sock3UdpSend },
        .{ adapter.P2Op.sock3_udp_receive, fn (*Caller, u32, u32) WasiP2Error!u32, sock3UdpReceive },
        .{ adapter.P2Op.sock3_resolve_addresses, fn (*Caller, u32, u32, u32) WasiP2Error!u32, sock3ResolveAddresses },
        .{ adapter.P2Op.http3_client_send, fn (*Caller, u32, u32) WasiP2Error!u32, http3ClientSend },
    };
    inline for (binds) |b| {
        if (op == b[0]) return lk.defineFuncCtx(ns, name, ctx, b[1], b[2]);
    }
    return error.UnsupportedWasiImport;
}

/// Read up to `count` `directory-entry` records from the P1 readdir cursor at
/// `dir_streams[state_index]` into guest memory at `ptr` (record = 24 B,
/// align 4: %type variant@0 (16), name string@16 (ptr@16, len@20); names land
/// in fresh cabi_realloc backings). P1's synthetic "."/".." are skipped.
/// Exhaustion with nothing read = the stream closes (DROPPED), so the guest
/// never spins on 0-entry completions.
fn fs3DirStreamRead(ctx: *WasiP2Ctx, state_index: u32, end: *async_mod.StreamFutureEnd, ptr: u32, count: u32) WasiP2Error!u32 {
    if (state_index >= ctx.dir_streams.items.len) return WasiP2Error.InvalidHandle;
    const state = &ctx.dir_streams.items[state_index];
    const mem = try ctx.memory();
    const buf_len: u32 = 4096;
    const buf_ptr = try ctx.reallocGuest(buf_len, 8);
    const used_ptr = try ctx.reallocGuest(4, 4);
    var filled: u32 = 0;
    outer: while (filled < count) {
        const errno = wasi_fd.fdReaddir(ctx.host, mem.slice(), state.fd, buf_ptr, buf_len, state.cookie, used_ptr);
        if (errno != .success) return WasiP2Error.WriteFailed;
        const used = try mem.read(u32, used_ptr);
        if (used < 24) break :outer; // stream end
        const d_next = try mem.read(u64, buf_ptr);
        const d_namlen = try mem.read(u32, buf_ptr + 16);
        const d_type = try mem.read(u8, buf_ptr + 20);
        if (used < 24 + d_namlen) return WasiP2Error.OutOfBounds; // > 4 KiB name
        state.cookie = d_next;
        const name = mem.sliceAt(buf_ptr + 24, d_namlen) catch return WasiP2Error.OutOfBounds;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const name_ptr = if (d_namlen == 0) 0 else try ctx.reallocGuest(d_namlen, 1);
        if (d_namlen != 0) {
            const dest = mem.sliceAt(name_ptr, d_namlen) catch return WasiP2Error.OutOfBounds;
            // Re-slice the source: reallocGuest may have moved/grown memory.
            const src = mem.sliceAt(buf_ptr + 24, d_namlen) catch return WasiP2Error.OutOfBounds;
            @memcpy(dest, src);
        }
        const rec = ptr + filled * 24;
        const p1_ft: wasi_p1.Filetype = @enumFromInt(d_type);
        try writeFs3DescriptorType(mem, rec, p1_ft);
        try mem.write(rec + 16, name_ptr);
        try mem.write(rec + 20, d_namlen);
        filled += 1;
    }
    if (filled == 0) {
        switch ((try ctx.shared.get(end.shared)).*) {
            .stream => |*s| s.dropped = true,
            .future, .subtask => return WasiP2Error.InvalidHandle,
        }
        end.state = .done;
        return (async_mod.ReturnCode{ .dropped = 0 }).encode();
    }
    return (async_mod.ReturnCode{ .completed = @intCast(filled) }).encode();
}

// ============================================================
// wasi:sockets@0.3.0 (ADR-0205 phase C)
// ============================================================
// The 0.3 socket surface: `tcp-socket`/`udp-socket` resources on the CM-async
// data plane. Sync plain funcs (create/bind/listen/receive/getters/setters)
// bind directly; `tcp.connect` + `udp.send`/`udp.receive` arrive ASYNC-LOWERED
// and complete eagerly (blocking on the loopback-class targets the corpus
// exercises); `tcp.listen`/`send`/`receive` mint host SOCKET stream peers
// (accept / tx / rx) like the fs3 file peers.

/// 0.3 `wasi:sockets/types` `error-code` variant ordinals (0.2's `unknown`/
/// `would-block` removed; `other(option<string>)` = 14 is the catch-all).
fn sockErrToFs3Code(e: anyerror) u8 {
    return switch (e) {
        error.AccessDenied, error.PermissionDenied => 0,
        error.OptionUnsupported, error.SocketModeUnsupported, error.Unsupported => 1,
        error.InvalidArgument, error.FamilyMismatch => 2,
        error.OutOfMemory, error.SystemResources => 3,
        error.Timeout, error.ConnectionTimedOut, error.WouldBlock => 4,
        error.InvalidState, error.NotInProgress, error.AlreadyBound, error.AlreadyListening, error.AlreadyConnected, error.NotConnected => 5,
        error.AddressNotAvailable, error.AddressUnavailable => 6,
        error.AddressInUse => 7,
        error.NetworkUnreachable, error.HostUnreachable, error.NetworkDown => 8,
        error.ConnectionRefused => 9,
        error.BrokenPipe => 10,
        error.ConnectionResetByPeer => 11,
        error.ConnectionAborted => 12,
        error.MessageTooBig, error.MessageOversize => 13,
        else => 14,
    };
}

test "D-444 II: sockErrToFs3Code — every 0.3 error-code ordinal, incl. the catch-all" {
    const cases = [_]struct { e: anyerror, code: u8 }{
        .{ .e = error.AccessDenied, .code = 0 },
        .{ .e = error.PermissionDenied, .code = 0 },
        .{ .e = error.Unsupported, .code = 1 },
        .{ .e = error.InvalidArgument, .code = 2 },
        .{ .e = error.FamilyMismatch, .code = 2 },
        .{ .e = error.OutOfMemory, .code = 3 },
        .{ .e = error.Timeout, .code = 4 },
        .{ .e = error.WouldBlock, .code = 4 },
        .{ .e = error.InvalidState, .code = 5 },
        .{ .e = error.AlreadyBound, .code = 5 },
        .{ .e = error.NotConnected, .code = 5 },
        .{ .e = error.AddressNotAvailable, .code = 6 },
        .{ .e = error.AddressInUse, .code = 7 },
        .{ .e = error.NetworkUnreachable, .code = 8 },
        .{ .e = error.HostUnreachable, .code = 8 },
        .{ .e = error.ConnectionRefused, .code = 9 },
        .{ .e = error.BrokenPipe, .code = 10 },
        .{ .e = error.ConnectionResetByPeer, .code = 11 },
        .{ .e = error.ConnectionAborted, .code = 12 },
        .{ .e = error.MessageTooBig, .code = 13 },
        .{ .e = error.Unexpected, .code = 14 }, // catch-all `other`
    };
    for (cases) |c| try std.testing.expectEqual(c.code, sockErrToFs3Code(c.e));
}

/// `result.err(error-code)` for a 0.3 sockets result whose payload slot sits
/// at `payload_off` (the error-code variant: disc u8, `other`'s
/// option<string> at +4 → none).
fn writeSock3Err(mem: Memory, retptr: u32, payload_off: u32, e: anyerror) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 1));
    try mem.write(retptr + payload_off, sockErrToFs3Code(e));
    try mem.write(retptr + payload_off + 4, @as(u8, 0));
}

fn writeSock3UnitResult(mem: Memory, retptr: u32, err: ?anyerror) WasiP2Error!void {
    if (err) |e| return writeSock3Err(mem, retptr, 4, e);
    try mem.write(retptr, @as(u8, 0));
}

/// The live `UdpSocket` behind a UDP3 handle rep.
fn ctxUdpSocket(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*p2sock.UdpSocket {
    if (rep >= ctx.udp_sockets.items.len) return resource_table.Error.InvalidHandle;
    return &ctx.udp_sockets.items[rep];
}

/// Address classification for the WIT's unicast-only contracts.
fn sock3IsMulticastOrBroadcast(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| (a.bytes[0] >= 224 and a.bytes[0] <= 239) or
            (a.bytes[0] == 255 and a.bytes[1] == 255 and a.bytes[2] == 255 and a.bytes[3] == 255),
        .ip6 => |a| a.bytes[0] == 0xff,
    };
}

/// `::ffff:a.b.c.d` — the WIT rejects IPv4-mapped IPv6 on every path.
fn sock3IsV4MappedV6(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => false,
        .ip6 => |a| std.mem.allEqual(u8, a.bytes[0..10], 0) and a.bytes[10] == 0xff and a.bytes[11] == 0xff,
    };
}

fn sock3IsAnyAddr(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| a.bytes[0] == 0 and a.bytes[1] == 0 and a.bytes[2] == 0 and a.bytes[3] == 0,
        .ip6 => |a| std.mem.allEqual(u8, &a.bytes, 0),
    };
}

/// `[static]tcp-socket.create` (family, retptr) → result<own, error-code>.
fn sock3TcpCreate(caller: *Caller, family: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (family > 1) return writeSock3Err(mem, retptr, 4, error.InvalidArgument);
    const idx: u32 = @intCast(ctx.tcp_sockets.items.len);
    ctx.tcp_sockets.append(ctx.alloc, p2sock.TcpSocket.create(@enumFromInt(family))) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.TCP_SOCKET_RT, idx);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

fn sock3TcpSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p2sock.TcpSocket {
    return ctxTcpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self));
}

/// `tcp.bind` (self, disc, p0..p10, retptr) — the 0.3 one-shot bind (the 0.2
/// start/finish pair collapsed).
fn sock3TcpBind(caller: *Caller, self: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3TcpSelf(ctx, self);
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    if (sock3IsMulticastOrBroadcast(addr) or sock3IsV4MappedV6(addr))
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    const io = try ctxIo(ctx);
    sock.startBind(io, addr) catch |e| return writeSock3UnitResult(mem, retptr, e);
    sock.finishBind() catch |e| return writeSock3UnitResult(mem, retptr, e);
    sock.bindNow(io) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

/// `[async-lower]tcp.connect` — spilled args (self@0, addr variant@4: disc
/// u8@+4, payload@+8). Completes eagerly (a blocking loopback-class connect).
fn sock3TcpConnect(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self = try mem.read(u32, argsptr);
    const addr = (try readSock3AddrVariant(mem, argsptr + 4)) orelse {
        try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
        return SUBTASK_RETURNED;
    };
    if (sock3IsMulticastOrBroadcast(addr) or sock3IsAnyAddr(addr) or sock3IsV4MappedV6(addr) or switch (addr) {
        .ip4 => |a| a.port == 0,
        .ip6 => |a| a.port == 0,
    }) {
        try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
        return SUBTASK_RETURNED;
    }
    const sock = try sock3TcpSelf(ctx, self);
    const io = try ctxIo(ctx);
    // Explicitly bound (the 0.3 `bind` → `connect` transition) takes the
    // raw bound-connect composition; everything else the std connect.
    if (sock.state == .bound) {
        sock.connectFromBound(io, addr) catch |e| {
            try writeSock3UnitResult(mem, retptr, e);
            return SUBTASK_RETURNED;
        };
    } else sock.startConnect(io, addr) catch |e| {
        try writeSock3UnitResult(mem, retptr, e);
        return SUBTASK_RETURNED;
    };
    sock.finishConnect() catch |e| {
        try writeSock3UnitResult(mem, retptr, e);
        return SUBTASK_RETURNED;
    };
    try writeSock3UnitResult(mem, retptr, null);
    return SUBTASK_RETURNED;
}

/// An in-memory `ip-socket-address` variant (disc u8@0, payload@4; ipv4
/// record port u16@0 + 4 bytes; ipv6 port@0, flow u32@4, 8×u16 segments@8,
/// scope@24).
fn readSock3AddrVariant(mem: Memory, base: u32) WasiP2Error!?std.Io.net.IpAddress {
    const disc = try mem.read(u8, base);
    const pay = base + 4;
    switch (disc) {
        0 => {
            const port = try mem.read(u16, pay);
            return .{ .ip4 = .{ .port = port, .bytes = .{
                try mem.read(u8, pay + 2),
                try mem.read(u8, pay + 3),
                try mem.read(u8, pay + 4),
                try mem.read(u8, pay + 5),
            } } };
        },
        1 => {
            const port = try mem.read(u16, pay);
            const flow = try mem.read(u32, pay + 4);
            var bytes: [16]u8 = undefined;
            for (0..8) |i| {
                const seg = try mem.read(u16, pay + 8 + @as(u32, @intCast(i * 2)));
                bytes[i * 2] = @intCast(seg >> 8);
                bytes[i * 2 + 1] = @truncate(seg);
            }
            return .{ .ip6 = .{ .port = port, .bytes = bytes, .flow = flow } };
        },
        else => return null,
    }
}

/// `tcp.listen` (self, retptr) → result<stream<tcp-socket>, error-code>: mint
/// the accept stream (host ACCEPT peer keyed by its shared id).
fn sock3TcpListen(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    {
        const sock = try ctxTcpSocket(ctx, rep);
        const io = try ctxIo(ctx);
        sock.listenNow(io) catch |e| return writeSock3Err(mem, retptr, 4, e);
    }
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    try ctx.host_accept_streams.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, rep);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, pair.readable);
}

/// `tcp.send` (self, data readable-stream) → future handle: the host drains
/// the guest's stream into the connected socket.
fn sock3TcpSend(caller: *Caller, self: u32, data_handle: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    const shared_id = blk: {
        const end = try ctx.streams.get(data_handle);
        if (end.kind != .stream) return WasiP2Error.InvalidHandle;
        break :blk end.shared;
    };
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    if ((try ctxTcpSocket(ctx, rep)).state != .connected) {
        // Not connected → err(invalid-state) future (official
        // sockets-tcp-send test_connected_state; mirrors receive).
        try ctx.host_result_futures.put(ctx.alloc, fut.readable, sockErrToFs3Code(error.InvalidState));
        return fut.readable;
    }
    // NOT eager: the future resolves at tx-drop / drain-error time
    // (sock3ResolveSendFuture) — the guest awaits it before writing under
    // `futures::join!`, so an eager ok would hide later drain failures
    // (official sockets-tcp-receive test_drop_read_half).
    try ctx.host_tcp_tx.put(ctx.alloc, shared_id, .{ .rep = rep, .fut = fut.readable });
    try sock3DrainParkedTcpWrite(ctx, shared_id);
    return fut.readable;
}

/// Resolve a `tcp.send` result future (ok = null / err = 0.3 error-code).
/// The send future is NOT eager — the guest usually awaits it BEFORE the
/// data stream is written+dropped (`futures::join!`), so the outcome lands
/// here at drain-error / tx-drop time: record it for a not-yet-issued read,
/// and complete an already-parked read in place (marshal + FUTURE_READ
/// event). First resolution wins (a drain error is not overwritten by the
/// ok of the subsequent drop).
fn sock3ResolveSendFuture(ctx: *WasiP2Ctx, fut_handle: u32, outcome: ?u8) WasiP2Error!void {
    const gop = try ctx.host_result_futures.getOrPut(ctx.alloc, fut_handle);
    if (gop.found_existing) return;
    gop.value_ptr.* = outcome;
    const pr = ctx.pending_reads.get(fut_handle) orelse return;
    const end = ctx.streams.get(fut_handle) catch return;
    const mem = try ctx.memory();
    if (outcome) |code| {
        const buf = mem.sliceAt(pr.ptr, 9) catch return WasiP2Error.OutOfBounds;
        buf[0] = 1;
        buf[4] = code;
        buf[8] = 0;
    } else {
        const buf = mem.sliceAt(pr.ptr, 1) catch return WasiP2Error.OutOfBounds;
        buf[0] = 0;
    }
    end.state = .done;
    end.setPendingEvent(.{ .code = .future_read, .index = fut_handle, .payload = (async_mod.ReturnCode{ .completed = 0 }).encode() });
    _ = ctx.pending_reads.remove(fut_handle);
}

/// A writer parked before `tcp.send` registered the socket sink: drain now.
fn sock3DrainParkedTcpWrite(ctx: *WasiP2Ctx, shared_id: u32) WasiP2Error!void {
    const sh = try ctx.shared.get(shared_id);
    const pending = switch (sh.*) {
        .stream => |*st| st.pending orelse return,
        .future, .subtask => return,
    };
    if (pending.side != .writable) return;
    const pw = ctx.pending_writes.get(pending.waitable) orelse return;
    const role = ctx.host_tcp_tx.get(shared_id) orelse return;
    const mem = try ctx.memory();
    const bytes = mem.sliceAt(pw.ptr, pw.count * pw.elem_size) catch return WasiP2Error.OutOfBounds;
    const sock = try ctxTcpSocket(ctx, role.rep);
    const io = try ctxIo(ctx);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = sock.send(io, bytes[off..]) catch |e| {
            try sock3ResolveSendFuture(ctx, role.fut, sockErrToFs3Code(e));
            break;
        };
        if (n == 0) break;
        off += n;
    }
    const writer = try ctx.streams.get(pending.waitable);
    writer.state = .idle;
    writer.setPendingEvent(.{ .code = .stream_write, .index = pending.waitable, .payload = (async_mod.ReturnCode{ .completed = @intCast(pw.count) }).encode() });
    switch (sh.*) {
        .stream => |*st| st.pending = null,
        .future, .subtask => {},
    }
    _ = ctx.pending_writes.remove(pending.waitable);
}

/// `tcp.receive` (self, retptr) → tuple<stream<u8>, future<...>>: the host
/// supplies bytes recv'd from the connected socket.
fn sock3TcpReceive(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const rep = try ctx.resources.rep(WasiP2Ctx.TCP_SOCKET_RT, self);
    const sockp = try ctxTcpSocket(ctx, rep);
    const usable = sockp.state == .connected and !sockp.rx_taken;
    const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    if (usable) {
        sockp.rx_taken = true;
        try ctx.host_tcp_rx.put(ctx.alloc, (try ctx.streams.get(pair.readable)).shared, rep);
        try ctx.host_result_futures.put(ctx.alloc, fut.readable, null);
    } else {
        // Not connected (or `receive` already taken — it is single-shot) →
        // err(invalid-state) future + an immediately-closed stream
        // (official sockets-tcp-receive test_connected_state /
        // test_multiple_receive).
        try ctx.host_result_futures.put(ctx.alloc, fut.readable, sockErrToFs3Code(error.InvalidState));
        switch ((try ctx.shared.get((try ctx.streams.get(pair.readable)).shared)).*) {
            .stream => |*st| st.dropped = true,
            else => {},
        }
    }
    try mem.write(retptr, pair.readable);
    try mem.write(retptr + 4, fut.readable);
}

fn sock3TcpLocalAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3TcpSelf(ctx, self);
    const addr = sock.localAddress() catch |e| return writeSock3Err(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

fn sock3TcpRemoteAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3TcpSelf(ctx, self);
    const addr = sock.remoteAddress() catch |e| return writeSock3Err(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

fn sock3TcpIsListening(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const sock = try sock3TcpSelf(ctx, self);
    return @intFromBool(sock.state == .listening);
}

fn sock3TcpFamily(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const sock = try sock3TcpSelf(ctx, self);
    return @intFromEnum(sock.family);
}

fn sock3TcpSetBacklog(caller: *Caller, self: u32, value: u64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3TcpSelf(ctx, self);
    if (value == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    sock.setListenBacklog(value) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

// -- TCP option getters/setters (stored-value model; the OS socket is lazy,
// so options are recorded with the spec's clamp-permitting semantics) --

fn writeSock3OkU8(mem: Memory, retptr: u32, v: u8) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, v);
}

fn writeSock3OkU32(mem: Memory, retptr: u32, v: u32) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, v);
}

fn writeSock3OkU64(mem: Memory, retptr: u32, v: u64) WasiP2Error!void {
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 8, v);
}

fn sock3TcpKaEnabledGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU8(mem, retptr, @intFromBool((try sock3TcpSelf(ctx, self)).opt_keep_alive));
}

fn sock3TcpKaEnabledSet(caller: *Caller, self: u32, value: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    (try sock3TcpSelf(ctx, self)).opt_keep_alive = value != 0;
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpKaIdleGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_ka_idle_ns);
}

fn sock3TcpKaIdleSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    // Clamp to whole seconds ≥ 1 (TCP_KEEPIDLE granularity) — read-back may
    // differ from the set value per the WIT contract.
    (try sock3TcpSelf(ctx, self)).opt_ka_idle_ns = @max(v - v % std.time.ns_per_s, std.time.ns_per_s);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpKaIntervalGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_ka_interval_ns);
}

fn sock3TcpKaIntervalSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_ka_interval_ns = @max(v - v % std.time.ns_per_s, std.time.ns_per_s);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpKaCountGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU32(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_ka_count);
}

fn sock3TcpKaCountSet(caller: *Caller, self: u32, value: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (value == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_ka_count = value;
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpHopGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU8(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_hop_limit);
}

fn sock3TcpHopSet(caller: *Caller, self: u32, value: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (value == 0 or value > 255) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_hop_limit = @intCast(value);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpRcvbufGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_rcvbuf);
}

fn sock3TcpRcvbufSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_rcvbuf = @min(v, 8 << 20); // clamp to 8 MiB
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3TcpSndbufGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3TcpSelf(ctx, self)).opt_sndbuf);
}

fn sock3TcpSndbufSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3TcpSelf(ctx, self)).opt_sndbuf = @min(v, 8 << 20);
    try writeSock3UnitResult(mem, retptr, null);
}

// -- UDP --

fn sock3UdpCreate(caller: *Caller, family: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (family > 1) return writeSock3Err(mem, retptr, 4, error.InvalidArgument);
    const idx: u32 = @intCast(ctx.udp_sockets.items.len);
    ctx.udp_sockets.append(ctx.alloc, p2sock.UdpSocket.create(@enumFromInt(family))) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.UDP_SOCKET3_RT, idx);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

fn sock3UdpSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p2sock.UdpSocket {
    return ctxUdpSocket(ctx, try ctx.resources.rep(WasiP2Ctx.UDP_SOCKET3_RT, self));
}

fn sock3UdpBind(caller: *Caller, self: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    if (sock3IsMulticastOrBroadcast(addr) or sock3IsV4MappedV6(addr))
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    sock.bind(try ctxIo(ctx), addr) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3UdpConnect(caller: *Caller, self: u32, disc: u32, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32, p5: u32, p6: u32, p7: u32, p8: u32, p9: u32, p10: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    const addr = decodeIpSocketAddress(disc, .{ p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 }) orelse
        return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    if (sock3IsMulticastOrBroadcast(addr) or sock3IsAnyAddr(addr) or sock3IsV4MappedV6(addr) or switch (addr) {
        .ip4 => |a| a.port == 0,
        .ip6 => |a| a.port == 0,
    }) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    sock.connect(try ctxIo(ctx), addr) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3UdpDisconnect(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    sock.disconnect(try ctxIo(ctx)) catch |e| return writeSock3UnitResult(mem, retptr, e);
    try writeSock3UnitResult(mem, retptr, null);
}

/// Structural equality of two socket addresses (port + raw address bytes).
fn sock3AddrEql(a: std.Io.net.IpAddress, b: std.Io.net.IpAddress) bool {
    return switch (a) {
        .ip4 => |x| switch (b) {
            .ip4 => |y| x.port == y.port and std.mem.eql(u8, &x.bytes, &y.bytes),
            .ip6 => false,
        },
        .ip6 => |x| switch (b) {
            .ip6 => |y| x.port == y.port and std.mem.eql(u8, &x.bytes, &y.bytes),
            .ip4 => false,
        },
    };
}

/// `[async-lower]udp.send` — spilled args: self@0, data list@4 (ptr,len),
/// remote option<ip-socket-address>@12 (disc u8@12, addr variant@16).
fn sock3UdpSend(caller: *Caller, argsptr: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const self = try mem.read(u32, argsptr);
    const data_ptr = try mem.read(u32, argsptr + 4);
    const data_len = try mem.read(u32, argsptr + 8);
    const has_remote = (try mem.read(u8, argsptr + 12)) != 0;
    const sock = try sock3UdpSelf(ctx, self);
    const dest: std.Io.net.IpAddress = blk: {
        if (has_remote) {
            const a = (try readSock3AddrVariant(mem, argsptr + 16)) orelse {
                try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
                return SUBTASK_RETURNED;
            };
            break :blk a;
        }
        break :blk sock.remote orelse {
            try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
            return SUBTASK_RETURNED;
        };
    };
    // Pre-OS validation — an EINVAL sendto is an errnoBug PANIC in the
    // pinned stdlib, so the invalid-argument classes never reach the OS:
    // family mismatch / unspecified ip / port 0, and a connected socket
    // only sends to its own remote.
    if (has_remote) {
        const fam_ok = switch (dest) {
            .ip4 => sock.family == .ipv4,
            .ip6 => sock.family == .ipv6,
        };
        const port_zero = switch (dest) {
            .ip4 => |a| a.port == 0,
            .ip6 => |a| a.port == 0,
        };
        if (!fam_ok or port_zero or sock3IsAnyAddr(dest)) {
            try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
            return SUBTASK_RETURNED;
        }
        if (sock.remote) |r| if (!sock3AddrEql(dest, r)) {
            try writeSock3UnitResult(mem, retptr, error.InvalidArgument);
            return SUBTASK_RETURNED;
        };
    }
    const bytes = mem.sliceAt(data_ptr, data_len) catch return WasiP2Error.OutOfBounds;
    sock.sendTo(try ctxIo(ctx), dest, bytes) catch |e| {
        try writeSock3UnitResult(mem, retptr, e);
        return SUBTASK_RETURNED;
    };
    try writeSock3UnitResult(mem, retptr, null);
    return SUBTASK_RETURNED;
}

/// `[async-lower]udp.receive` (self, retptr) →
/// result<tuple<list<u8>, ip-socket-address>, error-code>: ok payload@4 =
/// list (ptr,len)@4..12 + address variant@12 (disc u8@12, case record@16).
fn sock3UdpReceive(caller: *Caller, self: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const rep = try ctx.resources.rep(WasiP2Ctx.UDP_SOCKET3_RT, self);
    const sock = try ctxUdpSocket(ctx, rep);
    if (sock.socket == null) {
        // Unbound → invalid-state (official udp-receive test_not_bound).
        try writeSock3Err(mem, retptr, 4, error.InvalidState);
        return SUBTASK_RETURNED;
    }
    if (sock.readyIn() catch false) {
        try sock3UdpReceiveComplete(ctx, rep, retptr);
        return SUBTASK_RETURNED;
    }
    // No datagram queued → park as a subtask waitable (the timer pattern):
    // `pollBlockedUdpReceives` completes it at readiness. Receiving eagerly
    // here would block the whole runtime and starve the guest's own
    // sending task (official udp-receive test_receive_data joins both).
    const h = try ctx.streams.add(.{
        .kind = .subtask,
        .side = .readable,
        .elem_type = null,
        .subtask_state = .started,
    });
    try ctx.blocked_udp_receives.put(ctx.alloc, h, .{ .rep = rep, .retptr = retptr });
    return @intFromEnum(async_mod.SubtaskState.started) | (h << 4);
}

/// The receive proper: recvfrom into a fresh guest buffer + marshal the
/// `result<tuple<list<u8>, ip-socket-address>, _>` ok payload at `retptr`.
/// Shared by the eager (data already queued) and parked-completion paths.
fn sock3UdpReceiveComplete(ctx: *WasiP2Ctx, rep: u32, retptr: u32) WasiP2Error!void {
    const mem = try ctx.memory();
    const sock = try ctxUdpSocket(ctx, rep);
    const buf_ptr = try ctx.reallocGuest(65536, 1);
    const buf = mem.sliceAt(buf_ptr, 65536) catch return WasiP2Error.OutOfBounds;
    const r = sock.receiveFrom(try ctxIo(ctx), buf) catch |e| {
        return writeSock3Err(mem, retptr, 4, e);
    };
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, buf_ptr);
    try mem.write(retptr + 8, @as(u32, @intCast(r.n)));
    switch (r.from) {
        .ip4 => |a| {
            try mem.write(retptr + 12, @as(u8, 0));
            try mem.write(retptr + 16, a.port);
            for (a.bytes, 0..) |b, i| try mem.write(retptr + 18 + @as(u32, @intCast(i)), b);
        },
        .ip6 => |a| {
            try mem.write(retptr + 12, @as(u8, 1));
            try mem.write(retptr + 16, a.port);
            try mem.write(retptr + 20, a.flow);
            for (0..8) |i| {
                const seg: u16 = (@as(u16, a.bytes[i * 2]) << 8) | a.bytes[i * 2 + 1];
                try mem.write(retptr + 24 + @as(u32, @intCast(i * 2)), seg);
            }
            try mem.write(retptr + 40, @as(u32, 0)); // scope-id
        },
    }
}

// ============================================================
// wasi:http/types@0.3.0 (ADR-0205 phase D)
// ============================================================
// The `fields` resource: data model in src/wasi/p3_http.zig; these
// trampolines marshal guest memory. Canonical shapes: field-name = string
// (ptr,len), field-value = list<u8> (ptr,len), entries/copy-all elems =
// (name_ptr, name_len, val_ptr, val_len) 16 B; `result<_, header-error>` =
// disc u8@0, err variant disc u8@4, `other`'s option<string> none u8@8.

fn ctxHttpFields(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*p3http.HttpFields {
    if (rep >= ctx.http_fields.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_fields.items[rep];
}

fn http3FieldsSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpFields {
    const rep = ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, self) catch
        try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, self);
    return ctxHttpFields(ctx, rep);
}

fn http3MintFields(ctx: *WasiP2Ctx, fields: p3http.HttpFields) WasiP2Error!u32 {
    const idx: u32 = @intCast(ctx.http_fields.items.len);
    ctx.http_fields.append(ctx.alloc, fields) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_RT, idx);
}

/// `result<_, header-error>` (ok = null).
fn writeHeaderErrResult(mem: Memory, retptr: u32, e: ?p3http.FieldsError) WasiP2Error!void {
    if (e) |err| {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, p3http.headerErrorOrdinal(err));
        try mem.write(retptr + 8, @as(u8, 0)); // other's option<string>: none
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

fn http3FieldsNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return http3MintFields(ctx, .{});
}

fn http3FieldsFromList(caller: *Caller, entries_ptr: u32, entries_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    var fields: p3http.HttpFields = .{};
    var i: u32 = 0;
    while (i < entries_len) : (i += 1) {
        const rec = entries_ptr + i * 16;
        const name = mem.sliceAt(try mem.read(u32, rec), try mem.read(u32, rec + 4)) catch return WasiP2Error.OutOfBounds;
        const value = mem.sliceAt(try mem.read(u32, rec + 8), try mem.read(u32, rec + 12)) catch return WasiP2Error.OutOfBounds;
        if (dbg.on("async.host")) std.debug.print("[host] fields.from-list [{d}] name='{s}' value='{s}'\n", .{ i, name, value });
        fields.appendChecked(ctx.alloc, name, value) catch |e| {
            fields.deinit(ctx.alloc);
            try mem.write(retptr, @as(u8, 1));
            try mem.write(retptr + 4, p3http.headerErrorOrdinal(e));
            try mem.write(retptr + 8, @as(u8, 0));
            return;
        };
    }
    const handle = try http3MintFields(ctx, fields);
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, handle);
}

/// Marshal one nested byte blob (string / list<u8>) into its OWN guest
/// allocation. Nested lists must NOT share the outer table's block: the
/// guest's lift takes per-element buffer OWNERSHIP (Vec::from_raw_parts)
/// and frees the outer table separately — a packed single block gets
/// recycled by the guest allocator mid-lift, corrupting the data. A
/// zero-length blob writes a 4-aligned dangling pointer (the guest never
/// dereferences or frees a capacity-0 buffer).
fn http3AllocBlob(ctx: *WasiP2Ctx, mem: Memory, bytes: []const u8) WasiP2Error!u32 {
    if (bytes.len == 0) return 4;
    const p = try ctx.reallocGuest(@intCast(bytes.len), 1);
    const dest = mem.sliceAt(p, @intCast(bytes.len)) catch return WasiP2Error.OutOfBounds;
    @memcpy(dest, bytes);
    return p;
}

/// Marshal `list<field-value>`: the elem table is one allocation, each
/// value another (see `http3AllocBlob`); (ptr,len) lands at `retptr`.
fn http3WriteValueList(ctx: *WasiP2Ctx, mem: Memory, retptr: u32, values: []const []const u8) WasiP2Error!void {
    const base = if (values.len == 0) 4 else try ctx.reallocGuest(@intCast(values.len * 8), 4);
    for (values, 0..) |v, i| {
        const p = try http3AllocBlob(ctx, mem, v);
        const rec = base + @as(u32, @intCast(i * 8));
        try mem.write(rec, p);
        try mem.write(rec + 4, @as(u32, @intCast(v.len)));
    }
    try mem.write(retptr, base);
    try mem.write(retptr + 4, @as(u32, @intCast(values.len)));
}

fn http3FieldsGet(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(ctx.alloc);
    fields.get(&values, ctx.alloc, name) catch return WasiP2Error.OutOfMemory;
    try http3WriteValueList(ctx, mem, retptr, values.items);
}

fn http3FieldsHas(caller: *Caller, self: u32, name_ptr: u32, name_len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    return @intFromBool(fields.has(name));
}

fn http3FieldsSet(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, values_ptr: u32, values_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(ctx.alloc);
    var i: u32 = 0;
    while (i < values_len) : (i += 1) {
        const rec = values_ptr + i * 8;
        const v = mem.sliceAt(try mem.read(u32, rec), try mem.read(u32, rec + 4)) catch return WasiP2Error.OutOfBounds;
        values.append(ctx.alloc, v) catch return WasiP2Error.OutOfMemory;
    }
    fields.set(ctx.alloc, name, values.items) catch |e| return writeHeaderErrResult(mem, retptr, e);
    try writeHeaderErrResult(mem, retptr, null);
}

fn http3FieldsDelete(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    fields.delete(ctx.alloc, name) catch |e| return writeHeaderErrResult(mem, retptr, e);
    try writeHeaderErrResult(mem, retptr, null);
}

fn http3FieldsGetAndDelete(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |v| ctx.alloc.free(v);
        out.deinit(ctx.alloc);
    }
    fields.getAndDelete(&out, ctx.alloc, name) catch |e| {
        // result<list<field-value>, header-error> err: disc@0, err disc@4,
        // other's option none@8 (same offsets as the unit form).
        return writeHeaderErrResult(mem, retptr, e);
    };
    try mem.write(retptr, @as(u8, 0));
    try http3WriteValueList(ctx, mem, retptr + 4, out.items);
}

fn http3FieldsAppend(caller: *Caller, self: u32, name_ptr: u32, name_len: u32, value_ptr: u32, value_len: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    const value = mem.sliceAt(value_ptr, value_len) catch return WasiP2Error.OutOfBounds;
    fields.append(ctx.alloc, name, value) catch |e| return writeHeaderErrResult(mem, retptr, e);
    try writeHeaderErrResult(mem, retptr, null);
}

fn http3FieldsCopyAll(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const fields = try http3FieldsSelf(ctx, self);
    // Elem table = one allocation; each name string and value list its own
    // (per-element buffer ownership — see http3AllocBlob).
    const items = fields.entries.items;
    const base = if (items.len == 0) 4 else try ctx.reallocGuest(@intCast(items.len * 16), 4);
    for (items, 0..) |p, i| {
        const np = try http3AllocBlob(ctx, mem, p.name);
        const vp = try http3AllocBlob(ctx, mem, p.value);
        const rec = base + @as(u32, @intCast(i * 16));
        try mem.write(rec, np);
        try mem.write(rec + 4, @as(u32, @intCast(p.name.len)));
        try mem.write(rec + 8, vp);
        try mem.write(rec + 12, @as(u32, @intCast(p.value.len)));
    }
    try mem.write(retptr, base);
    try mem.write(retptr + 4, @as(u32, @intCast(items.len)));
}

fn http3FieldsClone(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const src = try http3FieldsSelf(ctx, self);
    var copy: p3http.HttpFields = .{};
    src.cloneInto(ctx.alloc, &copy) catch {
        copy.deinit(ctx.alloc);
        return WasiP2Error.OutOfMemory;
    };
    return http3MintFields(ctx, copy);
}

// -- request / response / request-options (ADR-0205 phase D-2) --

/// Release a stream/future end TRANSFERRED into a request/response at
/// `new` time (the guest's own handle moved to the host): the peer must
/// observe DROPPED or its writer task never completes.
pub fn http3DropTransferredEnd(ctx: *WasiP2Ctx, handle: u32) void {
    if (handle == 0) return;
    _ = ctx.host_result_futures.remove(handle);
    _ = ctx.pending_reads.remove(handle);
    // EXEMPT-FALLBACK: destructor — a stale/already-dropped end is benign (D-568)
    async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, handle) catch {};
}

fn http3RequestSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpRequest {
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, self);
    if (rep >= ctx.http_requests.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_requests.items[rep];
}

fn http3ReqoptsSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpRequestOptions {
    const rep = ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_RT, self) catch
        try ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_VIEW_RT, self);
    if (rep >= ctx.http_reqopts.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_reqopts.items[rep];
}

fn http3ResponseSelf(ctx: *WasiP2Ctx, self: u32) WasiP2Error!*p3http.HttpResponse {
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_RESPONSE_RT, self);
    if (rep >= ctx.http_responses.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_responses.items[rep];
}

/// `request.new` (headers, option<stream<u8>>, trailers future,
/// option<own<request-options>>, retptr) — consumes the headers (and
/// options) own handles: their storage now belongs to the request and both
/// become immutable. Returns tuple<request, future<result<_, error-code>>>
/// at retptr; the transmission future stays unresolved until a send.
fn http3RequestNew(caller: *Caller, headers: u32, contents_disc: u32, contents: u32, trailers_fut: u32, opts_disc: u32, opts: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const headers_rep = try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    (try ctxHttpFields(ctx, headers_rep)).immutable = true;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    var options_rep: ?u32 = null;
    if (opts_disc != 0) {
        const orep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQOPTS_RT, opts);
        (try http3ReqoptsSelf(ctx, opts)).immutable = true;
        _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQOPTS_RT, opts);
        options_rep = orep;
    }
    const idx: u32 = @intCast(ctx.http_requests.items.len);
    ctx.http_requests.append(ctx.alloc, .{
        .headers_rep = headers_rep,
        .options_rep = options_rep,
        .contents_stream = if (contents_disc != 0) contents else null,
        .trailers_future = trailers_fut,
    }) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.HTTP_REQUEST_RT, idx);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try mem.write(retptr, handle);
    try mem.write(retptr + 4, fut.readable);
}

fn http3RequestGetMethod(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    switch (req.method) {
        .other => |s| {
            try mem.write(retptr, @as(u8, 9));
            const p = try http3AllocBlob(ctx, mem, s);
            try mem.write(retptr + 4, p);
            try mem.write(retptr + 8, @as(u32, @intCast(s.len)));
        },
        else => try mem.write(retptr, @as(u8, @intFromEnum(std.meta.activeTag(req.method)))),
    }
}

fn http3RequestSetMethod(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (disc < 9) {
        req.method.deinit(ctx.alloc);
        req.method = switch (disc) {
            0 => .get,
            1 => .head,
            2 => .post,
            3 => .put,
            4 => .delete,
            5 => .connect,
            6 => .options,
            7 => .trace,
            8 => .patch,
            else => unreachable,
        };
        return 0;
    }
    const name = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
    if (!p3http.validMethod(name)) return 1;
    // other("GET") etc. normalizes to the enum case (wasi-http#194).
    inline for (p3http.Method.known_names) |k| {
        if (std.mem.eql(u8, name, k.name)) {
            req.method.deinit(ctx.alloc);
            req.method = @unionInit(p3http.Method, @tagName(k.tag), {});
            return 0;
        }
    }
    const copy = ctx.alloc.dupe(u8, name) catch return WasiP2Error.OutOfMemory;
    req.method.deinit(ctx.alloc);
    req.method = .{ .other = copy };
    return 0;
}

/// Write `option<string>` (disc u8@0, ptr@4, len@8) from an optional slice.
fn http3WriteOptString(ctx: *WasiP2Ctx, mem: Memory, retptr: u32, s: ?[]const u8) WasiP2Error!void {
    if (s) |str| {
        try mem.write(retptr, @as(u8, 1));
        const p = try http3AllocBlob(ctx, mem, str);
        try mem.write(retptr + 4, p);
        try mem.write(retptr + 8, @as(u32, @intCast(str.len)));
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

/// Store an optional validated string field (dupe + free old).
fn http3SetOptString(ctx: *WasiP2Ctx, slot: *?[]u8, s: ?[]const u8) WasiP2Error!void {
    if (slot.*) |old| ctx.alloc.free(old);
    slot.* = if (s) |str| ctx.alloc.dupe(u8, str) catch return WasiP2Error.OutOfMemory else null;
}

fn http3RequestGetPwq(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    try http3WriteOptString(ctx, mem, retptr, req.path_with_query);
}

fn http3RequestSetPwq(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (disc == 0) {
        try http3SetOptString(ctx, &req.path_with_query, null);
        return 0;
    }
    const s = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
    if (!p3http.validPathWithQuery(s)) return 1;
    // The corpus pins "" → "/" (an empty path serializes as "/").
    try http3SetOptString(ctx, &req.path_with_query, if (s.len == 0) "/" else s);
    return 0;
}

fn http3RequestGetScheme(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    const sc = req.scheme orelse {
        try mem.write(retptr, @as(u8, 0));
        return;
    };
    try mem.write(retptr, @as(u8, 1));
    switch (sc) {
        .http => try mem.write(retptr + 4, @as(u8, 0)),
        .https => try mem.write(retptr + 4, @as(u8, 1)),
        .other => |s| {
            try mem.write(retptr + 4, @as(u8, 2));
            const p = try http3AllocBlob(ctx, mem, s);
            try mem.write(retptr + 8, p);
            try mem.write(retptr + 12, @as(u32, @intCast(s.len)));
        },
    }
}

fn http3RequestSetScheme(caller: *Caller, self: u32, opt_disc: u32, scheme_disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (opt_disc == 0) {
        if (req.scheme) |*old| old.deinit(ctx.alloc);
        req.scheme = null;
        return 0;
    }
    var next: p3http.Scheme = undefined;
    switch (scheme_disc) {
        0 => next = .http,
        1 => next = .https,
        else => {
            const s = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
            if (!p3http.validScheme(s)) return 1;
            // other("http"/"https") normalizes to the enum case (#194).
            if (std.mem.eql(u8, s, "http")) {
                next = .http;
            } else if (std.mem.eql(u8, s, "https")) {
                next = .https;
            } else {
                next = .{ .other = ctx.alloc.dupe(u8, s) catch return WasiP2Error.OutOfMemory };
            }
        },
    }
    if (req.scheme) |*old| old.deinit(ctx.alloc);
    req.scheme = next;
    return 0;
}

fn http3RequestGetAuthority(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    try http3WriteOptString(ctx, mem, retptr, req.authority);
}

fn http3RequestSetAuthority(caller: *Caller, self: u32, disc: u32, ptr: u32, len: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (disc == 0) {
        try http3SetOptString(ctx, &req.authority, null);
        return 0;
    }
    const s = mem.sliceAt(ptr, len) catch return WasiP2Error.OutOfBounds;
    if (!p3http.validAuthority(s)) return 1;
    try http3SetOptString(ctx, &req.authority, s);
    return 0;
}

fn http3RequestGetOptions(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, self);
    if (req.options_rep) |orep| {
        const h = try ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_VIEW_RT, orep);
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, h);
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

fn http3RequestGetHeaders(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const req = try http3RequestSelf(ctx, self);
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, req.headers_rep);
}

/// `response.new` (headers, option<stream<u8>>, trailers future, retptr) →
/// tuple<response, future<result<_, error-code>>>.
fn http3ResponseNew(caller: *Caller, headers: u32, contents_disc: u32, contents: u32, trailers_fut: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const headers_rep = try ctx.resources.rep(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    (try ctxHttpFields(ctx, headers_rep)).immutable = true;
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_FIELDS_RT, headers);
    const idx: u32 = @intCast(ctx.http_responses.items.len);
    ctx.http_responses.append(ctx.alloc, .{
        .headers_rep = headers_rep,
        .contents_stream = if (contents_disc != 0) contents else null,
        .trailers_future = trailers_fut,
    }) catch return WasiP2Error.OutOfMemory;
    const handle = try ctx.resources.new(WasiP2Ctx.HTTP_RESPONSE_RT, idx);
    const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
    try mem.write(retptr, handle);
    try mem.write(retptr + 4, fut.readable);
}

fn http3ResponseGetStatus(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    return (try http3ResponseSelf(ctx, self)).status;
}

fn http3ResponseSetStatus(caller: *Caller, self: u32, status: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const resp = try http3ResponseSelf(ctx, self);
    // A valid HTTP status code is 100..=599.
    if (status < 100 or status > 599) return 1;
    resp.status = @intCast(status);
    return 0;
}

fn http3ResponseGetHeaders(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const resp = try http3ResponseSelf(ctx, self);
    return ctx.resources.new(WasiP2Ctx.HTTP_FIELDS_VIEW_RT, resp.headers_rep);
}

fn http3ReqoptsNew(caller: *Caller) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const idx: u32 = @intCast(ctx.http_reqopts.items.len);
    ctx.http_reqopts.append(ctx.alloc, .{}) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_RT, idx);
}

/// `option<duration>`: disc u8@0, u64 value@8 (align 8).
fn http3WriteOptDuration(mem: Memory, retptr: u32, v: ?u64) WasiP2Error!void {
    if (v) |ns| {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 8, ns);
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

/// `result<_, request-options-error>`: disc@0; err variant disc@4 (0 =
/// not-supported, 1 = immutable, 2 = other), other's option none@8.
fn http3WriteReqoptsSetResult(mem: Memory, retptr: u32, immutable: bool) WasiP2Error!void {
    if (immutable) {
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, @as(u8, 1));
        try mem.write(retptr + 8, @as(u8, 0));
    } else {
        try mem.write(retptr, @as(u8, 0));
    }
}

fn http3ReqoptsConnectGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    try http3WriteOptDuration(try ctxMemory(caller), retptr, (try http3ReqoptsSelf(ctx, self)).connect_timeout_ns);
}

fn http3ReqoptsConnectSet(caller: *Caller, self: u32, disc: u32, val: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const o = try http3ReqoptsSelf(ctx, self);
    if (!o.immutable) o.connect_timeout_ns = if (disc != 0) @bitCast(val) else null;
    try http3WriteReqoptsSetResult(mem, retptr, o.immutable);
}

fn http3ReqoptsFirstByteGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    try http3WriteOptDuration(try ctxMemory(caller), retptr, (try http3ReqoptsSelf(ctx, self)).first_byte_timeout_ns);
}

fn http3ReqoptsFirstByteSet(caller: *Caller, self: u32, disc: u32, val: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const o = try http3ReqoptsSelf(ctx, self);
    if (!o.immutable) o.first_byte_timeout_ns = if (disc != 0) @bitCast(val) else null;
    try http3WriteReqoptsSetResult(mem, retptr, o.immutable);
}

fn http3ReqoptsBetweenBytesGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    try http3WriteOptDuration(try ctxMemory(caller), retptr, (try http3ReqoptsSelf(ctx, self)).between_bytes_timeout_ns);
}

fn http3ReqoptsBetweenBytesSet(caller: *Caller, self: u32, disc: u32, val: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const o = try http3ReqoptsSelf(ctx, self);
    if (!o.immutable) o.between_bytes_timeout_ns = if (disc != 0) @bitCast(val) else null;
    try http3WriteReqoptsSetResult(mem, retptr, o.immutable);
}

/// `[static]request.consume-body` (this, res future, retptr) →
/// tuple<stream<u8>, future<result<option<trailers>, error-code>>>: hand
/// out the stored body ends. A bodiless request gets an immediately-CLOSED
/// stream (collect → empty) and, when no guest trailers future was
/// transferred (harness-built requests), a host-resolved `ok(none)` one.
/// Consumes `this` (handle slot only — headers/options views stay valid)
/// and releases the guest's error-report future.
fn http3RequestConsumeBody(caller: *Caller, this: u32, res_fut: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const req = try http3RequestSelf(ctx, this);
    const contents = req.contents_stream orelse blk: {
        const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
        // Dropping the writable half closes the stream for the reader.
        try async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, pair.writable);
        break :blk pair.readable;
    };
    const trailers = if (req.trailers_future != 0) req.trailers_future else blk: {
        const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
        try ctx.host_trailer_ok_futures.put(ctx.alloc, fut.readable, {});
        break :blk fut.readable;
    };
    req.contents_stream = null;
    req.trailers_future = 0;
    http3DropTransferredEnd(ctx, res_fut);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQUEST_RT, this);
    try mem.write(retptr, contents);
    try mem.write(retptr + 4, trailers);
}

/// `[static]response.consume-body` — the response-side mirror of the
/// request form: hand out the stored body ends (host-built responses from
/// `client.send` carry `host_body_bytes`-served streams; a bodiless one
/// gets a CLOSED stream and a host-resolved `ok(none)` trailers future).
fn http3ResponseConsumeBody(caller: *Caller, this: u32, res_fut: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const resp = try http3ResponseSelf(ctx, this);
    const contents = resp.contents_stream orelse blk: {
        const pair = try async_mod.newStreamPair(&ctx.streams, &ctx.shared, null);
        try async_mod.dropEndGuarded(&ctx.streams, &ctx.shared, pair.writable);
        break :blk pair.readable;
    };
    const trailers = if (resp.trailers_future != 0) resp.trailers_future else blk: {
        const fut = try async_mod.newFuturePair(&ctx.streams, &ctx.shared, null);
        try ctx.host_trailer_ok_futures.put(ctx.alloc, fut.readable, {});
        break :blk fut.readable;
    };
    resp.contents_stream = null;
    resp.trailers_future = 0;
    http3DropTransferredEnd(ctx, res_fut);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_RESPONSE_RT, this);
    try mem.write(retptr, contents);
    try mem.write(retptr + 4, trailers);
}

/// `[async-lower]wasi:http/client.send` (request, retptr): consumes the
/// request handle and PARKS as a subtask — the request body is a guest
/// stream fed by a guest writer task, so the blocking exchange can only
/// run once the guest closes it (`pollPendingClientSends`). A bodiless
/// request resolves at the first poll (its shared is never written).
fn http3ClientSend(caller: *Caller, request: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const rep = try ctx.resources.rep(WasiP2Ctx.HTTP_REQUEST_RT, request);
    _ = try ctx.resources.drop(WasiP2Ctx.HTTP_REQUEST_RT, request);
    const h = try ctx.streams.add(.{
        .kind = .subtask,
        .side = .readable,
        .elem_type = null,
        .subtask_state = .started,
    });
    const pcs = ctx.alloc.create(PendingClientSend) catch return WasiP2Error.OutOfMemory;
    pcs.* = .{ .req_rep = rep, .retptr = retptr, .subtask = h };
    ctx.pending_client_sends.append(ctx.alloc, pcs) catch {
        ctx.alloc.destroy(pcs);
        return WasiP2Error.OutOfMemory;
    };
    const req = try ctxHttpRequest(ctx, rep);
    if (req.contents_stream) |cs| {
        const end = try ctx.streams.get(cs);
        pcs.body_shared = end.shared;
        try http3RegisterCaptureSink(ctx, end.shared, &pcs.body);
    }
    // Release the request's trailers future (the guest holds the writer and
    // parks it; nothing reads request trailers on the client path) so its
    // writer observes DROPPED. `resources.drop` here bypasses p2ResourceDrop,
    // so the transferred-end release must be explicit.
    http3DropTransferredEnd(ctx, req.trailers_future);
    req.trailers_future = 0;
    return @intFromEnum(async_mod.SubtaskState.started) | (h << 4);
}

fn ctxHttpRequest(ctx: *WasiP2Ctx, rep: u32) WasiP2Error!*p3http.HttpRequest {
    if (rep >= ctx.http_requests.items.len) return WasiP2Error.InvalidHandle;
    return &ctx.http_requests.items[rep];
}

/// Resolve parked `client.send`s whose request body is complete (the body
/// stream's writer dropped — or no body at all): run the blocking HTTP
/// exchange, mint the response resource, marshal the result, and flip the
/// subtask to RETURNED (the timer-fire shape).
pub fn pollPendingClientSends(self: *WasiP2Ctx) WasiP2Error!bool {
    if (self.pending_client_sends.items.len == 0) return false;
    var progressed = false;
    var i: usize = 0;
    while (i < self.pending_client_sends.items.len) {
        const pcs = self.pending_client_sends.items[i];
        const body_done = if (pcs.body_shared) |sid| blk: {
            const sh = self.shared.get(sid) catch break :blk true;
            break :blk switch (sh.*) {
                .stream => |s| s.dropped,
                .future, .subtask => true,
            };
        } else true;
        if (!body_done) {
            i += 1;
            continue;
        }
        try http3PerformSend(self, pcs);
        if (pcs.body_shared) |sid| _ = self.host_capture_sinks.remove(sid);
        pcs.body.deinit(self.alloc);
        self.alloc.destroy(pcs);
        _ = self.pending_client_sends.orderedRemove(i);
        progressed = true;
    }
    return progressed;
}

/// The blocking HTTP exchange for one resolved `client.send`: std.http
/// Client against the request's scheme/authority/path, the response minted
/// as a host-built resource (`host_body_bytes`-served body; trailers via
/// the resolved-ok(none) future at consume-body). result<own<response>,
/// error-code> marshals at retptr with payload offset 8 (error-code
/// carries u64 cases).
fn http3PerformSend(self: *WasiP2Ctx, pcs: *PendingClientSend) WasiP2Error!void {
    const mem = try self.memory();
    const io = try ctxIo(self);
    const req = try ctxHttpRequest(self, pcs.req_rep);
    const fail = struct {
        fn write(m: Memory, retptr: u32, sub: *async_mod.StreamFutureEnd, h: u32) WasiP2Error!void {
            try m.write(retptr, @as(u8, 1));
            // error-code `internal-error(option<string>)` = ordinal 37, none.
            try m.write(retptr + 8, @as(u8, 37));
            try m.write(retptr + 16, @as(u8, 0));
            sub.subtask_state = .returned;
            sub.setPendingEvent(.{ .code = .subtask, .index = h, .payload = @intFromEnum(async_mod.SubtaskState.returned) });
        }
    };
    const sub = try self.streams.get(pcs.subtask);
    const authority = req.authority orelse return fail.write(mem, pcs.retptr, sub, pcs.subtask);
    const path = req.path_with_query orelse "/";
    const url = std.fmt.allocPrint(self.alloc, "http://{s}{s}", .{ authority, path }) catch return WasiP2Error.OutOfMemory;
    defer self.alloc.free(url);
    const uri = std.Uri.parse(url) catch return fail.write(mem, pcs.retptr, sub, pcs.subtask);
    const method: std.http.Method = switch (req.method) {
        .get => .GET,
        .head => .HEAD,
        .post => .POST,
        .put => .PUT,
        .delete => .DELETE,
        .connect => .CONNECT,
        .options => .OPTIONS,
        .trace => .TRACE,
        .patch => .PATCH,
        .other => return fail.write(mem, pcs.retptr, sub, pcs.subtask),
    };
    // Request headers from the fields model; content-length is computed by
    // the std client from the body.
    var extra: std.ArrayList(std.http.Header) = .empty;
    defer extra.deinit(self.alloc);
    if (req.headers_rep < self.http_fields.items.len) {
        for (self.http_fields.items[req.headers_rep].entries.items) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, "content-length")) continue;
            extra.append(self.alloc, .{ .name = p.name, .value = p.value }) catch return WasiP2Error.OutOfMemory;
        }
    }
    var client: std.http.Client = .{ .allocator = self.alloc, .io = io };
    defer client.deinit();
    var hreq = client.request(method, uri, .{ .extra_headers = extra.items }) catch return fail.write(mem, pcs.retptr, sub, pcs.subtask);
    defer hreq.deinit();
    hreq.sendBodyComplete(pcs.body.items) catch return fail.write(mem, pcs.retptr, sub, pcs.subtask);
    var redirect_buf: [2048]u8 = undefined;
    var hresp = hreq.receiveHead(&redirect_buf) catch return fail.write(mem, pcs.retptr, sub, pcs.subtask);

    // Response headers → an immutable fields entry.
    const fields_idx: u32 = @intCast(self.http_fields.items.len);
    self.http_fields.append(self.alloc, .{}) catch return WasiP2Error.OutOfMemory;
    var hit = hresp.head.iterateHeaders();
    while (hit.next()) |hd| {
        self.http_fields.items[fields_idx].appendChecked(self.alloc, hd.name, hd.value) catch continue;
    }
    self.http_fields.items[fields_idx].immutable = true;

    // Response body → a host-served stream.
    var transfer_buf: [4096]u8 = undefined;
    const rdr = hresp.reader(&transfer_buf);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(self.alloc);
    while (true) {
        const chunk = rdr.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return fail.write(mem, pcs.retptr, sub, pcs.subtask),
        };
        body.appendSlice(self.alloc, chunk) catch return WasiP2Error.OutOfMemory;
        rdr.toss(chunk.len);
    }
    var contents: ?u32 = null;
    if (body.items.len > 0) {
        const pair = try async_mod.newStreamPair(&self.streams, &self.shared, null);
        const shared_id = (try self.streams.get(pair.readable)).shared;
        const copy = self.alloc.dupe(u8, body.items) catch return WasiP2Error.OutOfMemory;
        try self.host_body_bytes.put(self.alloc, shared_id, .{ .data = copy });
        contents = pair.readable;
    }
    const resp_idx: u32 = @intCast(self.http_responses.items.len);
    self.http_responses.append(self.alloc, .{
        .status = @intFromEnum(hresp.head.status),
        .headers_rep = fields_idx,
        .contents_stream = contents,
    }) catch return WasiP2Error.OutOfMemory;
    const handle = try self.resources.new(WasiP2Ctx.HTTP_RESPONSE_RT, resp_idx);
    try mem.write(pcs.retptr, @as(u8, 0));
    try mem.write(pcs.retptr + 8, handle);
    // Re-fetch: newStreamPair/http_* appends above may have grown the
    // streams table, dangling the `sub` pointer taken at entry.
    const sub2 = try self.streams.get(pcs.subtask);
    sub2.subtask_state = .returned;
    sub2.setPendingEvent(.{ .code = .subtask, .index = pcs.subtask, .payload = @intFromEnum(async_mod.SubtaskState.returned) });
}

/// Register a harness capture sink for `shared_id`, draining a write that
/// parked before registration (the guest's spawned body writer may run
/// before the harness learns the response's stream id).
pub fn http3RegisterCaptureSink(ctx: *WasiP2Ctx, shared_id: u32, cap: *std.ArrayList(u8)) WasiP2Error!void {
    try ctx.host_capture_sinks.put(ctx.alloc, shared_id, cap);
    const sh = try ctx.shared.get(shared_id);
    const pending = switch (sh.*) {
        .stream => |*st| st.pending orelse return,
        .future, .subtask => return,
    };
    if (pending.side != .writable) return;
    const pw = ctx.pending_writes.get(pending.waitable) orelse return;
    const mem = try ctx.memory();
    const bytes = mem.sliceAt(pw.ptr, pw.count * pw.elem_size) catch return WasiP2Error.OutOfBounds;
    cap.appendSlice(ctx.alloc, bytes) catch return WasiP2Error.OutOfMemory;
    const writer = try ctx.streams.get(pending.waitable);
    writer.state = .idle;
    writer.setPendingEvent(.{ .code = .stream_write, .index = pending.waitable, .payload = (async_mod.ReturnCode{ .completed = @intCast(pw.count) }).encode() });
    switch (sh.*) {
        .stream => |*st| st.pending = null,
        .future, .subtask => {},
    }
    _ = ctx.pending_writes.remove(pending.waitable);
}

fn http3ReqoptsClone(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const src = (try http3ReqoptsSelf(ctx, self)).*;
    const idx: u32 = @intCast(ctx.http_reqopts.items.len);
    ctx.http_reqopts.append(ctx.alloc, .{
        .connect_timeout_ns = src.connect_timeout_ns,
        .first_byte_timeout_ns = src.first_byte_timeout_ns,
        .between_bytes_timeout_ns = src.between_bytes_timeout_ns,
    }) catch return WasiP2Error.OutOfMemory;
    return ctx.resources.new(WasiP2Ctx.HTTP_REQOPTS_RT, idx);
}

fn sock3UdpLocalAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    const addr = sock.localAddress() catch |e| return writeSock3Err(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

fn sock3UdpRemoteAddress(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const sock = try sock3UdpSelf(ctx, self);
    const addr = sock.remoteAddress() catch |e| return writeSock3Err(mem, retptr, 4, e);
    try writeIpSocketAddressResult(mem, retptr, addr);
}

fn sock3UdpFamily(caller: *Caller, self: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const sock = try sock3UdpSelf(ctx, self);
    return @intFromEnum(sock.family);
}

fn sock3UdpHopGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU8(mem, retptr, (try sock3UdpSelf(ctx, self)).opt_hop_limit);
}

fn sock3UdpHopSet(caller: *Caller, self: u32, value: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    if (value == 0 or value > 255) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3UdpSelf(ctx, self)).opt_hop_limit = @intCast(value);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3UdpRcvbufGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3UdpSelf(ctx, self)).opt_rcvbuf);
}

fn sock3UdpRcvbufSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3UdpSelf(ctx, self)).opt_rcvbuf = @min(v, 8 << 20);
    try writeSock3UnitResult(mem, retptr, null);
}

fn sock3UdpSndbufGet(caller: *Caller, self: u32, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    try writeSock3OkU64(mem, retptr, (try sock3UdpSelf(ctx, self)).opt_sndbuf);
}

fn sock3UdpSndbufSet(caller: *Caller, self: u32, value_raw: i64, retptr: u32) WasiP2Error!void {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const v: u64 = @bitCast(value_raw);
    if (v == 0) return writeSock3UnitResult(mem, retptr, error.InvalidArgument);
    (try sock3UdpSelf(ctx, self)).opt_sndbuf = @min(v, 8 << 20);
    try writeSock3UnitResult(mem, retptr, null);
}

/// `[async-lower]ip-name-lookup.resolve-addresses` (name ptr, len, retptr):
/// IP literals parse locally per the WIT; a real resolver is a seam the
/// corpus does not exercise — non-literals resolve only for "localhost".
fn sock3ResolveAddresses(caller: *Caller, name_ptr: u32, name_len: u32, retptr: u32) WasiP2Error!u32 {
    const ctx = caller.data(WasiP2Ctx);
    const mem = try ctxMemory(caller);
    const name = mem.sliceAt(name_ptr, name_len) catch return WasiP2Error.OutOfBounds;
    var addrs: [32]std.Io.net.IpAddress = undefined;
    const n = p2sock.resolveAddresses(try ctxIo(ctx), name, &addrs) catch |e| {
        // ip-name-lookup has its OWN error-code variant (ordinals per its
        // WIT declaration order; `other(option<string>)` = 5, none).
        const code: u8 = switch (e) {
            error.InvalidName => 1,
            error.NameUnresolvable => 2,
            error.TemporaryResolverFailure => 3,
            error.PermanentResolverFailure => 4,
            error.ResolverFailure, error.Canceled => 5,
        };
        try mem.write(retptr, @as(u8, 1));
        try mem.write(retptr + 4, code);
        try mem.write(retptr + 8, @as(u8, 0));
        return SUBTASK_RETURNED;
    };
    // ok: list<ip-address>; ip-address variant = disc u8@0, payload@2
    // (ipv4 4×u8 / ipv6 8×u16-le) → elem size 18 align 2.
    const base = try ctx.reallocGuest(@intCast(n * 18), 2);
    for (addrs[0..n], 0..) |a, i| {
        const elem_ptr = base + @as(u32, @intCast(i * 18));
        switch (a) {
            .ip4 => |v| {
                try mem.write(elem_ptr, @as(u8, 0));
                for (v.bytes, 0..) |b, j| try mem.write(elem_ptr + 2 + @as(u32, @intCast(j)), b);
            },
            .ip6 => |v| {
                try mem.write(elem_ptr, @as(u8, 1));
                for (0..8) |j| {
                    const seg: u16 = (@as(u16, v.bytes[j * 2]) << 8) | v.bytes[j * 2 + 1];
                    try mem.write(elem_ptr + 2 + @as(u32, @intCast(j * 2)), seg);
                }
            },
        }
    }
    try mem.write(retptr, @as(u8, 0));
    try mem.write(retptr + 4, base);
    try mem.write(retptr + 8, @as(u32, @intCast(n)));
    return SUBTASK_RETURNED;
}
