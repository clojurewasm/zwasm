//! WASI Preview 2 `wasi:sockets` host backing (ADR-0180 Phase 1).
//!
//! The TCP-client subset's OS-facing half: a `TcpSocket` state machine
//! (`wasi:sockets/tcp` documented transitions: unbound → bind-in-progress →
//! bound → connect-in-progress → connected) over `std.Io.net` (the pinned
//! Zig 0.16 stdlib has NO raw `std.posix` socket surface — networking is
//! io-based, the same discipline the WASI fs host already follows via
//! `host.io`). The component trampolines (impl-2) lower WIT records onto
//! this surface; nothing here touches guest memory.
//!
//! DIVERGENCE from the wasmtime shape (noted in ADR-0180): `std.Io.net`'s
//! `connect` is synchronous, so the OS connect executes inside
//! `start-connect` and `finish-connect` returns the cached result — the
//! guest-observable contract (validate at start; establishment failures
//! surface at finish) is preserved without an async runtime. Readiness for
//! the poll(2)-honest pollables still comes from `posix.poll` on the
//! socket handle (`ready`).
//!
//! Phase-2 DIVERGENCE (same root cause): the pinned stdlib has no
//! separate bind/listen steps for stream sockets (`netListenIp` is
//! socket+bind+listen atomically; `IpAddress.bind` is the DATAGRAM path),
//! so `start-bind` only validates + stores the address and the OS bind
//! executes inside `start-listen`. Consequences, both truthful:
//! bind-level failures (address-in-use, ...) surface at `finish-listen`
//! instead of `finish-bind`, and `local-address` of a `bound`-but-not-
//! listening socket reports the REQUESTED port (an ephemeral `:0` stays 0
//! until listen resolves it). A connected client's local-address is
//! `not-supported` (no getsockname in the pinned stdlib).
//!
//! Zone 2 (`src/wasi/`). `std.Io.net` + `std.posix.poll` only — no new
//! libc surface (`libc_boundary`).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.Io.net;

/// `wasi:sockets/network` `error-code` — spec-pinned ordinals 0–20
/// (sockets.wit `enum error-code` declaration order).
pub const ErrorCode = enum(u8) {
    unknown = 0,
    access_denied = 1,
    not_supported = 2,
    invalid_argument = 3,
    out_of_memory = 4,
    timeout = 5,
    concurrency_conflict = 6,
    not_in_progress = 7,
    would_block = 8,
    invalid_state = 9,
    new_socket_limit = 10,
    address_not_bindable = 11,
    address_in_use = 12,
    remote_unreachable = 13,
    connection_refused = 14,
    connection_reset = 15,
    connection_aborted = 16,
    datagram_too_large = 17,
    name_unresolvable = 18,
    temporary_resolver_failure = 19,
    permanent_resolver_failure = 20,
};

/// `wasi:sockets/network` `ip-address-family` (enum: ipv4, ipv6).
pub const AddressFamily = enum(u8) { ipv4 = 0, ipv6 = 1 };

/// Map a Zig networking error onto the spec `error-code`. Errors with no
/// spec counterpart fall back to `unknown` (the spec's catch-all).
pub fn errorToCode(err: anyerror) ErrorCode {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.AddressFamilyUnsupported, error.ProtocolUnsupportedByAddressFamily, error.ProtocolUnsupportedBySystem, error.SocketModeUnsupported, error.OptionUnsupported => .not_supported,
        error.InvalidArgument, error.AddressUnavailable => .invalid_argument,
        error.SystemResources, error.OutOfMemory => .out_of_memory,
        error.ConnectionTimedOut, error.Timeout => .timeout,
        error.WouldBlock => .would_block,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .new_socket_limit,
        error.AddressInUse => .address_in_use,
        error.NetworkUnreachable, error.NetworkDown, error.HostUnreachable => .remote_unreachable,
        error.ConnectionRefused => .connection_refused,
        error.ConnectionResetByPeer => .connection_reset,
        error.ConnectionAborted => .connection_aborted,
        error.MessageTooBig => .datagram_too_large,
        else => .unknown,
    };
}

/// poll(2) interest bits, comptime-gated: `std.posix.POLL` is absent on
/// Windows. The windows values are LOCAL tags only — `afdPollOnce` maps
/// them onto AFD_POLL_* event masks (winsock is unusable on the pinned
/// stdlib's raw NT/AFD socket handles; see the AFD section below).
pub const POLL_IN: i16 = switch (builtin.os.tag) {
    .windows => 0x0001,
    else => posix.POLL.IN,
};
pub const POLL_OUT: i16 = switch (builtin.os.tag) {
    .windows => 0x0004,
    else => posix.POLL.OUT,
};

/// `wasi:sockets/tcp` documented state machine.
pub const TcpState = enum { unbound, bind_started, bound, connect_started, connected, listen_started, listening, closed };

/// One live TCP socket: spec state + the `std.Io.net` objects backing it.
/// The OS socket is created lazily by connect/listen (`std.Io.net` has no
/// bare-socket constructor; wasmtime is lazy the same way). The component
/// layer owns the resource handle; this struct owns the OS handle(s).
pub const TcpSocket = struct {
    family: AddressFamily,
    state: TcpState = .unbound,
    /// Stored by start-bind; the OS bind executes inside start-listen
    /// (see the Phase-2 DIVERGENCE note in the module docstring).
    bound_addr: ?net.IpAddress = null,
    /// Set once the connect succeeded (start-connect path).
    stream: ?net.Stream = null,
    /// Set once the listen succeeded (start-listen path).
    server: ?net.Server = null,
    /// Establishment failure cached by start-connect, surfaced by
    /// finish-connect (the spec's two-phase contract).
    connect_err: ?anyerror = null,
    /// Bind/listen failure cached by start-listen, surfaced by finish-listen.
    listen_err: ?anyerror = null,
    /// `set-listen-backlog-size` before listen; applied at the OS listen.
    backlog: ?u31 = null,

    /// `tcp-create-socket.create-tcp-socket` — records the family; the OS
    /// socket is created by the first connect/listen.
    pub fn create(family: AddressFamily) TcpSocket {
        return .{ .family = family };
    }

    pub fn deinit(self: *TcpSocket, io: std.Io) void {
        if (self.stream) |s| s.close(io);
        if (self.server) |*s| s.deinit(io);
        self.stream = null;
        self.server = null;
        self.state = .closed;
    }

    /// `tcp.start-bind`. Validates + stores the address; the OS bind is
    /// deferred to start-listen (Phase-2 DIVERGENCE, module docstring).
    pub fn startBind(self: *TcpSocket, io: std.Io, addr: net.IpAddress) !void {
        _ = io;
        if (self.state != .unbound) return error.InvalidState;
        if (!familyMatches(self.family, addr)) return error.InvalidArgument;
        self.bound_addr = addr;
        self.state = .bind_started;
    }

    /// `tcp.finish-bind`.
    pub fn finishBind(self: *TcpSocket) !void {
        if (self.state != .bind_started) return error.NotInProgress;
        self.state = .bound;
    }

    /// `tcp.start-listen`. The OS socket+bind+listen executes here
    /// (`netListenIp` is atomic in the pinned stdlib); failures are cached
    /// for finish-listen (the spec's two-phase contract).
    pub fn startListen(self: *TcpSocket, io: std.Io) !void {
        if (self.state != .bound) return error.InvalidState;
        const addr = self.bound_addr.?; // .bound implies a stored address
        self.state = .listen_started;
        var opts: net.IpAddress.ListenOptions = .{ .mode = .stream, .protocol = .tcp };
        if (self.backlog) |b| opts.kernel_backlog = b;
        self.server = addr.listen(io, opts) catch |err| {
            self.listen_err = err;
            return;
        };
    }

    /// `tcp.finish-listen` — the cached start-listen result.
    pub fn finishListen(self: *TcpSocket) !void {
        if (self.state != .listen_started) return error.NotInProgress;
        if (self.listen_err) |err| {
            self.state = .closed;
            return err;
        }
        self.state = .listening;
    }

    /// `tcp.set-listen-backlog-size` — stored and applied at the OS listen.
    /// Updating a LIVE listener is optional per spec; truthful not-supported.
    pub fn setListenBacklog(self: *TcpSocket, value: u64) !void {
        if (value == 0) return error.InvalidArgument;
        switch (self.state) {
            .listen_started, .listening => return error.OptionUnsupported,
            .closed => return error.InvalidState,
            .unbound, .bind_started, .bound, .connect_started, .connected => {},
        }
        self.backlog = std.math.cast(u31, value) orelse std.math.maxInt(u31);
    }

    /// `tcp.accept` — non-blocking: `would-block` unless poll(2) reports a
    /// queued connection. On success mints the accepted socket as a fresh
    /// `connected` TcpSocket (the component layer registers the resource
    /// and pairs the streams, same as finish-connect).
    pub fn accept(self: *TcpSocket, io: std.Io) !TcpSocket {
        if (self.state != .listening) return error.InvalidState;
        const srv = &self.server.?;
        if (!try pollOnce(srv.socket.handle, POLL_IN)) return error.WouldBlock;
        const stream = try srv.accept(io);
        return .{ .family = self.family, .state = .connected, .stream = stream };
    }

    /// `tcp.remote-address`. The peer address of a connected socket: an
    /// accepted connection carries the peer sockaddr from the OS accept;
    /// a client carries the address it connected to.
    pub fn remoteAddress(self: *TcpSocket) !net.IpAddress {
        const stream = self.connectedStream() orelse return error.InvalidState;
        return stream.socket.address;
    }

    /// `tcp.local-address`. Listening sockets report the RESOLVED address
    /// (ephemeral `:0` becomes the real port); `bound` reports the stored
    /// request; connected clients are not-supported (no getsockname in the
    /// pinned stdlib — module docstring).
    pub fn localAddress(self: *TcpSocket) !net.IpAddress {
        return switch (self.state) {
            .listening => self.server.?.socket.address,
            .bound => self.bound_addr.?,
            .connected => error.OptionUnsupported,
            .unbound, .bind_started, .connect_started, .listen_started, .closed => error.InvalidState,
        };
    }

    /// `tcp.start-connect`. The synchronous `std.Io.net` connect executes
    /// here; a failure is cached for finish-connect (see module docstring).
    /// Connecting FROM an explicitly bound socket is Phase-2 scope
    /// (`std.Io.net` has no bound-socket connect) — truthful not-supported.
    pub fn startConnect(self: *TcpSocket, io: std.Io, addr: net.IpAddress) !void {
        if (self.state == .bound or self.state == .bind_started) return error.OptionUnsupported;
        if (self.state != .unbound) return error.InvalidState;
        if (!familyMatches(self.family, addr)) return error.InvalidArgument;
        self.state = .connect_started;
        self.stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
            self.connect_err = err;
            return;
        };
    }

    /// `tcp.finish-connect` — the cached start-connect result.
    pub fn finishConnect(self: *TcpSocket) !void {
        if (self.state != .connect_started) return error.NotInProgress;
        if (self.connect_err) |err| {
            self.state = .closed;
            return err;
        }
        self.state = .connected;
    }

    /// Socket-backed input-stream `read` (one-shot; blocks under the
    /// Threaded io until data arrives — the `blocking-read` contract; the
    /// non-blocking `read` trampoline gates on `ready` first).
    pub fn recv(self: *TcpSocket, io: std.Io, buf: []u8) !usize {
        const stream = self.connectedStream() orelse return error.InvalidState;
        var bufs = [_][]u8{buf};
        return io.vtable.netRead(io.userdata, stream.socket.handle, &bufs);
    }

    /// Socket-backed output-stream `write` (one-shot).
    pub fn send(self: *TcpSocket, io: std.Io, bytes: []const u8) !usize {
        const stream = self.connectedStream() orelse return error.InvalidState;
        const data = [_][]const u8{bytes};
        return io.vtable.netWrite(io.userdata, stream.socket.handle, "", &data, 1);
    }

    /// Readiness for the poll(2)-honest pollable (ADR-0180): is the
    /// connected socket ready for `interest` (POLL.IN / POLL.OUT) now?
    /// A listening socket's POLL.IN = "a connection is queued for accept".
    pub fn ready(self: *TcpSocket, interest: i16) !bool {
        if (self.state == .listening) return pollOnce(self.server.?.socket.handle, interest);
        const stream = self.connectedStream() orelse return error.InvalidState;
        return pollOnce(stream.socket.handle, interest);
    }

    /// `tcp.shutdown(shutdown-type)` — half/full-close a connected socket.
    pub fn shutdown(self: *TcpSocket, io: std.Io, how: net.ShutdownHow) !void {
        const stream = self.connectedStream() orelse return error.InvalidState;
        try stream.shutdown(io, how);
    }

    fn connectedStream(self: *TcpSocket) ?net.Stream {
        if (self.state != .connected) return null;
        return self.stream;
    }
};

fn familyMatches(family: AddressFamily, addr: net.IpAddress) bool {
    return switch (addr) {
        .ip4 => family == .ipv4,
        .ip6 => family == .ipv6,
    };
}

/// One zero-timeout poll(2) on a single socket handle: true iff `interest`
/// (or an error/hup condition, which also unblocks a waiter) is pending.
fn pollOnce(handle: net.Socket.Handle, interest: i16) !bool {
    switch (builtin.os.tag) {
        .windows => return afdPollOnce(handle, interest),
        else => {
            var fds = [_]posix.pollfd{.{ .fd = handle, .events = interest, .revents = 0 }};
            const n = try posix.poll(&fds, 0);
            return n > 0 and (fds[0].revents & (interest | posix.POLL.ERR | posix.POLL.HUP)) != 0;
        },
    }
}

// ---- Windows readiness: IOCTL_AFD_POLL (D-319 probes #3/#4) ----
//
// The pinned `std.Io.net` windows backend drives sockets as raw NT/AFD
// handles: winsock is never initialized AND the handles are not
// winsock-registered SOCKETs (WSAPoll fails WSAENOTSOCK even after
// WSAStartup). Readiness therefore uses the NT-native AFD poll ioctl on
// the socket handle itself — the wepoll/libuv/mio approach — with a
// zero timeout (snapshot semantics: STATUS_TIMEOUT/0 handles = not
// ready).

const win = std.os.windows;

const AFD_POLL_RECEIVE: u32 = 0x0001;
const AFD_POLL_SEND: u32 = 0x0004;
const AFD_POLL_DISCONNECT: u32 = 0x0008;
const AFD_POLL_ABORT: u32 = 0x0010;
const AFD_POLL_ACCEPT: u32 = 0x0080;
const AFD_POLL_CONNECT_FAIL: u32 = 0x0100;

const AfdPollHandleInfo = extern struct {
    handle: win.HANDLE,
    events: u32,
    status: win.NTSTATUS,
};

const AfdPollInfo = extern struct {
    timeout: i64,
    number_of_handles: u32,
    exclusive: u32,
    handles: [1]AfdPollHandleInfo,
};

/// IOCTL_AFD_POLL (0x00012024).
const AFD_POLL_CTL: win.CTL_CODE = @bitCast(@as(u32, 0x00012024));

fn afdPollOnce(handle: net.Socket.Handle, interest: i16) !bool {
    if (builtin.os.tag != .windows) unreachable;
    const want: u32 = blk: {
        var w: u32 = 0;
        if (interest & POLL_IN != 0) w |= AFD_POLL_RECEIVE | AFD_POLL_DISCONNECT | AFD_POLL_ABORT | AFD_POLL_ACCEPT | AFD_POLL_CONNECT_FAIL;
        if (interest & POLL_OUT != 0) w |= AFD_POLL_SEND;
        break :blk w;
    };
    var info: AfdPollInfo = .{
        .timeout = 0, // snapshot: expire immediately when nothing is ready
        .number_of_handles = 1,
        .exclusive = 0,
        .handles = .{.{ .handle = handle, .events = want, .status = .SUCCESS }},
    };
    var iosb: win.IO_STATUS_BLOCK = undefined;
    const status = win.ntdll.NtDeviceIoControlFile(
        handle,
        null,
        null,
        null,
        &iosb,
        AFD_POLL_CTL,
        &info,
        @sizeOf(AfdPollInfo),
        &info,
        @sizeOf(AfdPollInfo),
    );
    switch (status) {
        .SUCCESS => {},
        .TIMEOUT => return false, // nothing ready within the zero timeout
        else => {
            // D-319 probe diagnostic: name the NTSTATUS on failure.
            std.log.scoped(.zwasm_sockets).warn("IOCTL_AFD_POLL failed: NTSTATUS=0x{x} (handle=0x{x}, want=0x{x})", .{ @intFromEnum(status), @intFromPtr(handle), want });
            return error.Unexpected;
        },
    }
    if (info.number_of_handles == 0) return false;
    return (info.handles[0].events & want) != 0;
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "tcp client lifecycle: create → connect → echo against a loopback listener" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // In-test loopback listener on an ephemeral port (the impl-3 e2e host
    // echo server's seed).
    const listen_addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
    var server = try listen_addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var client = TcpSocket.create(.ipv4);
    defer client.deinit(io);
    try client.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(port) });
    try client.finishConnect();
    try testing.expectEqual(TcpState.connected, client.state);

    var conn = try server.accept(io);
    defer conn.close(io);

    // client → server
    try testing.expectEqual(@as(usize, 4), try client.send(io, "ping"));
    var srv_buf: [16]u8 = undefined;
    var srv_bufs = [_][]u8{&srv_buf};
    const got = try io.vtable.netRead(io.userdata, conn.socket.handle, &srv_bufs);
    try testing.expectEqualStrings("ping", srv_buf[0..got]);

    // server → client; readiness flips the client's POLL.IN pollable.
    const reply = [_][]const u8{"pong"};
    _ = try io.vtable.netWrite(io.userdata, conn.socket.handle, "", &reply, 1);
    var attempts: u32 = 0;
    while (!(try client.ready(POLL_IN)) and attempts < 500) : (attempts += 1) {
        try io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    try testing.expect(try client.ready(POLL_IN));
    var cli_buf: [16]u8 = undefined;
    const echoed = try client.recv(io, &cli_buf);
    try testing.expectEqualStrings("pong", cli_buf[0..echoed]);
}

test "tcp state machine: invalid transitions are rejected" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sock = TcpSocket.create(.ipv4);
    defer sock.deinit(io);
    // finish before start → not-in-progress.
    try testing.expectError(error.NotInProgress, sock.finishBind());
    try testing.expectError(error.NotInProgress, sock.finishConnect());
    // recv/send/ready before connected → invalid-state.
    var buf: [4]u8 = undefined;
    try testing.expectError(error.InvalidState, sock.recv(io, &buf));
    try testing.expectError(error.InvalidState, sock.send(io, "x"));
    try testing.expectError(error.InvalidState, sock.ready(POLL_IN));
    // family mismatch → invalid-argument.
    try testing.expectError(error.InvalidArgument, sock.startConnect(io, .{ .ip6 = net.Ip6Address.loopback(1) }));
    // bind twice → invalid-state on the second start-bind.
    try sock.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try testing.expectError(error.InvalidState, sock.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) }));
    try sock.finishBind();
    try testing.expectEqual(TcpState.bound, sock.state);
    // bound → connect is Phase-2 scope (std.Io.net has no bound connect).
    try testing.expectError(error.OptionUnsupported, sock.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(1) }));
}

test "tcp connect to a closed port surfaces connection-refused at finish-connect" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Grab an ephemeral port, then close the listener so nothing accepts.
    const listen_addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(0) };
    var server = try listen_addr.listen(io, .{ .mode = .stream, .protocol = .tcp });
    const port = server.socket.address.getPort();
    server.deinit(io);

    var sock = TcpSocket.create(.ipv4);
    defer sock.deinit(io);
    try sock.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(port) });
    if (builtin.os.tag == .windows) {
        // D-323: the pinned stdlib's windows netConnect surfaces NTSTATUS
        // 0xC0000236 (CONNECTION_REFUSED) as error.Unexpected (unmapped
        // status) — the guest sees error-code `unknown` instead of
        // `connection-refused` until the stdlib maps it.
        try testing.expectError(error.Unexpected, sock.finishConnect());
    } else {
        try testing.expectError(error.ConnectionRefused, sock.finishConnect());
    }
    try testing.expectEqual(ErrorCode.connection_refused, errorToCode(error.ConnectionRefused));
}

test "tcp listener lifecycle: bind → listen → accept → echo (ADR-0180 Phase 2)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = TcpSocket.create(.ipv4);
    defer listener.deinit(io);
    try listener.setListenBacklog(8);
    try listener.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try listener.finishBind();
    // bound (pre-listen): local-address reports the REQUESTED port (0 —
    // the deferred-bind DIVERGENCE; resolution happens at listen).
    try testing.expectEqual(@as(u16, 0), (try listener.localAddress()).getPort());
    try listener.startListen(io);
    try listener.finishListen();
    try testing.expectEqual(TcpState.listening, listener.state);

    // listening: local-address now carries the RESOLVED ephemeral port.
    const local = try listener.localAddress();
    const port = local.getPort();
    try testing.expect(port != 0);

    // No queued connection yet → accept is would-block, readiness false.
    try testing.expect(!(try listener.ready(POLL_IN)));
    try testing.expectError(error.WouldBlock, listener.accept(io));

    // A client connects (kernel backlog completes the handshake).
    var client = TcpSocket.create(.ipv4);
    defer client.deinit(io);
    try client.startConnect(io, .{ .ip4 = net.Ip4Address.loopback(port) });
    try client.finishConnect();

    var attempts: u32 = 0;
    while (!(try listener.ready(POLL_IN)) and attempts < 500) : (attempts += 1) {
        try io.sleep(.{ .nanoseconds = 2 * std.time.ns_per_ms }, .awake);
    }
    var accepted = try listener.accept(io);
    defer accepted.deinit(io);
    try testing.expectEqual(TcpState.connected, accepted.state);

    // Echo through the accepted socket: client → accepted → client.
    try testing.expectEqual(@as(usize, 4), try client.send(io, "ping"));
    var srv_buf: [16]u8 = undefined;
    const got = try accepted.recv(io, &srv_buf);
    try testing.expectEqualStrings("ping", srv_buf[0..got]);
    try testing.expectEqual(@as(usize, 4), try accepted.send(io, "pong"));
    var cli_buf: [16]u8 = undefined;
    const echoed = try client.recv(io, &cli_buf);
    try testing.expectEqualStrings("pong", cli_buf[0..echoed]);
}

test "tcp listener state machine: invalid transitions are rejected" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sock = TcpSocket.create(.ipv4);
    defer sock.deinit(io);
    // listen before bound / finish before start / accept before listening.
    try testing.expectError(error.InvalidState, sock.startListen(io));
    try testing.expectError(error.NotInProgress, sock.finishListen());
    try testing.expectError(error.InvalidState, sock.accept(io));
    try testing.expectError(error.InvalidState, sock.localAddress());
    // backlog 0 is invalid-argument per spec.
    try testing.expectError(error.InvalidArgument, sock.setListenBacklog(0));

    try sock.startBind(io, .{ .ip4 = net.Ip4Address.loopback(0) });
    try sock.finishBind();
    try sock.startListen(io);
    try sock.finishListen();
    // live listener: backlog update is truthful not-supported.
    try testing.expectError(error.OptionUnsupported, sock.setListenBacklog(4));
    // connected-client local-address: not-supported (no getsockname).
    var client = TcpSocket.create(.ipv4);
    defer client.deinit(io);
    try client.startConnect(io, .{ .ip4 = net.Ip4Address.loopback((try sock.localAddress()).getPort()) });
    try client.finishConnect();
    try testing.expectError(error.OptionUnsupported, client.localAddress());
}

test "errorToCode: spec ordinals pinned" {
    try testing.expectEqual(@as(u8, 8), @intFromEnum(ErrorCode.would_block));
    try testing.expectEqual(@as(u8, 9), @intFromEnum(ErrorCode.invalid_state));
    try testing.expectEqual(@as(u8, 12), @intFromEnum(errorToCode(error.AddressInUse)));
    try testing.expectEqual(@as(u8, 14), @intFromEnum(errorToCode(error.ConnectionRefused)));
    try testing.expectEqual(@as(u8, 20), @intFromEnum(ErrorCode.permanent_resolver_failure));
    try testing.expectEqual(ErrorCode.unknown, errorToCode(error.Unexpected));
}
