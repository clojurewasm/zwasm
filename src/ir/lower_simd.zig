//! Wasm SIMD (0xFD prefix) lowerer — extracted from `lower.zig`
//! per ADR-0089 (ADR-0083 pattern). The non-SIMD lowerer +
//! `Lowerer` struct stay in `lower.zig`; the 0xFD prefix dispatcher
//! and its SIMD-only helpers (emitLaneByte, emitMemargLane) move
//! here.
//!
//! `Lowerer` is pub in lower.zig so this sibling can name it as
//! the `self` parameter type. Cross-file method syntax
//! (`self.method()`) works for the non-moved methods (`emit`,
//! `emitMemarg`, `appendSimdConst`) because they are pub on
//! Lowerer. Intra-moved calls (`emitLaneByte` / `emitMemargLane`)
//! are converted to free-fn form (`name(self, args)`) since the
//! moved fn is no longer a method.
//!
//! See lesson `2026-05-21-cross-file-struct-method-syntax-zig-0-16.md`.
//!
//! Zone 1 (`src/ir/`) — may import Zone 0 only.

const support = @import("../support/leb128.zig");
const leb128 = support;
const zir = @import("zir.zig");
const lower = @import("lower.zig");

const Lowerer = lower.Lowerer;
const Error = lower.Error;
const ZirOp = zir.ZirOp;

/// Wasm SIMD-128 prefix-0xFD opcode group (§9.9 per ADR-0041).
/// Sub-opcode is uleb32; MVP catalogue mirrors the validator's
/// 9.3 coverage. The 16-byte v128.const immediate + 16-byte
/// shuffle lane immediate are stored via the ZirInstr's
/// `payload`/`extra` fields as offsets into a side-table managed
/// in 9.5 emit; for the 9.4 lower-pass MVP, we record the
/// immediate's byte offset within `self.body` so emit can read
/// the original bytes by position. Per ADR-0041 §"Decision" / 1
/// (shape-as-variant), each sub-opcode resolves to a single
/// ZirOp without nested dispatch.
pub fn emitPrefixFD(self: *Lowerer) Error!void {
    const sub = try leb128.readUleb128(u32, self.body, &self.pos);
    switch (sub) {
        0 => try self.emitMemarg(.@"v128.load"),
        1 => try self.emitMemarg(.@"v128.load8x8_s"),
        2 => try self.emitMemarg(.@"v128.load8x8_u"),
        3 => try self.emitMemarg(.@"v128.load16x4_s"),
        4 => try self.emitMemarg(.@"v128.load16x4_u"),
        5 => try self.emitMemarg(.@"v128.load32x2_s"),
        6 => try self.emitMemarg(.@"v128.load32x2_u"),
        7 => try self.emitMemarg(.@"v128.load8_splat"),
        8 => try self.emitMemarg(.@"v128.load16_splat"),
        9 => try self.emitMemarg(.@"v128.load32_splat"),
        10 => try self.emitMemarg(.@"v128.load64_splat"),
        11 => try self.emitMemarg(.@"v128.store"),
        92 => try self.emitMemarg(.@"v128.load32_zero"),
        93 => try self.emitMemarg(.@"v128.load64_zero"),

        // §9.7 / 9.7-ba — load_lane × 4, store_lane × 4. Memarg +
        // 1-byte lane immediate. payload = offset; extra = lane.
        // align is dropped (unused in emit, validator already
        // consumed it for type-stack tracking).
        84 => try emitMemargLane(self, .@"v128.load8_lane"),
        85 => try emitMemargLane(self, .@"v128.load16_lane"),
        86 => try emitMemargLane(self, .@"v128.load32_lane"),
        87 => try emitMemargLane(self, .@"v128.load64_lane"),
        88 => try emitMemargLane(self, .@"v128.store8_lane"),
        89 => try emitMemargLane(self, .@"v128.store16_lane"),
        90 => try emitMemargLane(self, .@"v128.store32_lane"),
        91 => try emitMemargLane(self, .@"v128.store64_lane"),

        12 => {
            // v128.const: 16 immediate bytes. Per ADR-0042, copy
            // into per-function simd_consts pool; payload stores
            // the array index.
            if (self.pos + 16 > self.body.len) return Error.UnexpectedEnd;
            var bytes: [16]u8 = undefined;
            @memcpy(&bytes, self.body[self.pos..][0..16]);
            self.pos += 16;
            const idx = try self.appendSimdConst(bytes);
            try self.emit(.@"v128.const", idx, 0);
        },
        13 => {
            // i8x16.shuffle: 16 immediate lane bytes (each < 32).
            // Per ADR-0042, copy into per-function simd_consts pool;
            // payload stores the array index.
            if (self.pos + 16 > self.body.len) return Error.UnexpectedEnd;
            for (self.body[self.pos..][0..16]) |lane| {
                if (lane >= 32) return Error.BadBlockType;
            }
            var bytes: [16]u8 = undefined;
            @memcpy(&bytes, self.body[self.pos..][0..16]);
            self.pos += 16;
            const idx = try self.appendSimdConst(bytes);
            try self.emit(.@"i8x16.shuffle", idx, 0);
        },
        14 => try self.emit(.@"i8x16.swizzle", 0, 0),

        // Splats: single ZirOp per shape; no immediate payload.
        15 => try self.emit(.@"i8x16.splat", 0, 0),
        16 => try self.emit(.@"i16x8.splat", 0, 0),
        17 => try self.emit(.@"i32x4.splat", 0, 0),
        18 => try self.emit(.@"i64x2.splat", 0, 0),
        19 => try self.emit(.@"f32x4.splat", 0, 0),
        20 => try self.emit(.@"f64x2.splat", 0, 0),

        // extract_lane / replace_lane: 1-byte lane immediate → payload.
        21 => try emitLaneByte(self, .@"i8x16.extract_lane_s"),
        22 => try emitLaneByte(self, .@"i8x16.extract_lane_u"),
        23 => try emitLaneByte(self, .@"i8x16.replace_lane"),
        24 => try emitLaneByte(self, .@"i16x8.extract_lane_s"),
        25 => try emitLaneByte(self, .@"i16x8.extract_lane_u"),
        26 => try emitLaneByte(self, .@"i16x8.replace_lane"),
        27 => try emitLaneByte(self, .@"i32x4.extract_lane"),
        28 => try emitLaneByte(self, .@"i32x4.replace_lane"),
        29 => try emitLaneByte(self, .@"i64x2.extract_lane"),
        30 => try emitLaneByte(self, .@"i64x2.replace_lane"),
        31 => try emitLaneByte(self, .@"f32x4.extract_lane"),
        32 => try emitLaneByte(self, .@"f32x4.replace_lane"),
        33 => try emitLaneByte(self, .@"f64x2.extract_lane"),
        34 => try emitLaneByte(self, .@"f64x2.replace_lane"),

        // Comparison / bitwise / int-arith / float-arith: full
        // op-by-op catalogue lands in 9.5/9.6 ARM64 emit + 9.7/
        // 9.8 x86_64 emit chunks alongside their lowering. For
        // 9.4 MVP we lower a representative subset (`i32x4.add`,
        // `v128.not`) demonstrating the pattern; remaining
        // sub-opcodes below the validator-accepted ranges return
        // `NotImplemented` here even though the validator
        // accepts them — the lower → emit pipeline closes the
        // gap as the emit chunks land.
        174 => try self.emit(.@"i32x4.add", 0, 0),
        77 => try self.emit(.@"v128.not", 0, 0),
        // §9.9 / 9.9-f-1: bitwise ops 78..82 lower-side wiring.
        // Validator now accepts these (split out of the 35..82
        // binop range); arm64 + x86_64 emit dispatch already
        // handles them via existing op_simd handlers.
        78 => try self.emit(.@"v128.and", 0, 0),
        79 => try self.emit(.@"v128.andnot", 0, 0),
        80 => try self.emit(.@"v128.or", 0, 0),
        81 => try self.emit(.@"v128.xor", 0, 0),
        82 => try self.emit(.@"v128.bitselect", 0, 0),
        // §9.9 / 9.9-f-5: f32x4 / f64x2 arith (sub-opcodes
        // 224..247). Validator already accepts them (binop /
        // unop split landed alongside this commit); emit
        // handlers in arm64/op_simd.zig + x86_64/op_simd.zig
        // are pre-wired in 9.6/9.7. Sub-opcode → ZirOp:
        //   224..235 → f32x4 (abs/neg/_/sqrt + add/sub/mul/
        //   div + min/max/pmin/pmax)
        //   236..247 → f64x2 (abs/neg/_/sqrt + add/sub/mul/
        //   div + min/max/pmin/pmax)
        // 226 + 238 are unused gaps in the spec.
        224 => try self.emit(.@"f32x4.abs", 0, 0),
        225 => try self.emit(.@"f32x4.neg", 0, 0),
        227 => try self.emit(.@"f32x4.sqrt", 0, 0),
        228 => try self.emit(.@"f32x4.add", 0, 0),
        229 => try self.emit(.@"f32x4.sub", 0, 0),
        230 => try self.emit(.@"f32x4.mul", 0, 0),
        231 => try self.emit(.@"f32x4.div", 0, 0),
        232 => try self.emit(.@"f32x4.min", 0, 0),
        233 => try self.emit(.@"f32x4.max", 0, 0),
        234 => try self.emit(.@"f32x4.pmin", 0, 0),
        235 => try self.emit(.@"f32x4.pmax", 0, 0),
        236 => try self.emit(.@"f64x2.abs", 0, 0),
        237 => try self.emit(.@"f64x2.neg", 0, 0),
        239 => try self.emit(.@"f64x2.sqrt", 0, 0),
        240 => try self.emit(.@"f64x2.add", 0, 0),
        241 => try self.emit(.@"f64x2.sub", 0, 0),
        242 => try self.emit(.@"f64x2.mul", 0, 0),
        243 => try self.emit(.@"f64x2.div", 0, 0),
        244 => try self.emit(.@"f64x2.min", 0, 0),
        245 => try self.emit(.@"f64x2.max", 0, 0),
        246 => try self.emit(.@"f64x2.pmin", 0, 0),
        247 => try self.emit(.@"f64x2.pmax", 0, 0),
        // §9.9 / 9.9-f-6: int arith (i8x16 / i16x8 / i32x4 /
        // i64x2). Sub-opcodes per Wasm SIMD spec:
        //   96..98 / 110..113: i8x16 abs/neg/popcnt + add/sub
        //   128..149: i16x8 abs/neg/q15mulr/all_true/bitmask
        //             /extend_*/add/add_sat/sub/sub_sat/mul
        //   160..182: i32x4 abs/neg/all_true/bitmask/extend_*
        //             /add/sub/mul/min/max/dot
        //   192..213: i64x2 abs/neg/all_true/bitmask/extend_*
        //             /shl/shr/add/sub/mul
        // ZirOps + emit handlers exist from 9.5..9.7; this just
        // closes the lower-side dispatch.
        96 => try self.emit(.@"i8x16.abs", 0, 0),
        97 => try self.emit(.@"i8x16.neg", 0, 0),
        98 => try self.emit(.@"i8x16.popcnt", 0, 0),
        110 => try self.emit(.@"i8x16.add", 0, 0),
        113 => try self.emit(.@"i8x16.sub", 0, 0),
        128 => try self.emit(.@"i16x8.abs", 0, 0),
        129 => try self.emit(.@"i16x8.neg", 0, 0),
        142 => try self.emit(.@"i16x8.add", 0, 0),
        145 => try self.emit(.@"i16x8.sub", 0, 0),
        149 => try self.emit(.@"i16x8.mul", 0, 0),
        160 => try self.emit(.@"i32x4.abs", 0, 0),
        161 => try self.emit(.@"i32x4.neg", 0, 0),
        177 => try self.emit(.@"i32x4.sub", 0, 0),
        181 => try self.emit(.@"i32x4.mul", 0, 0),
        192 => try self.emit(.@"i64x2.abs", 0, 0),
        193 => try self.emit(.@"i64x2.neg", 0, 0),
        206 => try self.emit(.@"i64x2.add", 0, 0),
        209 => try self.emit(.@"i64x2.sub", 0, 0),
        213 => try self.emit(.@"i64x2.mul", 0, 0),

        // §9.9 / 9.9-g-10 — int min/max + avgr_u (14 ops, lower-side
        // wiring). Per Wasm SIMD spec sub-op numbering:
        //   118..123: i8x16.{min_s, min_u, max_s, max_u, avgr_u}  (122 unused)
        //   150..155: i16x8.{min_s, min_u, max_s, max_u, avgr_u}  (154 unused)
        //   182..185: i32x4.{min_s, min_u, max_s, max_u}  (no i32x4.avgr_u)
        // Validator already routes these through opSimdBinop (94..211
        // binop fallthrough); ZirOps + per-arch emit handlers landed
        // alongside this chunk for ARM64. x86_64 dispatch pre-existed
        // since §9.7-au.
        118 => try self.emit(.@"i8x16.min_s", 0, 0),
        119 => try self.emit(.@"i8x16.min_u", 0, 0),
        120 => try self.emit(.@"i8x16.max_s", 0, 0),
        121 => try self.emit(.@"i8x16.max_u", 0, 0),
        123 => try self.emit(.@"i8x16.avgr_u", 0, 0),
        150 => try self.emit(.@"i16x8.min_s", 0, 0),
        151 => try self.emit(.@"i16x8.min_u", 0, 0),
        152 => try self.emit(.@"i16x8.max_s", 0, 0),
        153 => try self.emit(.@"i16x8.max_u", 0, 0),
        155 => try self.emit(.@"i16x8.avgr_u", 0, 0),
        182 => try self.emit(.@"i32x4.min_s", 0, 0),
        183 => try self.emit(.@"i32x4.min_u", 0, 0),
        184 => try self.emit(.@"i32x4.max_s", 0, 0),
        185 => try self.emit(.@"i32x4.max_u", 0, 0),

        // §9.9 / 9.9-g-2: SIMD comparison ops. ZirOps + per-arch
        // emit dispatch pre-existed; only the lower-side
        // sub-op→ZirOp wiring was missing. Wasm SIMD spec:
        //   35..44  i8x16.{eq, ne, lt_s, lt_u, gt_s, gt_u,
        //                  le_s, le_u, ge_s, ge_u}
        //   45..54  i16x8.{eq, ne, lt_s, lt_u, gt_s, gt_u,
        //                  le_s, le_u, ge_s, ge_u}
        //   55..64  i32x4.{eq, ne, lt_s, lt_u, gt_s, gt_u,
        //                  le_s, le_u, ge_s, ge_u}
        //   65..70  f32x4.{eq, ne, lt, gt, le, ge}
        //   71..76  f64x2.{eq, ne, lt, gt, le, ge}
        //  214..219 i64x2.{eq, ne, lt_s, gt_s, le_s, ge_s}
        //           — i64x2 only has signed compare per spec
        35 => try self.emit(.@"i8x16.eq", 0, 0),
        36 => try self.emit(.@"i8x16.ne", 0, 0),
        37 => try self.emit(.@"i8x16.lt_s", 0, 0),
        38 => try self.emit(.@"i8x16.lt_u", 0, 0),
        39 => try self.emit(.@"i8x16.gt_s", 0, 0),
        40 => try self.emit(.@"i8x16.gt_u", 0, 0),
        41 => try self.emit(.@"i8x16.le_s", 0, 0),
        42 => try self.emit(.@"i8x16.le_u", 0, 0),
        43 => try self.emit(.@"i8x16.ge_s", 0, 0),
        44 => try self.emit(.@"i8x16.ge_u", 0, 0),
        45 => try self.emit(.@"i16x8.eq", 0, 0),
        46 => try self.emit(.@"i16x8.ne", 0, 0),
        47 => try self.emit(.@"i16x8.lt_s", 0, 0),
        48 => try self.emit(.@"i16x8.lt_u", 0, 0),
        49 => try self.emit(.@"i16x8.gt_s", 0, 0),
        50 => try self.emit(.@"i16x8.gt_u", 0, 0),
        51 => try self.emit(.@"i16x8.le_s", 0, 0),
        52 => try self.emit(.@"i16x8.le_u", 0, 0),
        53 => try self.emit(.@"i16x8.ge_s", 0, 0),
        54 => try self.emit(.@"i16x8.ge_u", 0, 0),
        55 => try self.emit(.@"i32x4.eq", 0, 0),
        56 => try self.emit(.@"i32x4.ne", 0, 0),
        57 => try self.emit(.@"i32x4.lt_s", 0, 0),
        58 => try self.emit(.@"i32x4.lt_u", 0, 0),
        59 => try self.emit(.@"i32x4.gt_s", 0, 0),
        60 => try self.emit(.@"i32x4.gt_u", 0, 0),
        61 => try self.emit(.@"i32x4.le_s", 0, 0),
        62 => try self.emit(.@"i32x4.le_u", 0, 0),
        63 => try self.emit(.@"i32x4.ge_s", 0, 0),
        64 => try self.emit(.@"i32x4.ge_u", 0, 0),
        65 => try self.emit(.@"f32x4.eq", 0, 0),
        66 => try self.emit(.@"f32x4.ne", 0, 0),
        67 => try self.emit(.@"f32x4.lt", 0, 0),
        68 => try self.emit(.@"f32x4.gt", 0, 0),
        69 => try self.emit(.@"f32x4.le", 0, 0),
        70 => try self.emit(.@"f32x4.ge", 0, 0),
        71 => try self.emit(.@"f64x2.eq", 0, 0),
        72 => try self.emit(.@"f64x2.ne", 0, 0),
        73 => try self.emit(.@"f64x2.lt", 0, 0),
        74 => try self.emit(.@"f64x2.gt", 0, 0),
        75 => try self.emit(.@"f64x2.le", 0, 0),
        76 => try self.emit(.@"f64x2.ge", 0, 0),
        214 => try self.emit(.@"i64x2.eq", 0, 0),
        215 => try self.emit(.@"i64x2.ne", 0, 0),
        216 => try self.emit(.@"i64x2.lt_s", 0, 0),
        217 => try self.emit(.@"i64x2.gt_s", 0, 0),
        218 => try self.emit(.@"i64x2.le_s", 0, 0),
        219 => try self.emit(.@"i64x2.ge_s", 0, 0),

        // §9.9 / 9.9-g-3 + 9.9-g-19 — v128 → i32 reductions
        // (any_true, all_true, bitmask). Wasm SIMD spec §4.4
        // (vector reductions). Bitmask family wired per
        // ADR-0051 (arm64 extra_consts infrastructure).
        83 => try self.emit(.@"v128.any_true", 0, 0),
        99 => try self.emit(.@"i8x16.all_true", 0, 0),
        131 => try self.emit(.@"i16x8.all_true", 0, 0),
        163 => try self.emit(.@"i32x4.all_true", 0, 0),
        195 => try self.emit(.@"i64x2.all_true", 0, 0),
        100 => try self.emit(.@"i8x16.bitmask", 0, 0),
        132 => try self.emit(.@"i16x8.bitmask", 0, 0),
        164 => try self.emit(.@"i32x4.bitmask", 0, 0),
        196 => try self.emit(.@"i64x2.bitmask", 0, 0),

        // §9.9 / 9.9-g-6 — int extend ops. Per Wasm SIMD spec
        // (BinarySIMD.md authoritative numbering, NOT the
        // misleading lower.zig comment that misnumbered these
        // 134..137 / 166..169 / 199..202 — verified via
        // `~/Documents/OSS/WebAssembly/simd/proposals/simd/
        // BinarySIMD.md` which gives 0x87..0x8A / 0xA7..0xAA /
        // 0xC7..0xCA).
        //   135..138 i16x8.extend_{low,high}_i8x16_{s,u}
        //   167..170 i32x4.extend_{low,high}_i16x8_{s,u}
        //   199..202 i64x2.extend_{low,high}_i32x4_{s,u}
        135 => try self.emit(.@"i16x8.extend_low_i8x16_s", 0, 0),
        136 => try self.emit(.@"i16x8.extend_high_i8x16_s", 0, 0),
        137 => try self.emit(.@"i16x8.extend_low_i8x16_u", 0, 0),
        138 => try self.emit(.@"i16x8.extend_high_i8x16_u", 0, 0),
        167 => try self.emit(.@"i32x4.extend_low_i16x8_s", 0, 0),
        168 => try self.emit(.@"i32x4.extend_high_i16x8_s", 0, 0),
        169 => try self.emit(.@"i32x4.extend_low_i16x8_u", 0, 0),
        170 => try self.emit(.@"i32x4.extend_high_i16x8_u", 0, 0),
        199 => try self.emit(.@"i64x2.extend_low_i32x4_s", 0, 0),
        200 => try self.emit(.@"i64x2.extend_high_i32x4_s", 0, 0),
        201 => try self.emit(.@"i64x2.extend_low_i32x4_u", 0, 0),
        202 => try self.emit(.@"i64x2.extend_high_i32x4_u", 0, 0),

        // §9.9 / 9.9-g-7 — int shift family. Per spec 0x6B..6D /
        // 0x8B..8D / 0xAB..AD / 0xCB..CD. ARM64 emit currently
        // only handles shl (4 ops); shr_s / shr_u surface as
        // UnsupportedOp at compile until the next chunk lands
        // NEG-then-(U|S)SHL synthesis.
        107 => try self.emit(.@"i8x16.shl", 0, 0),
        108 => try self.emit(.@"i8x16.shr_s", 0, 0),
        109 => try self.emit(.@"i8x16.shr_u", 0, 0),
        139 => try self.emit(.@"i16x8.shl", 0, 0),
        140 => try self.emit(.@"i16x8.shr_s", 0, 0),
        141 => try self.emit(.@"i16x8.shr_u", 0, 0),
        171 => try self.emit(.@"i32x4.shl", 0, 0),
        172 => try self.emit(.@"i32x4.shr_s", 0, 0),
        173 => try self.emit(.@"i32x4.shr_u", 0, 0),
        203 => try self.emit(.@"i64x2.shl", 0, 0),
        204 => try self.emit(.@"i64x2.shr_s", 0, 0),
        205 => try self.emit(.@"i64x2.shr_u", 0, 0),

        else => return Error.NotImplemented,
    }
}

/// SIMD lane-byte op: read 1-byte lane immediate → payload.
fn emitLaneByte(self: *Lowerer, op: ZirOp) Error!void {
    if (self.pos >= self.body.len) return Error.UnexpectedEnd;
    const lane = self.body[self.pos];
    self.pos += 1;
    try self.emit(op, lane, 0);
}

/// memarg+lane op (load_lane / store_lane): payload = offset,
/// extra = lane byte. align is dropped (unused in emit; the
/// validator consumed it for type-stack tracking). Wasm 3.0
/// §5.4.6 memory64 memarg encoding: align uleb bit 6 (0x40)
/// signals a memidx uleb follows; memidx is decoded-and-
/// discarded here since the instantiate path rejects
/// multi-memory > 1 (per ADR-0111 D5) and the lane variant's
/// `extra` field is already consumed by the lane byte. When
/// per-lane multi-memory codegen lands, memidx can route via
/// a side table similar to the scalar MemArgExtra packing.
fn emitMemargLane(self: *Lowerer, op: ZirOp) Error!void {
    const raw_align = try leb128.readUleb128(u32, self.body, &self.pos);
    const has_memidx = (raw_align & 0x40) != 0;
    if (has_memidx) {
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // memidx (discarded; multi-memory rejected at instantiate)
    }
    const offset = try self.readMemargOffset(); // memory64-aware width (D-209)
    if (self.pos >= self.body.len) return Error.UnexpectedEnd;
    const lane = self.body[self.pos];
    self.pos += 1;
    try self.emit(op, offset, lane);
}
