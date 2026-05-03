//! Tests for `src/frontend/validator.zig` (§9.5 / 5.2 carve-out
//! to keep the validator under §A2's 1000-line soft cap while
//! the per-feature handler split per ROADMAP §A12 stays queued
//! for §9.1 / 1.7's dispatch-table migration).
//!
//! Tests reach the validator only through its public API
//! (`validateFunction`, `Error`, `GlobalEntry`) — no private
//! `Validator` methods are touched, so no `pub`-leak was needed
//! for the carve.

const std = @import("std");

const validator = @import("validator.zig");
const zir = @import("../ir/zir.zig");

const validateFunction = validator.validateFunction;
const Error = validator.Error;
const GlobalEntry = validator.GlobalEntry;
const ValType = zir.ValType;
const FuncType = zir.FuncType;

const testing = std.testing;

const empty_sig: FuncType = .{ .params = &.{}, .results = &.{} };
const i32_arr = [_]ValType{.i32};
const i64_arr = [_]ValType{.i64};
const i32_result_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };
const i64_result_sig: FuncType = .{ .params = &.{}, .results = &i64_arr };

test "validate: empty function (() -> ()) with bare `end`" {
    try validateFunction(empty_sig, &.{}, &[_]u8{0x0B}, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: i32.const 0 + drop + end on () -> ()" {
    // 0x41 0x00  -> i32.const 0
    // 0x1A       -> drop
    // 0x0B       -> end
    try validateFunction(empty_sig, &.{}, &[_]u8{ 0x41, 0x00, 0x1A, 0x0B }, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: i32.const + end produces declared i32 result" {
    try validateFunction(i32_result_sig, &.{}, &[_]u8{ 0x41, 0x07, 0x0B }, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: empty body for () -> i32 fails arity" {
    const r = validateFunction(i32_result_sig, &.{}, &[_]u8{0x0B}, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.ArityMismatch, r);
}

test "validate: type mismatch — i64 where i32 expected" {
    // i64.const 1 ; i32.add  -> type mismatch (i32.add expects i32 i32)
    const body = [_]u8{ 0x42, 0x01, 0x42, 0x02, 0x6A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: nested block with i32 result" {
    // (block (result i32) i32.const 1) end
    // 0x02 0x7F -> block i32
    //   0x41 0x01 -> i32.const 1
    // 0x0B -> end (block)
    // 0x0B -> end (function frame)
    try validateFunction(i32_result_sig, &.{}, &[_]u8{ 0x02, 0x7F, 0x41, 0x01, 0x0B, 0x0B }, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: nested block leaving wrong type at end fails" {
    // (block (result i32) i64.const 1) end -> i32.const? — fails
    const body = [_]u8{ 0x02, 0x7F, 0x42, 0x01, 0x0B, 0x0B };
    const r = validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: unreachable polymorphism — () -> i32 satisfied by `unreachable`" {
    // unreachable; end
    try validateFunction(i32_result_sig, &.{}, &[_]u8{ 0x00, 0x0B }, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: br to outer block consumes labeled type" {
    // outer block (result i32) { i32.const 5 ; br 0 } end
    // function sig () -> i32, expected to validate.
    const body = [_]u8{
        0x02, 0x7F, // block i32
        0x41, 0x05, // i32.const 5
        0x0C, 0x00, // br 0 (target = innermost block)
        0x0B, // end block
        0x0B, // end function
    };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: br to invalid depth fails" {
    // br 5 with only function frame -> InvalidBranchDepth
    const body = [_]u8{ 0x0C, 0x05, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.InvalidBranchDepth, r);
}

test "validate: local.get / local.set — params and locals indexed correctly" {
    // params: (i32, i64)  locals: (f32)
    // local.get 0 (i32) -> drop ; local.get 1 (i64) -> drop ;
    // local.get 2 (f32) -> drop ; end
    const params = [_]ValType{ .i32, .i64 };
    const sig: FuncType = .{ .params = &params, .results = &.{} };
    const locals = [_]ValType{.f32};
    const body = [_]u8{
        0x20, 0x00, 0x1A,
        0x20, 0x01, 0x1A,
        0x20, 0x02, 0x1A,
        0x0B,
    };
    try validateFunction(sig, &locals, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: local.get out of range fails" {
    const body = [_]u8{ 0x20, 0x05, 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.InvalidLocalIndex, r);
}

test "validate: local.set type mismatch fails" {
    // local.set 0 expects i32; we push i64.
    const params = [_]ValType{.i32};
    const sig: FuncType = .{ .params = &params, .results = &.{} };
    const body = [_]u8{ 0x42, 0x07, 0x21, 0x00, 0x0B };
    const r = validateFunction(sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: if/else with matching i32 results" {
    // i32.const 1 ; if (result i32) i32.const 10 else i32.const 20 end ; end-fn
    const body = [_]u8{
        0x41, 0x01, // i32.const 1
        0x04, 0x7F, // if i32
        0x41, 0x0A,
        0x05, // else
        0x41, 0x14,
        0x0B, // end if
        0x0B, // end fn
    };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: if/else with mismatched branch types fails" {
    // if (result i32) i32.const 1 else i64.const 2 end -> mismatch on else end
    const body = [_]u8{
        0x41, 0x01,
        0x04, 0x7F,
        0x41, 0x0A,
        0x05,
        0x42, 0x14,
        0x0B,
        0x0B,
    };
    const r = validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: unclosed frame (truncated body) fails" {
    // block (no end)
    const body = [_]u8{ 0x02, 0x40, 0x0B }; // opens block, ends block, but not function frame
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.UnexpectedEnd, r);
}

test "validate: trailing bytes after function `end` are rejected" {
    const body = [_]u8{ 0x0B, 0x00 };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.TrailingBytes, r);
}

test "validate: stack underflow on drop with empty operand stack" {
    const body = [_]u8{ 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackUnderflow, r);
}

test "validate: i32.add binop — correct typing" {
    const body = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x6A, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: i32.eqz unary test — pops i32, pushes i32" {
    const body = [_]u8{ 0x41, 0x01, 0x45, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: return polymorphism" {
    // i32.const 7 ; return ; end
    const body = [_]u8{ 0x41, 0x07, 0x0F, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: NotImplemented for unknown opcode (e.g. 0xFF)" {
    const body = [_]u8{ 0xFF, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.NotImplemented, r);
}

test "validate: i32.extend8_s — pops i32, pushes i32" {
    // i32.const 0x7F ; i32.extend8_s ; end
    const body = [_]u8{ 0x41, 0x7F, 0xC0, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: i32.extend16_s — pops i32, pushes i32" {
    const body = [_]u8{ 0x41, 0x7F, 0xC1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: i64.extend8_s — pops i64, pushes i64" {
    // i64.const 0x7F ; i64.extend8_s ; end
    const body = [_]u8{ 0x42, 0x7F, 0xC2, 0x0B };
    try validateFunction(i64_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: i64.extend16_s — pops i64, pushes i64" {
    const body = [_]u8{ 0x42, 0x7F, 0xC3, 0x0B };
    try validateFunction(i64_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: i64.extend32_s — pops i64, pushes i64" {
    const body = [_]u8{ 0x42, 0x7F, 0xC4, 0x0B };
    try validateFunction(i64_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: i32.trunc_sat_f32_s (0xFC 00) — pops f32, pushes i32" {
    // f32.const 0.0 ; i32.trunc_sat_f32_s ; end
    const body = [_]u8{ 0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: i64.trunc_sat_f64_u (0xFC 07) — pops f64, pushes i64" {
    // f64.const 0.0 ; i64.trunc_sat_f64_u ; end
    const body = [_]u8{
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xFC, 0x07,
        0x0B,
    };
    try validateFunction(i64_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: multivalue block via s33 typeidx — empty params, two i32 results" {
    // module_types[0] = ([] -> [i32, i32])
    const empty_arr = [_]ValType{};
    const i32_pair = [_]ValType{ .i32, .i32 };
    const types = [_]FuncType{.{ .params = &empty_arr, .results = &i32_pair }};
    // function: () -> () body =
    //   block (typeidx 0) ; i32.const 1 ; i32.const 2 ; end ; drop ; drop ; end
    // The block pushes two i32, consumed by two drops outside.
    const body = [_]u8{
        0x02, 0x00, // block (typeidx 0; sleb 0 = 0x00)
        0x41, 0x01, // i32.const 1
        0x41, 0x02, // i32.const 2
        0x0B, // end (block)
        0x1A, 0x1A, // drop, drop
        0x0B, // end (function)
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &types, 0, &.{}, 0);
}

test "validate: multivalue block typeidx with non-empty params → BadBlockType" {
    // module_types[0] = ([i32] -> [i32]) — multi-param case deferred
    const i32_arr_local = [_]ValType{.i32};
    const types = [_]FuncType{.{ .params = &i32_arr_local, .results = &i32_arr_local }};
    const body = [_]u8{
        0x41, 0x07, // i32.const 7 (push the param)
        0x02, 0x00, // block (typeidx 0)
        0x0B, // end (block)
        0x0B, // end (function)
    };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &types, 0, &.{}, 0);
    try testing.expectError(Error.BadBlockType, r);
}

test "validate: memory.copy (0xFC 10) — pops three i32" {
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; memory.copy ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0A, 0x00, 0x00,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: memory.fill (0xFC 11) — pops three i32" {
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0B, 0x00,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: memory.copy with non-zero reserved byte → BadBlockType" {
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0A, 0x01, 0x00,
        0x0B,
    };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.BadBlockType, r);
}

test "validate: memory.init (0xFC 8) with valid dataidx" {
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; memory.init 0 ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x08, 0x00, 0x00,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 1, &.{}, 0);
}

test "validate: memory.init dataidx out of range → InvalidFuncIndex" {
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x08, 0x05, 0x00,
        0x0B,
    };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 1, &.{}, 0);
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: data.drop (0xFC 9) with valid dataidx" {
    // data.drop 0 ; end
    const body = [_]u8{ 0xFC, 0x09, 0x00, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 1, &.{}, 0);
}

test "validate: data.drop dataidx out of range → InvalidFuncIndex" {
    const body = [_]u8{ 0xFC, 0x09, 0x03, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 1, &.{}, 0);
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: ref.null funcref pushes funcref; ref.is_null consumes + pushes i32" {
    // ref.null funcref ; ref.is_null ; end
    const body = [_]u8{ 0xD0, 0x70, 0xD1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.null externref pushes externref; drop ; end" {
    const body = [_]u8{ 0xD0, 0x6F, 0x1A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.null with bad reftype byte → BadValType" {
    const body = [_]u8{ 0xD0, 0x55, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.BadValType, r);
}

test "validate: ref.func with valid funcidx pushes funcref" {
    const types = [_]FuncType{empty_sig};
    // ref.func 0 ; ref.is_null ; end
    const body = [_]u8{ 0xD2, 0x00, 0xD1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &types, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.func with out-of-range funcidx → InvalidFuncIndex" {
    const body = [_]u8{ 0xD2, 0x05, 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: select_typed (0x1C) — i32 result, two i32 vals + cond" {
    // i32.const 1 ; i32.const 2 ; i32.const 0 ; select_typed [i32] ; drop ; end
    const body = [_]u8{
        0x41, 0x01,
        0x41, 0x02,
        0x41, 0x00,
        0x1C, 0x01, 0x7F,
        0x1A,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: select_typed with funcref result" {
    // ref.null funcref ; ref.null funcref ; i32.const 0 ; select_typed [funcref] ; drop ; end
    const body = [_]u8{
        0xD0, 0x70,
        0xD0, 0x70,
        0x41, 0x00,
        0x1C, 0x01, 0x70,
        0x1A,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: select_typed with count != 1 → InvalidOpcode" {
    const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0x1C, 0x02, 0x7F, 0x7F, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.InvalidOpcode, r);
}

test "validate: select_typed type mismatch → StackTypeMismatch" {
    // i64.const 0 ; i32.const 0 ; i32.const 0 ; select_typed [i32] ...
    const body = [_]u8{ 0x42, 0x00, 0x41, 0x00, 0x41, 0x00, 0x1C, 0x01, 0x7F, 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: ref.is_null on i32 → StackTypeMismatch" {
    const body = [_]u8{ 0x41, 0x00, 0xD1, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: table.get pops i32 + pushes elem_type (funcref)" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // i32.const 0 ; table.get 0 ; drop ; end
    const body = [_]u8{ 0x41, 0x00, 0x25, 0x00, 0x1A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables, 0);
}

test "validate: table.set pops elem_type then i32 idx" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // i32.const 0 ; ref.null funcref ; table.set 0 ; end
    const body = [_]u8{ 0x41, 0x00, 0xD0, 0x70, 0x26, 0x00, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables, 0);
}

test "validate: table.size pushes i32" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // table.size 0 ; end
    const body = [_]u8{ 0xFC, 0x10, 0x00, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables, 0);
}

test "validate: table.get with out-of-range tableidx → InvalidFuncIndex" {
    const body = [_]u8{ 0x41, 0x00, 0x25, 0x05, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: table.grow pops i32 + reftype, pushes i32" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // ref.null funcref ; i32.const 1 ; table.grow 0 ; drop ; end
    const body = [_]u8{ 0xD0, 0x70, 0x41, 0x01, 0xFC, 0x0F, 0x00, 0x1A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables, 0);
}

test "validate: table.fill pops i32 + reftype + i32" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // i32.const 0 ; ref.null funcref ; i32.const 0 ; table.fill 0 ; end
    const body = [_]u8{ 0x41, 0x00, 0xD0, 0x70, 0x41, 0x00, 0xFC, 0x11, 0x00, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables, 0);
}

test "validate: table.copy pops three i32; both tables same elem_type" {
    const tables = [_]zir.TableEntry{
        .{ .elem_type = .funcref, .min = 0 },
        .{ .elem_type = .funcref, .min = 0 },
    };
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; table.copy 0 1 ; end
    const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xFC, 0x0E, 0x00, 0x01, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables, 0);
}

test "validate: table.copy with mismatched elem types → StackTypeMismatch" {
    const tables = [_]zir.TableEntry{
        .{ .elem_type = .funcref, .min = 0 },
        .{ .elem_type = .externref, .min = 0 },
    };
    const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xFC, 0x0E, 0x00, 0x01, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: table.init pops three i32; bounds-checks elemidx+tableidx" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xFC, 0x0C, 0x00, 0x00, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables, 1);
}

test "validate: table.init with elemidx out of range → InvalidFuncIndex" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xFC, 0x0C, 0x05, 0x00, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables, 1);
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: elem.drop validates elemidx" {
    const body = [_]u8{ 0xFC, 0x0D, 0x00, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 1);
}

test "validate: elem.drop with out-of-range idx → InvalidFuncIndex" {
    const body = [_]u8{ 0xFC, 0x0D, 0x05, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 1);
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: 0xFC unknown sub-opcode → NotImplemented" {
    // f32.const 0.0 ; 0xFC 0xFF ... ; end — sub-op 0xFF is past
    // chunk-2 scope. Should return NotImplemented (chunks 4+ wire
    // the rest).
    const body = [_]u8{ 0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0xFF, 0x01, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.NotImplemented, r);
}
