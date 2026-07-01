//! x86_64 cross-module import bridge thunk encoder
//! (ADR-0066 + Amendment §A1, D-142
//! fix (A.3) + D-238/ADR-0185 (a) RBP frame-link).
//!
//! Each thunk is a 40-byte native code snippet that wraps a
//! call-and-return around the callee's JIT entry. It does three
//! things: **(1)** establishes a standard `PUSH RBP; MOV RBP,RSP`
//! frame so the cross-instance EH unwinder can walk THROUGH the
//! thunk (D-238 — `[RBP,0]`=saved importer RBP, `[RBP,8]`=importer
//! return address, making the thunk frame a chain link); **(2)**
//! **saves the caller's R15** (`runtime_ptr_save_gpr` per ADR-0026
//! Cc-pivot) across the CALL so the importer's runtime-ptr survives
//! the callee's prologue overwrite (the D-142 cohort discipline);
//! **(3)** keeps `CALL RAX` 16-byte aligned via an explicit pad.
//! Mirrors the arm64 `MOV X29,SP` thunk frame-link (`4f73d9ee`).
//! See `.dev/lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md`
//! for the D-142 chain, `.claude/rules/abi_callee_saved_pinning.md`
//! for the cohort discipline, ADR-0185 for the EH frame-walk.
//!
//! Layout:
//!
//! ```text
//! offset  encoding                            disassembly
//! 0x00    55                                  PUSH RBP           ; frame link (saved importer RBP)
//! 0x01    48 89 E5                            MOV  RBP, RSP      ; [RBP,8] = importer retaddr
//! 0x04    41 57                               PUSH R15           ; save caller's R15 (= caller_rt)
//! 0x06    48 83 EC 08                         SUB  RSP, 8        ; alignment pad
//! 0x0A    48 BF <callee_rt LE 8 bytes>        MOV  RDI, imm64    ; SysV arg0
//! 0x14    48 B8 <callee_entry LE 8 bytes>     MOV  RAX, imm64
//! 0x1E    FF D0                               CALL RAX           ; SysV CALL (RSP 16-aligned here)
//! 0x20    48 83 C4 08                         ADD  RSP, 8        ; undo pad
//! 0x24    41 5F                               POP  R15           ; restore caller's R15
//! 0x26    5D                                  POP  RBP           ; restore importer's RBP
//! 0x27    C3                                  RET                ; return to importer
//! ```
//!
//! 1 + 3 + 2 + 4 + 10 + 10 + 2 + 4 + 2 + 1 + 1 = 40 bytes total. The
//! literals are embedded directly in the MOV imm64 instructions (no
//! separate pool), so the thunk is position-independent: relocate to
//! any byte-aligned RX page without patching.
//!
//! SysV AMD64 §3.2.1 invariant: RBX, RBP, R12..R15 are callee-saved.
//! v2's JIT prologue (per ADR-0026 Cc-pivot) overwrites R15 with the
//! new `*JitRuntime` argument WITHOUT first stack-saving the caller's
//! value. For same-module calls this is a no-op (caller_rt ≡ callee_rt)
//! but for cross-module bridge thunks caller_rt ≠ callee_rt, so the
//! bridge thunk pays the save/restore cost on the caller's behalf.
//! Same discipline pattern as arm64 X19; see ADR-0066 §A1.
//!
//! Stack-alignment note (D-238 changed this): SysV requires
//! `RSP % 16 == 0` at the point of CALL. The importer's CALL into the
//! thunk leaves entry RSP ≡ 8 mod 16 (pushed return address). The two
//! pushes (`PUSH RBP` → ≡0, `PUSH R15` → ≡8) would leave `CALL RAX`
//! misaligned, so the explicit `SUB RSP, 8` pad restores ≡0 before the
//! CALL (and `ADD RSP, 8` undoes it after). The OLD 27-byte single-push
//! thunk aligned by luck (one push: ≡8 → ≡0); adding the RBP frame-link
//! needs the pad. Load-bearing for SSE/AVX in the callee.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");
const inst = @import("inst.zig");

/// Total thunk size in bytes (PUSH RBP [1] + MOV RBP,RSP [3] + PUSH
/// R15 [2] + SUB RSP,8 [4] + MOV RDI imm64 [10] + MOV RAX imm64 [10]
/// + CALL RAX [2] + ADD RSP,8 [4] + POP R15 [2] + POP RBP [1] + RET
/// [1] = 40). Stable across all callee signatures.
pub const thunk_bytes: usize = 40;

/// Emit one bridge thunk into `buf[0..thunk_bytes]`. `buf` MUST be
/// exactly `thunk_bytes` long; the caller is responsible for
/// allocating it inside an RX-mappable arena.
///
/// `callee_rt`    — the callee instance's `*JitRuntime` value
///                  to install in RDI before the CALL.
/// `callee_entry` — the callee's JIT entry point.
pub fn emitThunk(buf: []u8, callee_rt: usize, callee_entry: usize) void {
    std.debug.assert(buf.len == thunk_bytes);
    // PUSH RBP — establish the frame link so the cross-instance EH
    // unwinder can walk through the thunk (D-238 / ADR-0185 a).
    @memcpy(buf[0..1], inst.encPushR(.rbp).slice());
    // MOV RBP, RSP — now [RBP,0]=saved RBP, [RBP,8]=importer retaddr.
    @memcpy(buf[1..4], inst.encMovRR(.q, .rbp, .rsp).slice());
    // PUSH R15 — save caller's R15 = caller_rt (D-142 cohort save).
    @memcpy(buf[4..6], inst.encPushR(.r15).slice());
    // SUB RSP, 8 — alignment pad (two pushes left RSP ≡ 8; restore ≡ 0
    // so the CALL below is SysV 16-aligned).
    @memcpy(buf[6..10], inst.encSubRSpImm8(8).slice());
    // MOV RDI, callee_rt — SysV arg0 (= *JitRuntime).
    @memcpy(buf[10..20], inst.encMovImm64Q(.rdi, callee_rt).slice());
    // MOV RAX, callee_entry.
    @memcpy(buf[20..30], inst.encMovImm64Q(.rax, callee_entry).slice());
    // CALL RAX — SysV CALL (not JMP); pushes post-CALL RIP so the
    // callee's RET returns here.
    @memcpy(buf[30..32], inst.encCallReg(.rax).slice());
    // ADD RSP, 8 — undo the alignment pad.
    @memcpy(buf[32..36], inst.encAddRSpImm8(8).slice());
    // POP R15 — RESTORE caller's R15.
    @memcpy(buf[36..38], inst.encPopR(.r15).slice());
    // POP RBP — RESTORE importer's RBP.
    @memcpy(buf[38..39], inst.encPopR(.rbp).slice());
    // RET — return to importer's call site.
    @memcpy(buf[39..40], inst.encRet().slice());
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "emitThunk: byte-exact layout for known constants (D-238 RBP frame-link)" {
    var buf: [thunk_bytes]u8 = undefined;
    const callee_rt: usize = 0xDEADBEEF_CAFEBABE;
    const callee_entry: usize = 0x12345678_9ABCDEF0;
    emitThunk(&buf, callee_rt, callee_entry);

    try testing.expectEqual(@as(u8, 0x55), buf[0]); // PUSH RBP
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xE5 }, buf[1..4]); // MOV RBP,RSP
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x57 }, buf[4..6]); // PUSH R15
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xEC, 0x08 }, buf[6..10]); // SUB RSP,8
    // MOV RDI, callee_rt — REX.W (48) + B8+rdi.low3=7=BF + LE imm64
    try testing.expectEqualSlices(u8, &.{
        0x48, 0xBF,
        0xBE, 0xBA,
        0xFE, 0xCA,
        0xEF, 0xBE,
        0xAD, 0xDE,
    }, buf[10..20]);
    // MOV RAX, callee_entry — REX.W (48) + B8+rax.low3=0=B8 + LE imm64
    try testing.expectEqualSlices(u8, &.{
        0x48, 0xB8,
        0xF0, 0xDE,
        0xBC, 0x9A,
        0x78, 0x56,
        0x34, 0x12,
    }, buf[20..30]);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, buf[30..32]); // CALL RAX
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC4, 0x08 }, buf[32..36]); // ADD RSP,8
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5F }, buf[36..38]); // POP R15
    try testing.expectEqual(@as(u8, 0x5D), buf[38]); // POP RBP
    try testing.expectEqual(@as(u8, 0xC3), buf[39]); // RET
}

test "emitThunk: round-trip literals at zero" {
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0, 0);
    // Frame + opcode bytes unchanged; both imm64 fields all-zero.
    try testing.expectEqual(@as(u8, 0x55), buf[0]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xE5 }, buf[1..4]);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x57 }, buf[4..6]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xEC, 0x08 }, buf[6..10]);
    try testing.expectEqual(@as(u8, 0x48), buf[10]);
    try testing.expectEqual(@as(u8, 0xBF), buf[11]);
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[12..20], .little));
    try testing.expectEqual(@as(u8, 0x48), buf[20]);
    try testing.expectEqual(@as(u8, 0xB8), buf[21]);
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, buf[22..30], .little));
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, buf[30..32]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC4, 0x08 }, buf[32..36]);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5F }, buf[36..38]);
    try testing.expectEqual(@as(u8, 0x5D), buf[38]);
    try testing.expectEqual(@as(u8, 0xC3), buf[39]);
}

test "emitThunk: opcode/frame bytes constant across two distinct callees" {
    var buf_a: [thunk_bytes]u8 = undefined;
    var buf_b: [thunk_bytes]u8 = undefined;
    emitThunk(&buf_a, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888);
    emitThunk(&buf_b, 0xAAAA_BBBB_CCCC_DDDD, 0xEEEE_FFFF_0000_1111);
    // Frame + opcode bytes at fixed offsets must match across thunks
    // (ADR-0066 §A1 + ADR-0185 a invariant); only the imm64 literals differ.
    try testing.expectEqualSlices(u8, buf_a[0..12], buf_b[0..12]); // frame + MOV RDI opcode
    try testing.expectEqualSlices(u8, buf_a[20..22], buf_b[20..22]); // MOV RAX opcode
    try testing.expectEqualSlices(u8, buf_a[30..40], buf_b[30..40]); // CALL + ADD + POP + POP + RET
}

test "emitThunk: D-142 R15 save/restore + D-238 RBP frame around CALL" {
    // Structural assertion: a standard frame (PUSH RBP / MOV RBP,RSP /
    // POP RBP) wraps the body, and PUSH R15 / POP R15 wraps the CALL RAX.
    // These are the load-bearing invariants — RBP frame for the EH unwind
    // (D-238), R15 save for the cohort (D-142). A future encoder reshuffle
    // that drops either fails here before the runtime SEGV / unwind break.
    var buf: [thunk_bytes]u8 = undefined;
    emitThunk(&buf, 0xDEADBEEF, 0xCAFEBABE);
    try testing.expectEqual(@as(u8, 0x55), buf[0]); // PUSH RBP
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xE5 }, buf[1..4]); // MOV RBP,RSP
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x57 }, buf[4..6]); // PUSH R15
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, buf[30..32]); // CALL RAX
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5F }, buf[36..38]); // POP R15
    try testing.expectEqual(@as(u8, 0x5D), buf[38]); // POP RBP
    try testing.expectEqual(@as(u8, 0xC3), buf[39]); // RET
}
