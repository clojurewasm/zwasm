//! Shared loop / branch / liveness analysis for the JIT pipeline.
//!
//! Owns the data structures that describe a function's control-flow
//! shape (where the branch targets are, which PCs are loop headers,
//! how long each loop body extends) plus per-vreg liveness (first
//! definition, last use). Phase 4+ extends this with classification of
//! loop-invariant constants.
//!
//! Both JIT backends consume the same `LoopInfo` instead of running
//! their own pre-scans. Cost: one forward sweep over the RegInstr
//! stream per compile (control-flow sweep + liveness sweep are fused).

const std = @import("std");
const regalloc = @import("regalloc.zig");

const RegInstr = regalloc.RegInstr;

/// Sentinel used by `vreg_first_def[v]` to mean "vreg v is never written
/// inside the function body". Callers wishing to ask "is v defined before
/// PC X?" should treat NEVER_DEFINED as "no, not defined here". Params
/// and locals are conceptually defined at function entry but their
/// definition is implicit (no RegInstr writes them) — Phase 4 handles
/// that distinction by also treating `v < local_count` as defined-before-loop.
pub const NEVER_DEFINED: u32 = std.math.maxInt(u32);

pub const LoopInfo = struct {
    /// branch_targets[pc] = true iff some control-flow op (BR, BR_IF,
    /// BR_IF_NOT, BR_TABLE, BLOCK_END) targets this PC. Drives JIT
    /// cache eviction and the known_consts wipe.
    branch_targets: []bool = &.{},

    /// loop_headers[pc] = true iff `pc` is the target of a backward
    /// branch (i.e. a loop entry).
    loop_headers: []bool = &.{},

    /// loop_end[header_pc] = max source PC of any back-edge into
    /// header_pc. Defines the inclusive range `[header_pc, loop_end]`
    /// that the loop body covers. 0 for non-headers.
    loop_end: []u32 = &.{},

    /// vreg_first_def[v] = PC of the first RegInstr that writes vreg v,
    /// or `NEVER_DEFINED` if v is never assigned by any instruction in
    /// this function body. "Write" here is dataflow-correct: stores
    /// (0x36..0x3E), conditional branches (BR_IF / BR_IF_NOT) and
    /// RETURN treat rd as a SOURCE, not a destination, and are ignored.
    vreg_first_def: []u32 = &.{},

    /// vreg_last_use[v] = PC of the last RegInstr that reads vreg v
    /// (rs1, rs2_field, or rd-as-source for stores / conditional
    /// branches / RETURN). 0 if v is never read.
    /// Conservative: opcodes that don't actually consume rs1/rs2 (BR,
    /// CONST32, CONST64, BLOCK_END, NOP, DELETED) are excluded;
    /// everything else treats both rs1 and rs2_field as a read. The
    /// over-approximation extends last_use later than necessary, which
    /// only shrinks the coalescing window in Phase 5 — safe by design.
    vreg_last_use: []u32 = &.{},

    /// Number of vregs the liveness arrays cover. Equals reg_func.reg_count
    /// at analyse() time. Used for bounds checks in callers.
    vreg_count: u32 = 0,

    /// The single divisor with the highest count of `CONST32 K → DIV_U/REM_U`
    /// (or signed variants) immediately-adjacent pairs anywhere in the body.
    /// `null` if no such pattern exists or the count is below the threshold
    /// for hoist amortisation. The JIT consults this to decide whether to
    /// reserve a callee-saved slot for the magic constant in the prologue.
    /// Phase 3 supports a single dominant divisor; multi-divisor hoist is
    /// future work.
    dominant_divisor: ?u32 = null,
    /// Number of div/rem sites in the function body that match
    /// `dominant_divisor`. Used by callers to decide whether the hoist
    /// pays for itself (≥ 1 always wins over the per-iter MOVZ+MOVK
    /// because the prologue load is at most 2 instrs and div sites in
    /// loops execute many times — the loop is the multiplier).
    dominant_use_count: u16 = 0,

    /// Free all owned slices. Safe to call on a default-initialized
    /// (empty) LoopInfo.
    pub fn deinit(self: *LoopInfo, alloc: std.mem.Allocator) void {
        if (self.branch_targets.len > 0) alloc.free(self.branch_targets);
        if (self.loop_headers.len > 0) alloc.free(self.loop_headers);
        if (self.loop_end.len > 0) alloc.free(self.loop_end);
        if (self.vreg_first_def.len > 0) alloc.free(self.vreg_first_def);
        if (self.vreg_last_use.len > 0) alloc.free(self.vreg_last_use);
        self.* = .{};
    }

    /// Single forward sweep populating branch_targets / loop_headers /
    /// loop_end and per-vreg first_def / last_use. Returns false on
    /// allocation failure (caller treats the JIT compile as a bail).
    pub fn analyse(
        self: *LoopInfo,
        alloc: std.mem.Allocator,
        ir: []const RegInstr,
        reg_count: u32,
    ) bool {
        const targets = alloc.alloc(bool, ir.len) catch return false;
        @memset(targets, false);
        const loop_headers = alloc.alloc(bool, ir.len) catch {
            alloc.free(targets);
            return false;
        };
        @memset(loop_headers, false);
        const loop_end = alloc.alloc(u32, ir.len) catch {
            alloc.free(loop_headers);
            alloc.free(targets);
            return false;
        };
        @memset(loop_end, 0);

        const first_def = alloc.alloc(u32, reg_count) catch {
            alloc.free(loop_end);
            alloc.free(loop_headers);
            alloc.free(targets);
            return false;
        };
        @memset(first_def, NEVER_DEFINED);
        const last_use = alloc.alloc(u32, reg_count) catch {
            alloc.free(first_def);
            alloc.free(loop_end);
            alloc.free(loop_headers);
            alloc.free(targets);
            return false;
        };
        @memset(last_use, 0);

        var scan_pc: u32 = 0;
        while (scan_pc < ir.len) {
            const instr = ir[scan_pc];
            const source_pc = scan_pc;
            scan_pc += 1;

            // --- Control-flow shape ---
            switch (instr.op) {
                regalloc.OP_BR => recordTarget(targets, loop_headers, loop_end, instr.operand, source_pc, ir.len),
                regalloc.OP_BR_IF, regalloc.OP_BR_IF_NOT => recordTarget(
                    targets,
                    loop_headers,
                    loop_end,
                    instr.operand,
                    source_pc,
                    ir.len,
                ),
                regalloc.OP_BR_TABLE => {
                    const count = instr.operand;
                    var i: u32 = 0;
                    while (i < count + 1 and scan_pc < ir.len) : (i += 1) {
                        const entry = ir[scan_pc];
                        scan_pc += 1;
                        recordTarget(targets, loop_headers, loop_end, entry.operand, source_pc, ir.len);
                        // BR_TABLE follow-up NOPs participate in liveness too:
                        // their operand is a target PC, not a vreg, so we skip
                        // their rs1/rs2_field/rd entries.
                    }
                },
                regalloc.OP_BLOCK_END => {
                    targets[scan_pc - 1] = true;
                },
                else => {},
            }

            // --- Liveness ---
            //
            // Update last_use BEFORE first_def so a `mov rd = rs1` that
            // happens to have rd == rs1 (degenerate, but legal) records
            // the read at PC and the write at PC. That's correct: the
            // value is read AT this PC and written AT this PC.

            if (regalloc.opUsesRdAsSource(instr.op)) {
                if (instr.rd < reg_count) last_use[instr.rd] = source_pc;
            }
            if (regalloc.opUsesRs1AsSource(instr.op)) {
                if (instr.rs1 < reg_count) last_use[instr.rs1] = source_pc;
            }
            if (regalloc.opUsesRs2AsSource(instr.op)) {
                const r2 = instr.rs2();
                if (r2 < reg_count) last_use[r2] = source_pc;
            }
            // Multi-source ops (CALL / CALL_INDIRECT / RETURN_MULTI /
            // memory.fill / memory.copy) read additional vregs that live
            // in the operand field as a count + following NOP slots, or
            // in special positions. Phase 1 conservatively treats them
            // via the rs1/rs2 fields above (over-approximation only loses
            // optimization in Phase 5; never hurts correctness).

            if (regalloc.opWritesRd(instr.op)) {
                if (instr.rd < reg_count and first_def[instr.rd] == NEVER_DEFINED) {
                    first_def[instr.rd] = source_pc;
                }
            }
        }

        // --- Hoist candidate scan ---
        //
        // Find adjacent `CONST32 rd=V op=K` followed by an unsigned
        // div/rem with rs2 = V. Group by K, keep the divisor with the
        // highest count. Powers of 2 and < 2 are skipped because the
        // existing JIT shortcut handles them with LSR / AND.
        //
        // Local stack array sized for typical TinyGo / Rust / clang
        // outputs (1-3 distinct divisors per function); hoist is single-
        // register today so we only need the max anyway.
        var divisors: [16]Divisor = .{Divisor{ .divisor = 0, .count = 0 }} ** 16;
        var n_divisors: usize = 0;

        if (ir.len >= 2) {
            var i: usize = 0;
            while (i + 1 < ir.len) : (i += 1) {
                const c = ir[i];
                if (c.op != regalloc.OP_CONST32) continue;
                if (c.operand < 2) continue;
                if (c.operand & (c.operand - 1) == 0) continue; // power of 2
                const next = ir[i + 1];
                // 0x6E = i32.div_u, 0x70 = i32.rem_u (unsigned magic-fold path).
                if (next.op != 0x6E and next.op != 0x70) continue;
                if (next.rs2() != c.rd) continue;

                const k = c.operand;
                var found = false;
                for (0..n_divisors) |j| {
                    if (divisors[j].divisor == k) {
                        divisors[j].count +|= 1;
                        found = true;
                        break;
                    }
                }
                if (!found and n_divisors < divisors.len) {
                    divisors[n_divisors] = .{ .divisor = k, .count = 1 };
                    n_divisors += 1;
                }
            }
        }

        var dom_divisor: ?u32 = null;
        var dom_count: u16 = 0;
        for (0..n_divisors) |j| {
            if (divisors[j].count > dom_count) {
                dom_count = divisors[j].count;
                dom_divisor = divisors[j].divisor;
            }
        }

        self.* = .{
            .branch_targets = targets,
            .loop_headers = loop_headers,
            .loop_end = loop_end,
            .vreg_first_def = first_def,
            .vreg_last_use = last_use,
            .vreg_count = reg_count,
            .dominant_divisor = dom_divisor,
            .dominant_use_count = dom_count,
        };
        return true;
    }
};

const Divisor = struct {
    divisor: u32,
    count: u16,
};

fn recordTarget(
    targets: []bool,
    loop_headers: []bool,
    loop_end: []u32,
    target_pc: u32,
    source_pc: u32,
    ir_len: usize,
) void {
    if (target_pc >= ir_len) return;
    targets[target_pc] = true;
    if (target_pc <= source_pc) {
        loop_headers[target_pc] = true;
        if (source_pc > loop_end[target_pc]) {
            loop_end[target_pc] = source_pc;
        }
    }
}

// Opcode classification helpers (opWritesRd / opUsesRdAsSource /
// opUsesRs1AsSource / opUsesRs2AsSource) live in regalloc.zig as the
// canonical source of RegInstr semantics. Both this module and the
// regalloc-stage coalescer consume them.

const testing = std.testing;

test "LoopInfo: empty IR yields empty slices" {
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &.{}, 0));
    try testing.expectEqual(@as(usize, 0), info.branch_targets.len);
    try testing.expectEqual(@as(usize, 0), info.loop_headers.len);
    try testing.expectEqual(@as(usize, 0), info.loop_end.len);
    try testing.expectEqual(@as(usize, 0), info.vreg_first_def.len);
    try testing.expectEqual(@as(usize, 0), info.vreg_last_use.len);
}

test "LoopInfo: forward branch flagged, no loop header" {
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BR, .rd = 0, .rs1 = 0, .operand = 3 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 0));
    try testing.expect(info.branch_targets[3]);
    try testing.expect(!info.loop_headers[3]);
    try testing.expectEqual(@as(u32, 0), info.loop_end[3]);
}

test "LoopInfo: backward branch is a loop header with end_pc" {
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BR_IF, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 0));
    try testing.expect(info.branch_targets[0]);
    try testing.expect(info.loop_headers[0]);
    try testing.expectEqual(@as(u32, 2), info.loop_end[0]);
}

test "LoopInfo: nested back-edges keep max end_pc" {
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BR, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BR, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 0));
    try testing.expectEqual(@as(u32, 4), info.loop_end[0]);
}

test "LoopInfo: BLOCK_END marks the END pc itself as a target" {
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BLOCK_END, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 0));
    try testing.expect(info.branch_targets[1]);
    try testing.expect(!info.loop_headers[1]);
}

test "LoopInfo: liveness — CONST32 writes rd, ADD reads rs1+rs2_field" {
    // pc=0: const32 r2 = 42
    // pc=1: const32 r3 = 5
    // pc=2: i32.add r4 = r2 + r3
    // pc=3: return r4
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_CONST32, .rd = 2, .rs1 = 0, .operand = 42 },
        .{ .op = regalloc.OP_CONST32, .rd = 3, .rs1 = 0, .operand = 5 },
        .{ .op = 0x6A, .rd = 4, .rs1 = 2, .rs2_field = 3, .operand = 0 }, // i32.add
        .{ .op = regalloc.OP_RETURN, .rd = 4, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 5));
    try testing.expectEqual(@as(u32, 5), info.vreg_count);
    // r2 first defined at pc 0, last used at pc 2
    try testing.expectEqual(@as(u32, 0), info.vreg_first_def[2]);
    try testing.expectEqual(@as(u32, 2), info.vreg_last_use[2]);
    // r3 first defined at pc 1, last used at pc 2
    try testing.expectEqual(@as(u32, 1), info.vreg_first_def[3]);
    try testing.expectEqual(@as(u32, 2), info.vreg_last_use[3]);
    // r4 first defined at pc 2, last used at pc 3 (RETURN reads rd)
    try testing.expectEqual(@as(u32, 2), info.vreg_first_def[4]);
    try testing.expectEqual(@as(u32, 3), info.vreg_last_use[4]);
    // r0 / r1 never touched
    try testing.expectEqual(NEVER_DEFINED, info.vreg_first_def[0]);
    try testing.expectEqual(@as(u32, 0), info.vreg_last_use[0]);
    try testing.expectEqual(NEVER_DEFINED, info.vreg_first_def[1]);
}

test "LoopInfo: liveness — store reads rd, does not write rd" {
    // pc=0: const32 r2 = 100   (address)
    // pc=1: const32 r3 = 7     (value)
    // pc=2: i32.store rd=r3, rs1=r2  (op 0x36)
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_CONST32, .rd = 2, .rs1 = 0, .operand = 100 },
        .{ .op = regalloc.OP_CONST32, .rd = 3, .rs1 = 0, .operand = 7 },
        .{ .op = 0x36, .rd = 3, .rs1 = 2, .operand = 0 }, // i32.store
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 5));
    // The store does not redefine r3; first_def stays at pc=1
    try testing.expectEqual(@as(u32, 1), info.vreg_first_def[3]);
    // Both r2 (address) and r3 (value) are read at pc=2
    try testing.expectEqual(@as(u32, 2), info.vreg_last_use[2]);
    try testing.expectEqual(@as(u32, 2), info.vreg_last_use[3]);
}

test "LoopInfo: liveness — BR_IF reads rd as condition" {
    // pc=0: const32 r2 = 1   (condition)
    // pc=1: br_if rd=r2 -> pc=3
    // pc=2: nop
    // pc=3: nop
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_CONST32, .rd = 2, .rs1 = 0, .operand = 1 },
        .{ .op = regalloc.OP_BR_IF, .rd = 2, .rs1 = 0, .operand = 3 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 4));
    // r2 first defined at pc=0, BR_IF reads it (does NOT redefine) at pc=1
    try testing.expectEqual(@as(u32, 0), info.vreg_first_def[2]);
    try testing.expectEqual(@as(u32, 1), info.vreg_last_use[2]);
}

test "LoopInfo: hoist — three CONST32→DIV_U pairs collapse to dominant_divisor" {
    // Mirror tgo_string_ops digitCount's pattern: three (const32, div_u 10)
    // pairs scattered through the function body. Expected:
    // dominant_divisor = 10, dominant_use_count = 3.
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_CONST32, .rd = 8, .rs1 = 0, .operand = 10 },
        .{ .op = 0x6E, .rd = 8, .rs1 = 0, .rs2_field = 8, .operand = 0 }, // i32.div_u
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_CONST32, .rd = 9, .rs1 = 0, .operand = 10 },
        .{ .op = 0x6E, .rd = 9, .rs1 = 0, .rs2_field = 9, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_CONST32, .rd = 12, .rs1 = 1, .operand = 10 },
        .{ .op = 0x6E, .rd = 12, .rs1 = 1, .rs2_field = 12, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 16));
    try testing.expectEqual(@as(?u32, 10), info.dominant_divisor);
    try testing.expectEqual(@as(u16, 3), info.dominant_use_count);
}

test "LoopInfo: hoist — power-of-2 divisor is ignored (existing LSR shortcut)" {
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_CONST32, .rd = 4, .rs1 = 0, .operand = 8 },
        .{ .op = 0x6E, .rd = 4, .rs1 = 0, .rs2_field = 4, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 8));
    try testing.expectEqual(@as(?u32, null), info.dominant_divisor);
    try testing.expectEqual(@as(u16, 0), info.dominant_use_count);
}

test "LoopInfo: hoist — distinct divisors count separately, max wins" {
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_CONST32, .rd = 4, .rs1 = 0, .operand = 7 },
        .{ .op = 0x6E, .rd = 4, .rs1 = 0, .rs2_field = 4, .operand = 0 },
        .{ .op = regalloc.OP_CONST32, .rd = 5, .rs1 = 0, .operand = 11 },
        .{ .op = 0x6E, .rd = 5, .rs1 = 0, .rs2_field = 5, .operand = 0 },
        .{ .op = regalloc.OP_CONST32, .rd = 6, .rs1 = 0, .operand = 11 },
        .{ .op = 0x6E, .rd = 6, .rs1 = 0, .rs2_field = 6, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 8));
    // 11 has 2 uses, 7 has 1 — the max is 11.
    try testing.expectEqual(@as(?u32, 11), info.dominant_divisor);
    try testing.expectEqual(@as(u16, 2), info.dominant_use_count);
}

test "LoopInfo: liveness — MOV does not over-read rs2 default 0" {
    // pc=0: const32 r5 = 99
    // pc=1: mov r6 = r5  (rs1=5, rs2_field defaults to 0)
    // We must NOT mark vreg 0 as last_used at pc=1 just because rs2
    // defaulted to 0.
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_CONST32, .rd = 5, .rs1 = 0, .operand = 99 },
        .{ .op = regalloc.OP_MOV, .rd = 6, .rs1 = 5, .rs2_field = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir, 8));
    try testing.expectEqual(@as(u32, 1), info.vreg_last_use[5]); // read at pc=1
    try testing.expectEqual(@as(u32, 0), info.vreg_last_use[0]); // never read
}
