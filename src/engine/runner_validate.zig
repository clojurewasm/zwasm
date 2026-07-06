//! Module-level validation helpers extracted from `runner.zig`
//! per ADR-0064. Self-contained: takes `expr: []const u8` (and
//! optional context) → returns a typed result or a tagged error.
//!
//! These helpers cover Wasm spec const-expression validation
//! (`§3.4.3` global init / `§3.4.6` / `§3.4.7` active offset_expr
//! / `§5.4` instr-encoded reftypes) and minimal const-expression
//! evaluation (i32 / scalar-as-u64 / v128 16-byte payload).
//!
//! Zone 2 (`src/engine/`); imports Zone 0 (`leb128`) and Zone 1
//! (`ir/zir`, `parse/sections`) only.

const std = @import("std");

const leb128 = @import("../support/leb128.zig");
const sections = @import("../parse/sections.zig");
const zir = @import("../ir/zir.zig");

/// Errors originating in this module. Subset of `runner.Error`;
/// merged in via `runner.Error = ... || runner_validate.Error || ...`.
pub const Error = error{
    /// Wasm spec §3.4.3 / §3.3.2: a global section entry's
    /// init expression is not a valid constant expression for
    /// its declared type. Triggers: a non-const opcode, a
    /// `global.get` of a non-imported / non-immutable global,
    /// an init-expr whose result type doesn't match the
    /// declared valtype, ref.func funcidx out of range.
    InvalidGlobalInitExpr,
    /// Const-expression decode failed at the scalar / v128
    /// helper level (mostly: truncated body, unknown opcode,
    /// missing trailing `end`). The runner upgrades this to
    /// `Error.UnsupportedEntrySignature` for setup-time const
    /// init paths.
    UnsupportedEntrySignature,
    /// `evalConstI32Expr` reached a shape it doesn't decode
    /// (anything besides `i32.const N; end`). Active data /
    /// elem offset_expr resolution surfaces this in the
    /// runner.
    UnsupportedConstExpr,
};

/// §9.9 / 9.9-l-1b-d093-d82 — extract the funcidx from a global
/// init-expression of shape `ref.func N; end`. Returns `null`
/// for any other shape (i32.const, ref.null, global.get of
/// import, SIMD v128.const, or a malformed expression). Used by
/// `compileWasm` to seed the declared-funcrefs bitset per Wasm
/// spec §3.4.10. The full validity check (range, trailing
/// `end`, type match) still lives in `validateGlobalInitExpr`;
/// this helper is best-effort extraction only.
pub fn initExprRefFunc(expr: []const u8) ?u32 {
    if (expr.len < 3) return null;
    if (expr[0] != 0xD2) return null;
    var pos: usize = 1;
    const idx = leb128.readUleb128(u32, expr, &pos) catch return null;
    if (pos >= expr.len or expr[pos] != 0x0B) return null;
    return idx;
}

/// Wasm spec §3.4.3 / §3.3.2 const-expression validator for
/// global init exprs AND active elem / data offset_expr (d-78
/// callers pass `.i32` for offset expressions). Naming retained
/// for git blame continuity; semantically a generic
/// `validateConstExpr` helper.
///
/// Returns `Error.InvalidGlobalInitExpr` for any non-const
/// opcode, out-of-range global index, mutable-global reference,
/// type mismatch, or missing trailing `end`.
pub fn validateGlobalInitExpr(
    expr: []const u8,
    want_valtype: zir.ValType,
    num_global_imports: u32,
    imports_opt: ?sections.Imports,
    total_funcs: u32,
) Error!void {
    if (expr.len < 1) return Error.InvalidGlobalInitExpr;
    // Walk the const-expr as a sequence of value-producing ops (Wasm 3.0
    // §3.4.3 extended GC const-exprs are multi-operand: array.new = 2-op,
    // struct.new = N-op). This is the JIT compile gate, not the
    // authoritative validator — the interp validator already checked
    // operand counts + subtyping, so here we only (a) parse each op's
    // immediates byte-correctly to reach the trailing `end`, and (b)
    // track the LAST value-producing op's result type for the want-check
    // (a global init produces exactly one value = the final producer). D-220 / D-223.
    var pos: usize = 0;
    var produced: ?zir.ValType = null;
    while (pos < expr.len) {
        const op = expr[pos];
        pos += 1;
        switch (op) {
            0x0B => { // end — must be the final byte with exactly one value produced
                if (pos != expr.len) return Error.InvalidGlobalInitExpr;
                const pv = produced orelse return Error.InvalidGlobalInitExpr;
                // Numeric / v128 must match exactly. For ref types accept any
                // ref-for-ref (interp validator owns the GC subtype lattice).
                const both_ref = isRefType(pv) and isRefType(want_valtype);
                if (!both_ref and !pv.eql(want_valtype)) return Error.InvalidGlobalInitExpr;
                return;
            },
            0x41 => { // i32.const
                _ = leb128.readSleb128(i32, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                produced = .i32;
            },
            0x42 => { // i64.const
                _ = leb128.readSleb128(i64, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                produced = .i64;
            },
            // Extended-const proposal (Wasm 3.0): i32/i64 add/sub/mul (no
            // immediate). Operand-count + operand-type checks are owned by the
            // interp validator; here we only track the result type for the
            // final want-check (binop result type == the i32/i64 operand type).
            0x6A, 0x6B, 0x6C => produced = .i32,
            0x7C, 0x7D, 0x7E => produced = .i64,
            0x43 => { // f32.const
                if (pos + 4 > expr.len) return Error.InvalidGlobalInitExpr;
                pos += 4;
                produced = .f32;
            },
            0x44 => { // f64.const
                if (pos + 8 > expr.len) return Error.InvalidGlobalInitExpr;
                pos += 8;
                produced = .f64;
            },
            0xD0 => { // ref.null heaptype (s33: negative = abstract, non-negative = concrete typeidx)
                const ht = leb128.readSleb128(i64, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                produced = if (ht >= 0)
                    // D-239 — concrete typed heaptype `(ref.null $typeidx)`
                    // (function-references; e.g. `(global (ref null $t)
                    // (ref.null $t))`). Produce a nullable concrete ref; the
                    // want-check accepts ref-for-ref + the interp validator
                    // owns the precise typeidx subtype lattice.
                    zir.ValType{ .ref = .{ .nullable = true, .heap_type = .{ .concrete = @intCast(ht) } } }
                else switch (ht) {
                    -0x10 => zir.ValType.funcref, // 0x70
                    -0x11 => zir.ValType.externref, // 0x6F
                    // Wasm 3.0 GC abstract heaptypes (D-220).
                    -0x12 => zir.ValType.anyref, // 0x6E
                    -0x13 => zir.ValType.eqref, // 0x6D
                    -0x14 => zir.ValType.i31ref, // 0x6C
                    -0x15 => zir.ValType.structref, // 0x6B
                    -0x16 => zir.ValType.arrayref, // 0x6A
                    -0x0F, -0x0E, -0x0D, -0x17, -0x18 => zir.ValType.anyref, // none/noextern/nofunc/exn/noexn — lenient
                    else => return Error.InvalidGlobalInitExpr,
                };
            },
            0xD2 => { // ref.func funcidx (Wasm 2.0)
                const idx = leb128.readUleb128(u32, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                // Wasm spec §3.4.3: ref.func init-expr funcidx must
                // be in [0, total_funcs). ref_func.2.wasm asserts
                // rejection of `(global funcref (ref.func 7))` when
                // only 2 funcs exist.
                if (idx >= total_funcs) return Error.InvalidGlobalInitExpr;
                produced = .funcref;
            },
            0xFD => { // SIMD prefix — only v128.const (0x0C) is valid in const-expr
                const sub = leb128.readUleb128(u32, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                if (sub != 0x0C) return Error.InvalidGlobalInitExpr;
                if (pos + 16 > expr.len) return Error.InvalidGlobalInitExpr;
                pos += 16;
                produced = .v128;
            },
            0x23 => { // global.get N
                const idx = leb128.readUleb128(u32, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                // Init-expr global.get can only reference imported
                // globals (§3.4.2). Defined-global self/forward
                // references are not constant expressions.
                if (idx >= num_global_imports) return Error.InvalidGlobalInitExpr;
                // The referenced import must be immutable.
                const imports = imports_opt orelse return Error.InvalidGlobalInitExpr;
                var seen: u32 = 0;
                var resolved: ?zir.ValType = null;
                for (imports.items) |imp| {
                    if (imp.kind != .global) continue;
                    if (seen == idx) {
                        const g = imp.payload.global;
                        if (g.mutable) return Error.InvalidGlobalInitExpr;
                        resolved = g.valtype;
                        break;
                    }
                    seen += 1;
                }
                produced = resolved orelse return Error.InvalidGlobalInitExpr;
            },
            0xFB => { // Wasm 3.0 GC prefix const-exprs
                const sub = leb128.readUleb128(u32, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                switch (sub) {
                    0x1C => produced = zir.ValType.i31ref, // ref.i31 (wraps preceding i32)
                    // struct.new / struct.new_default / array.new /
                    // array.new_default — each carries a typeidx and yields
                    // (ref $typeidx). The setup-eval allocates on the gc heap.
                    0x00, 0x01, 0x06, 0x07 => {
                        const ti = leb128.readUleb128(u32, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                        produced = .{ .ref = zir.RefType.conc(ti, false) };
                    },
                    0x08 => { // array.new_fixed $t N — typeidx then element count
                        const ti = leb128.readUleb128(u32, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                        _ = leb128.readUleb128(u32, expr, &pos) catch return Error.InvalidGlobalInitExpr;
                        produced = .{ .ref = zir.RefType.conc(ti, false) };
                    },
                    else => return Error.InvalidGlobalInitExpr,
                }
            },
            else => return Error.InvalidGlobalInitExpr,
        }
    }
    return Error.InvalidGlobalInitExpr; // ran off the end with no trailing `end`
}

fn isRefType(t: zir.ValType) bool {
    return std.meta.activeTag(t) == .ref;
}

/// Context for resolving `global.get N` inside a const-expression
/// during init-time (active data offset, active elem offset,
/// defined-global init). Wasm spec §3.3.3 restricts const-expr
/// `global.get` to imported immutable globals (N <
/// num_global_imports); the importer-side scratch buffer must be
/// pre-populated with the imported values before any caller of
/// the eval helpers below is invoked. When `ctx` is `null`, the
/// helpers behave as before — `global.get` reaches the `else`
/// arm and returns `UnsupportedConstExpr` / `UnsupportedEntrySignature`.
pub const GlobalsCtx = struct {
    offsets: []const u32,
    valtypes: []const zir.ValType,
    buf: []const u8,
    num_imports: u32,
};

/// Decode a scalar const-expression's raw bits as a u64. Used by
/// setupRuntime to initialise defined-global slots from their
/// init_expr. Returns `Error.UnsupportedEntrySignature` for
/// shapes not yet supported (the const-expr corpus consumed by
/// the Wasm 2.0 spec runner is finite — i32/i64/f32/f64.const,
/// ref.null, ref.func, v128.const is handled by the separate
/// `evalConstV128Expr`). `global.get N` for imported immutable
/// globals is supported when `ctx` is non-null per close-plan
/// §6 (j) Step B cohort 1.
pub fn evalConstScalarRaw(expr: []const u8) Error!u64 {
    return evalConstScalarRawCtx(expr, null);
}

pub fn evalConstScalarRawCtx(expr: []const u8, ctx: ?GlobalsCtx) Error!u64 {
    if (expr.len < 2) return Error.UnsupportedEntrySignature;
    var pos: usize = 1;
    const v: u64 = switch (expr[0]) {
        0x41 => blk: { // i32.const
            const n = leb128.readSleb128(i32, expr, &pos) catch return Error.UnsupportedEntrySignature;
            const u: u32 = @bitCast(n);
            break :blk @as(u64, u);
        },
        0x42 => blk: { // i64.const
            const n = leb128.readSleb128(i64, expr, &pos) catch return Error.UnsupportedEntrySignature;
            break :blk @bitCast(n);
        },
        0x43 => blk: { // f32.const
            if (pos + 4 > expr.len) return Error.UnsupportedEntrySignature;
            const bits = std.mem.readInt(u32, expr[pos..][0..4], .little);
            pos += 4;
            break :blk @as(u64, bits);
        },
        0x44 => blk: { // f64.const
            if (pos + 8 > expr.len) return Error.UnsupportedEntrySignature;
            const bits = std.mem.readInt(u64, expr[pos..][0..8], .little);
            pos += 8;
            break :blk bits;
        },
        0xD0 => blk: { // ref.null reftype
            if (pos >= expr.len) return Error.UnsupportedEntrySignature;
            pos += 1;
            break :blk 0;
        },
        0xD2 => blk: { // ref.func funcidx — Wasm 2.0 §5.4.3
            // Encode as the funcidx itself. Runtime-side funcref
            // resolution (turning funcidx into a JIT entry ptr)
            // is Phase 10+ scope; the spec corpus modules that
            // EXPORT a reftype global via `ref.func` are
            // currently only imported by cross-module fixtures
            // that the d-37 unbindable-imports pre-filter
            // SKIPs, so the stored value is never read by any
            // assertion in the Wasm 2.0 corpus.
            const fidx = leb128.readUleb128(u32, expr, &pos) catch return Error.UnsupportedEntrySignature;
            break :blk @as(u64, fidx);
        },
        0x23 => blk: { // global.get N — close-plan §6 (j) Step B cohort 1
            const idx = leb128.readUleb128(u32, expr, &pos) catch return Error.UnsupportedEntrySignature;
            const c = ctx orelse return Error.UnsupportedEntrySignature;
            if (idx >= c.num_imports) return Error.UnsupportedEntrySignature;
            if (idx >= c.offsets.len or idx >= c.valtypes.len) return Error.UnsupportedEntrySignature;
            // v128 globals are not scalar — caller must dispatch v128 init
            // via `evalConstV128Expr` instead. Reject early.
            if (c.valtypes[idx] == .v128) return Error.UnsupportedEntrySignature;
            // Post-ADR-0110 widen: every slot occupies uniform 16 bytes;
            // scalar values live in the low 8 bytes (little-endian).
            const off = c.offsets[idx];
            if (off + 8 > c.buf.len) return Error.UnsupportedEntrySignature;
            break :blk std.mem.readInt(u64, c.buf[off..][0..8], .little);
        },
        else => return Error.UnsupportedEntrySignature,
    };
    if (pos >= expr.len or expr[pos] != 0x0B) return Error.UnsupportedEntrySignature;
    return v;
}

/// Decode a `v128.const` (0xFD 0x0C) terminated init-expression
/// and return the 16-byte little-endian-encoded constant.
pub fn evalConstV128Expr(expr: []const u8) Error!([16]u8) {
    // (v128.const v128) (end) — 0xFD 0x0C <16 bytes> 0x0B
    if (expr.len < 2 + 16 + 1) return Error.UnsupportedEntrySignature;
    if (expr[0] != 0xFD or expr[1] != 0x0C) return Error.UnsupportedEntrySignature;
    if (expr[18] != 0x0B) return Error.UnsupportedEntrySignature;
    var out: [16]u8 = undefined;
    @memcpy(&out, expr[2..][0..16]);
    return out;
}

/// Evaluate a Wasm const-expression that resolves to an i32.
/// Active data-segment offsets reach this path; v0.1.0's only
/// supported shape is `i32.const N; end` (3+ bytes: opcode 0x41,
/// sleb128 N, opcode 0x0B). Mirrors the shape in
/// `runtime/instance/instantiate.zig:evalConstI32Expr` but stays
/// JIT-runner-local to avoid pulling instance/ into engine/.
pub fn evalConstI32Expr(expr: []const u8) Error!i32 {
    return evalConstI32ExprCtx(expr, null);
}

/// Context-aware variant per close-plan §6 (j) Step B cohort 1.
/// Accepts the `global.get N` shape (opcode 0x23) for imported
/// immutable globals when `ctx` is non-null. The importer-side
/// `ctx.buf` must be pre-populated with each imported global's
/// resolved value (see spec runner's
/// `applyImportedGlobalsFromRegistered`).
pub fn evalConstI32ExprCtx(expr: []const u8, ctx: ?GlobalsCtx) Error!i32 {
    if (expr.len < 2) return Error.UnsupportedConstExpr;
    var pos: usize = 1;
    const v: i32 = switch (expr[0]) {
        0x41 => blk: { // i32.const
            const n = leb128.readSleb128(i32, expr, &pos) catch return Error.UnsupportedConstExpr;
            break :blk n;
        },
        0x23 => blk: { // global.get N
            const idx = leb128.readUleb128(u32, expr, &pos) catch return Error.UnsupportedConstExpr;
            const c = ctx orelse return Error.UnsupportedConstExpr;
            if (idx >= c.num_imports) return Error.UnsupportedConstExpr;
            if (idx >= c.offsets.len or idx >= c.valtypes.len) return Error.UnsupportedConstExpr;
            if (c.valtypes[idx] != .i32) return Error.UnsupportedConstExpr;
            const off = c.offsets[idx];
            if (off + 4 > c.buf.len) return Error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u32, c.buf[off..][0..4], .little);
            break :blk @bitCast(bits);
        },
        else => return Error.UnsupportedConstExpr,
    };
    if (pos >= expr.len or expr[pos] != 0x0B) return Error.UnsupportedConstExpr;
    return v;
}

/// Context-aware u64 offset evaluator (D-475 table64). Mirrors
/// `evalConstI32ExprCtx`'s single-op shape but returns u64: accepts
/// `i32.const` (zero-extended), `i64.const` (table64 / memory64), and
/// `global.get N` of an imported immutable i32 (zero-extended) or i64
/// global when `ctx` is non-null.
pub fn evalConstOffsetU64Ctx(expr: []const u8, ctx: ?GlobalsCtx) Error!u64 {
    if (expr.len < 2) return Error.UnsupportedConstExpr;
    var pos: usize = 1;
    const v: u64 = switch (expr[0]) {
        0x41 => blk: { // i32.const — zero-extend
            const n = leb128.readSleb128(i32, expr, &pos) catch return Error.UnsupportedConstExpr;
            break :blk @as(u32, @bitCast(n));
        },
        0x42 => blk: { // i64.const (table64 / memory64)
            const n = leb128.readSleb128(i64, expr, &pos) catch return Error.UnsupportedConstExpr;
            break :blk @bitCast(n);
        },
        0x23 => blk: { // global.get N (imported i32 / i64)
            const idx = leb128.readUleb128(u32, expr, &pos) catch return Error.UnsupportedConstExpr;
            const c = ctx orelse return Error.UnsupportedConstExpr;
            if (idx >= c.num_imports) return Error.UnsupportedConstExpr;
            if (idx >= c.offsets.len or idx >= c.valtypes.len) return Error.UnsupportedConstExpr;
            const off = c.offsets[idx];
            switch (c.valtypes[idx]) {
                .i32 => {
                    if (off + 4 > c.buf.len) return Error.UnsupportedConstExpr;
                    break :blk std.mem.readInt(u32, c.buf[off..][0..4], .little);
                },
                .i64 => {
                    if (off + 8 > c.buf.len) return Error.UnsupportedConstExpr;
                    break :blk std.mem.readInt(u64, c.buf[off..][0..8], .little);
                },
                else => return Error.UnsupportedConstExpr,
            }
        },
        else => return Error.UnsupportedConstExpr,
    };
    if (pos >= expr.len or expr[pos] != 0x0B) return Error.UnsupportedConstExpr;
    return v;
}

/// Evaluate an active-segment offset const-expr to a u64. Accepts
/// `i32.const` (mem32 / table — zero-extended) and `i64.const`
/// (memory64), each followed by `end`. An offset is unsigned; the
/// caller's bounds check rejects out-of-range values. D-219.
pub fn evalConstOffsetU64(expr: []const u8) Error!u64 {
    // Small const-expr stack machine: i32/i64.const + the extended-const
    // proposal's i32/i64 add/sub/mul (Wasm 3.0). A computed active data/element
    // offset like `(i32.add (i32.const 4) (i32.const 6))` is valid. i32 values
    // are kept zero-extended in the u64 slot; i32 arithmetic wraps at 32 bits.
    var stack: [16]u64 = undefined;
    var sp: usize = 0;
    var pos: usize = 0;
    while (pos < expr.len) {
        const op = expr[pos];
        pos += 1;
        if (op == 0x0B) break;
        switch (op) {
            0x41 => { // i32.const
                const n = leb128.readSleb128(i32, expr, &pos) catch return Error.UnsupportedConstExpr;
                if (sp >= stack.len) return Error.UnsupportedConstExpr;
                stack[sp] = @as(u32, @bitCast(n));
                sp += 1;
            },
            0x42 => { // i64.const (memory64)
                const n = leb128.readSleb128(i64, expr, &pos) catch return Error.UnsupportedConstExpr;
                if (sp >= stack.len) return Error.UnsupportedConstExpr;
                stack[sp] = @bitCast(n);
                sp += 1;
            },
            0x6A, 0x6B, 0x6C => { // i32 add/sub/mul — 32-bit wrapping
                if (sp < 2) return Error.UnsupportedConstExpr;
                sp -= 1;
                const a: u32 = @truncate(stack[sp - 1]);
                const b: u32 = @truncate(stack[sp]);
                stack[sp - 1] = switch (op) {
                    0x6A => a +% b,
                    0x6B => a -% b,
                    else => a *% b,
                };
            },
            0x7C, 0x7D, 0x7E => { // i64 add/sub/mul — 64-bit wrapping
                if (sp < 2) return Error.UnsupportedConstExpr;
                sp -= 1;
                const a = stack[sp - 1];
                const b = stack[sp];
                stack[sp - 1] = switch (op) {
                    0x7C => a +% b,
                    0x7D => a -% b,
                    else => a *% b,
                };
            },
            else => return Error.UnsupportedConstExpr,
        }
    }
    if (sp != 1) return Error.UnsupportedConstExpr;
    return stack[0];
}
