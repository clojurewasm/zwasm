//! WASI snapshot-1 type substrate (Phase 4 / §9.4 / 4.1).
//!
//! Declares the data shapes the `wasi_snapshot_preview1.*` host
//! functions consume / produce — types only, no behaviour. Per
//! ROADMAP §P13 (type up-front), the layouts here are fixed so
//! later tasks (4.3 args / environ / proc_exit, 4.4 fd_*, 4.5
//! path_open / fdstat, 4.6 clock / random / poll) can populate
//! handlers without redesigning the substrate.
//!
//! All numeric types are sized to match WASI's 32-bit Wasm-host
//! convention: `Size`, `Fd`, `Iovec.buf`, `Iovec.buf_len` are
//! u32 (Wasm pointers are 32-bit); `Filesize`, `Timestamp`,
//! `Rights` are u64. `Errno` is u16; `Fdflags` / `Oflags` /
//! `Fstflags` are u16 bit-flags; `Filetype` / `Whence` /
//! `Advice` are u8.
//!
//! Reference shapes (read, never copy):
//! - `~/Documents/OSS/wasi-rs/crates/wasip1/src/lib_generated.rs`
//! - `~/Documents/OSS/wasmtime/crates/wasi-common`
//! Spec source of truth:
//! `WebAssembly/WASI/legacy/preview1/witx/typenames.witx`.
//!
//! Zone 2 (`src/wasi/`) — may import Zone 0 (`util/`) and
//! Zone 1 (`ir/`, `runtime/`, …). MUST NOT import Zone 2-other
//! (`interp/`, `jit*/`) or Zone 3 (`c_api/`, `cli/`).

const std = @import("std");

// ============================================================
// Scalar aliases
// ============================================================

/// 32-bit Wasm-side `size_t` (Wasm pointers are 32-bit).
pub const Size = u32;

/// Number of bytes that fits in a file. WASI uses u64 to
/// support files larger than 4 GiB.
pub const Filesize = u64;

/// Nanoseconds since the Unix epoch (or another monotonic
/// reference, depending on `Clockid`).
pub const Timestamp = u64;

/// File descriptor — small unsigned integer that indexes into
/// the host's fd table. Stdin / stdout / stderr take 0 / 1 / 2;
/// preopens follow.
pub const Fd = u32;

/// Signed seek delta for `fd_seek`.
pub const Filedelta = i64;

/// Cookie used by `fd_readdir` to resume between dirents.
pub const Dircookie = u64;
pub const Dirnamlen = u32;
pub const Inode = u64;
pub const Device = u64;
pub const Linkcount = u64;
pub const Userdata = u64;

// ============================================================
// Errno — 16-bit error code
// ============================================================

/// WASI snapshot-1 errno values. Numeric values match
/// `WebAssembly/WASI/legacy/preview1/witx/typenames.witx` —
/// stable across all snapshot-1 implementations. Tagged
/// `non_exhaustive` because future WASI versions may add
/// codes; switch statements should `else => …` accordingly.
pub const Errno = enum(u16) {
    success = 0,
    @"2big" = 1,
    acces = 2,
    addrinuse = 3,
    addrnotavail = 4,
    afnosupport = 5,
    again = 6,
    already = 7,
    badf = 8,
    badmsg = 9,
    busy = 10,
    canceled = 11,
    child = 12,
    connaborted = 13,
    connrefused = 14,
    connreset = 15,
    deadlk = 16,
    destaddrreq = 17,
    dom = 18,
    dquot = 19,
    exist = 20,
    fault = 21,
    fbig = 22,
    hostunreach = 23,
    idrm = 24,
    ilseq = 25,
    inprogress = 26,
    intr = 27,
    inval = 28,
    io = 29,
    isconn = 30,
    isdir = 31,
    loop = 32,
    mfile = 33,
    mlink = 34,
    msgsize = 35,
    multihop = 36,
    nametoolong = 37,
    netdown = 38,
    netreset = 39,
    netunreach = 40,
    nfile = 41,
    nobufs = 42,
    nodev = 43,
    noent = 44,
    noexec = 45,
    nolck = 46,
    nolink = 47,
    nomem = 48,
    nomsg = 49,
    noprotoopt = 50,
    nospc = 51,
    nosys = 52,
    notconn = 53,
    notdir = 54,
    notempty = 55,
    notrecoverable = 56,
    notsock = 57,
    notsup = 58,
    notty = 59,
    nxio = 60,
    overflow = 61,
    ownerdead = 62,
    perm = 63,
    pipe = 64,
    proto = 65,
    protonosupport = 66,
    prototype = 67,
    range = 68,
    rofs = 69,
    spipe = 70,
    srch = 71,
    stale = 72,
    timedout = 73,
    txtbsy = 74,
    xdev = 75,
    notcapable = 76,
    _,
};

// ============================================================
// Filetype + Whence + Advice + Clockid + PreopenType
// ============================================================

pub const Filetype = enum(u8) {
    unknown = 0,
    block_device = 1,
    character_device = 2,
    directory = 3,
    regular_file = 4,
    socket_dgram = 5,
    socket_stream = 6,
    symbolic_link = 7,
    _,
};

pub const Whence = enum(u8) {
    set = 0,
    cur = 1,
    end = 2,
    _,
};

pub const Advice = enum(u8) {
    normal = 0,
    sequential = 1,
    random = 2,
    willneed = 3,
    dontneed = 4,
    noreuse = 5,
    _,
};

pub const Clockid = enum(u32) {
    realtime = 0,
    monotonic = 1,
    process_cputime_id = 2,
    thread_cputime_id = 3,
    _,
};

pub const PreopenType = enum(u8) {
    dir = 0,
    _,
};

pub const EventType = enum(u8) {
    clock = 0,
    fd_read = 1,
    fd_write = 2,
    _,
};

pub const Signal = enum(u8) {
    none = 0,
    hup = 1,
    int = 2,
    quit = 3,
    ill = 4,
    trap = 5,
    abrt = 6,
    bus = 7,
    fpe = 8,
    kill = 9,
    usr1 = 10,
    segv = 11,
    usr2 = 12,
    pipe = 13,
    alrm = 14,
    term = 15,
    _,
};

// ============================================================
// Bit-flag aliases
// ============================================================

/// File-descriptor flags (`O_APPEND` / `O_NONBLOCK` / etc.).
/// Bit values match the witx `fdflags` flagsdef.
pub const Fdflags = u16;
pub const FDFLAGS_APPEND: Fdflags = 0x0001;
pub const FDFLAGS_DSYNC: Fdflags = 0x0002;
pub const FDFLAGS_NONBLOCK: Fdflags = 0x0004;
pub const FDFLAGS_RSYNC: Fdflags = 0x0008;
pub const FDFLAGS_SYNC: Fdflags = 0x0010;

/// `path_open` open flags.
pub const Oflags = u16;
pub const OFLAGS_CREAT: Oflags = 0x0001;
pub const OFLAGS_DIRECTORY: Oflags = 0x0002;
pub const OFLAGS_EXCL: Oflags = 0x0004;
pub const OFLAGS_TRUNC: Oflags = 0x0008;

/// File-system rights — capability bits granted to a file
/// descriptor at preopen time. The full witx rightsdef has 30+
/// flags; only the load-bearing ones are listed here, more land
/// alongside their consuming syscalls.
pub const Rights = u64;
pub const RIGHTS_FD_READ: Rights = 0x0000000000000002;
pub const RIGHTS_FD_SEEK: Rights = 0x0000000000000004;
pub const RIGHTS_FD_WRITE: Rights = 0x0000000000000040;
pub const RIGHTS_FD_TELL: Rights = 0x0000000000000020;
pub const RIGHTS_PATH_OPEN: Rights = 0x0000000000002000;

/// `fd_filestat_set_times` / `path_filestat_set_times` flags.
pub const Fstflags = u16;
pub const FSTFLAGS_ATIM: Fstflags = 0x0001;
pub const FSTFLAGS_ATIM_NOW: Fstflags = 0x0002;
pub const FSTFLAGS_MTIM: Fstflags = 0x0004;
pub const FSTFLAGS_MTIM_NOW: Fstflags = 0x0008;

/// `path_open` lookup flags.
pub const Lookupflags = u32;
pub const LOOKUPFLAGS_SYMLINK_FOLLOW: Lookupflags = 0x0001;

// ============================================================
// Compound shapes (extern struct — Wasm-memory layout)
// ============================================================

/// `iovec` — a (buf, len) pair the guest passes to `fd_read`.
/// `buf` is a 32-bit Wasm pointer into linear memory. The host
/// dereferences it via `Runtime.memory[buf .. buf + buf_len]`.
pub const Iovec = extern struct {
    buf: u32,
    buf_len: Size,
};

/// `ciovec` — same shape as `Iovec` but const-pointer flavoured
/// for `fd_write`. Distinct type so the host can't accidentally
/// store into a guest's read-only buffer view.
pub const Ciovec = extern struct {
    buf: u32,
    buf_len: Size,
};

/// `fdstat` — what `fd_fdstat_get` writes back. 24 bytes:
/// 1 + 1(pad) + 2(flags) + 4(pad) + 8(rights) + 8(rights inh).
pub const Fdstat = extern struct {
    fs_filetype: Filetype,
    _pad0: u8 = 0,
    fs_flags: Fdflags,
    _pad1: u32 = 0,
    fs_rights_base: Rights,
    fs_rights_inheriting: Rights,
};

/// `filestat` — what `fd_filestat_get` / `path_filestat_get`
/// write back. 64 bytes total.
pub const Filestat = extern struct {
    dev: Device,
    ino: Inode,
    filetype: Filetype,
    _pad: [7]u8 = .{0} ** 7,
    nlink: Linkcount,
    size: Filesize,
    atim: Timestamp,
    mtim: Timestamp,
    ctim: Timestamp,
};

/// `prestat` — `fd_prestat_get` writes this for each preopen
/// fd; tagged on `pr_type` and (for dir) carries the guest-
/// path length. The follow-up `fd_prestat_dir_name` then reads
/// the name itself. Size: 1 + 3 pad + 4 = 8 bytes.
pub const Prestat = extern struct {
    pr_type: PreopenType,
    _pad: [3]u8 = .{0} ** 3,
    pr_name_len: Size,
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "Iovec / Ciovec are 8 bytes (u32 buf + u32 len)" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Iovec));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Ciovec));
}

test "Errno: spec-conformant values for the load-bearing tags" {
    try testing.expectEqual(@as(u16, 0), @intFromEnum(Errno.success));
    try testing.expectEqual(@as(u16, 8), @intFromEnum(Errno.badf));
    try testing.expectEqual(@as(u16, 28), @intFromEnum(Errno.inval));
    try testing.expectEqual(@as(u16, 44), @intFromEnum(Errno.noent));
    try testing.expectEqual(@as(u16, 52), @intFromEnum(Errno.nosys));
    try testing.expectEqual(@as(u16, 54), @intFromEnum(Errno.notdir));
    try testing.expectEqual(@as(u16, 76), @intFromEnum(Errno.notcapable));
}

test "Filetype: spec values" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Filetype.unknown));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Filetype.directory));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(Filetype.regular_file));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(Filetype.symbolic_link));
}

test "Whence: spec values + Clockid: spec values" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Whence.set));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Whence.cur));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Whence.end));
    try testing.expectEqual(@as(u32, 0), @intFromEnum(Clockid.realtime));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(Clockid.monotonic));
}

test "Fdflags / Oflags / Rights: spec bit values" {
    try testing.expectEqual(@as(Fdflags, 0x0001), FDFLAGS_APPEND);
    try testing.expectEqual(@as(Fdflags, 0x0004), FDFLAGS_NONBLOCK);
    try testing.expectEqual(@as(Oflags, 0x0001), OFLAGS_CREAT);
    try testing.expectEqual(@as(Oflags, 0x0008), OFLAGS_TRUNC);
    try testing.expectEqual(@as(Rights, 0x0000000000000002), RIGHTS_FD_READ);
    try testing.expectEqual(@as(Rights, 0x0000000000000040), RIGHTS_FD_WRITE);
}

test "Fdstat: 24-byte layout per witx" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(Fdstat));
    const fs: Fdstat = .{
        .fs_filetype = .regular_file,
        .fs_flags = FDFLAGS_APPEND,
        .fs_rights_base = RIGHTS_FD_READ | RIGHTS_FD_WRITE,
        .fs_rights_inheriting = 0,
    };
    try testing.expectEqual(Filetype.regular_file, fs.fs_filetype);
    try testing.expectEqual(@as(Fdflags, 0x0001), fs.fs_flags);
}

test "Filestat: 64-byte layout per witx" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(Filestat));
}

test "Prestat: 8-byte tag + name-len shape" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Prestat));
    const ps: Prestat = .{ .pr_type = .dir, .pr_name_len = 5 };
    try testing.expectEqual(@as(Size, 5), ps.pr_name_len);
}

test "Scalar aliases: width matches WASI 32-bit Wasm convention" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(Size));
    try testing.expectEqual(@as(usize, 4), @sizeOf(Fd));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Filesize));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Timestamp));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Rights));
}
