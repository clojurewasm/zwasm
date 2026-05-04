//! Error diagnostic system (ADR-0016 phase 1).
//!
//! `Diagnostic.Info` carries the structured side-channel that
//! sits beside zwasm's Zig error sets — the error union still
//! drives control flow on the hot path (per ROADMAP §A12 and
//! Phase 7 JIT readiness), and rich context (kind / phase /
//! location / message) lives in a threadlocal slot written
//! only on the cold trap path.
//!
//! Phase 1 ships:
//!   * `Kind` enum (initial tag set covering the six runWasm-
//!     boundary error tags + the 12 spec-text trap kinds
//!     already in `c_api/trap_surface.zig:TrapKind`).
//!   * `Phase` enum (parse / validate / instantiate / execute
//!     / wasi, plus `unknown`).
//!   * `Location` tagged union (only the `unknown` variant in
//!     phase 1; M2/M3 add `parse` / `validate` / `execute`
//!     variants additively).
//!   * `Info` struct with an inline 512-byte message buffer —
//!     `setDiag` doesn't allocate on the cold path.
//!   * `setDiag` / `clearDiag` / `lastDiagnostic` API.
//!   * Threadlocal `last_diag` slot.
//!
//! Out of phase 1: typed helpers (`requireValidLocalIdx` etc.,
//! M2), full `Location` variants (M2/M3), C-ABI accessor family
//! (M4, drops the parallel `c_api.TrapKind`), backtraces (M5).
//!
//! ## libc / TLS dependency
//!
//! Zig 0.16's `threadlocal var` lowers to platform TLS
//! (`__thread` on Linux glibc / Mac aarch64 darwin;
//! `_Thread_local` on Windows ucrt). All three target hosts
//! have libc-supported TLS, so this module is callable from
//! every libc-linked compilation unit. A future no-libc
//! embedded build (none today) would need either a Zig stdlib
//! no-libc TLS path or a compile-mode shim. This is the same
//! constraint ADR-0015 documents for `util/dbg.zig`'s
//! `std.c.getenv`; one TODO at `dbg.zig:69` covers the family.
//!
//! Zone 1 (`src/runtime/`) — may import Zone 0 only.

const std = @import("std");

/// Initial tag set. Numbering is **draft** in phase 1; M4 locks
/// the values when the C-ABI accessor family ships, after which
/// adding a tag is append-only. Phase 1 callers should reference
/// tags by name, never by integer.
pub const Kind = enum(u32) {
    // Boundary tags (the six errors `runWasm` returns to its caller
    // — phase 1 wires `setDiag` immediately before each return).
    engine_alloc_failed = 0,
    store_alloc_failed = 1,
    config_alloc_failed = 2,
    module_alloc_failed = 3,
    instance_alloc_failed = 4,
    no_func_export = 5,

    // 11 spec-text trap kinds (mirror `c_api/trap_surface.zig:TrapKind`).
    // M4 drops the duplicate and aliases this side as the source of
    // truth.
    binding_error = 100,
    unreachable_ = 101,
    div_by_zero = 102,
    int_overflow = 103,
    invalid_conversion = 104,
    oob_memory = 105,
    oob_table = 106,
    uninitialized_elem = 107,
    indirect_call_mismatch = 108,
    stack_overflow = 109,
    out_of_memory = 110,

    // Catch-all for unwired sites that haven't been classified
    // yet. `renderFallback` in `cli/diag_print.zig` is the
    // intended path for these — but if a `setDiag` call site
    // can't decide, this tag is preferred over silence.
    other = 999,
};

/// Phase axis. `unknown` is the default for diagnostics that
/// haven't been classified — the renderer treats it as fallback.
pub const Phase = enum(u32) {
    unknown = 0,
    parse = 1,
    validate = 2,
    instantiate = 3,
    execute = 4,
    wasi = 5,
};

/// Location is a tagged union — phase 1 ships only `unknown`.
/// M2 adds `parse: { byte_offset }`, M3 adds
/// `validate: { fn_idx, body_offset, opcode }` and
/// `execute: { fn_idx, pc, ea, mem_size }`. The renderer
/// switches on `phase` first and only reads `location` for the
/// variants it knows; new variants land additively without
/// breaking phase-1 callers.
pub const Location = union(enum) {
    unknown,
};

/// Inline message buffer size — matches v1 c_api `ERROR_BUF_SIZE`
/// and ClojureWasm v2's `error.zig`. The cap is soft; v1's
/// longest message strings sit well under 200 bytes.
pub const message_buf_size: usize = 512;

/// Structured diagnostic payload. `setDiag` populates this; the
/// CLI / runner / C-API binding consumes via `lastDiagnostic`.
pub const Info = struct {
    kind: Kind,
    phase: Phase,
    location: Location,
    /// `[0..message_len]` is the formatted message. Truncated
    /// silently if `setDiag`'s formatter overflows. The full
    /// `message_buf_size` is reserved as inline storage so the
    /// cold path doesn't allocate.
    message_buf: [message_buf_size]u8,
    message_len: usize,

    /// Borrow the formatted message as a slice.
    pub fn message(self: *const Info) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

/// Per-thread diagnostic slot. Single-threaded today per
/// ROADMAP §7; if a future Phase 7+ Store gains a per-Store-
/// pointer slot, this moves there.
threadlocal var last_diag: ?Info = null;

/// Populate the threadlocal diagnostic. The caller follows
/// immediately with `return error.X`. Call site is cold:
/// the format-string evaluation runs only on the trap path.
///
/// `@branchHint(.cold)` is advisory — LLVM may ignore it in
/// `Debug` / `ReleaseSafe` builds. The function is named to
/// help readers (and grep) identify cold-path emit sites.
pub fn setDiag(
    phase: Phase,
    kind: Kind,
    location: Location,
    comptime fmt: []const u8,
    args: anytype,
) void {
    @branchHint(.cold);
    var info: Info = .{
        .kind = kind,
        .phase = phase,
        .location = location,
        .message_buf = undefined,
        .message_len = 0,
    };
    const written = std.fmt.bufPrint(&info.message_buf, fmt, args) catch blk: {
        // Silent truncation per ADR — write what fit, leave the
        // rest. The buffer's full capacity has been written; we
        // just cap message_len at the buffer size.
        break :blk info.message_buf[0..info.message_buf.len];
    };
    info.message_len = written.len;
    last_diag = info;
}

/// Clear the threadlocal slot. Binding entry points call this
/// at start so a stale diagnostic doesn't leak across calls.
pub fn clearDiag() void {
    last_diag = null;
}

/// Read the most recent diagnostic, if any. Returned pointer is
/// valid until the next `setDiag` / `clearDiag` on this thread.
pub fn lastDiagnostic() ?*const Info {
    if (last_diag) |*d| return d;
    return null;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "diagnostic: clear → lastDiagnostic returns null" {
    clearDiag();
    try testing.expect(lastDiagnostic() == null);
}

test "diagnostic: setDiag populates slot, lastDiagnostic returns it" {
    clearDiag();
    setDiag(.instantiate, .module_alloc_failed, .unknown, "module decode failed at byte {d}", .{42});
    const d = lastDiagnostic().?;
    try testing.expectEqual(Phase.instantiate, d.phase);
    try testing.expectEqual(Kind.module_alloc_failed, d.kind);
    try testing.expect(std.mem.eql(u8, d.message(), "module decode failed at byte 42"));
}

test "diagnostic: setDiag overwrites the previous slot" {
    clearDiag();
    setDiag(.parse, .other, .unknown, "first", .{});
    setDiag(.execute, .oob_memory, .unknown, "second {d}", .{99});
    const d = lastDiagnostic().?;
    try testing.expectEqual(Phase.execute, d.phase);
    try testing.expectEqual(Kind.oob_memory, d.kind);
    try testing.expect(std.mem.eql(u8, d.message(), "second 99"));
}

test "diagnostic: oversize message is silently truncated" {
    clearDiag();
    // 600-byte message exceeds the 512-byte buffer.
    var pad: [600]u8 = undefined;
    @memset(&pad, 'x');
    setDiag(.unknown, .other, .unknown, "{s}", .{&pad});
    const d = lastDiagnostic().?;
    try testing.expectEqual(@as(usize, message_buf_size), d.message_len);
    try testing.expectEqual(@as(u8, 'x'), d.message()[0]);
    try testing.expectEqual(@as(u8, 'x'), d.message()[message_buf_size - 1]);
}

test "diagnostic: clearDiag after setDiag returns null" {
    clearDiag();
    setDiag(.wasi, .other, .unknown, "wasi error", .{});
    try testing.expect(lastDiagnostic() != null);
    clearDiag();
    try testing.expect(lastDiagnostic() == null);
}
