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

const sections = @import("../parse/sections.zig");

const validateFunction = validator.validateFunction;
const validateFunctionWithTags = validator.validateFunctionWithTags;
const validateFunctionWithGcTypes = validator.validateFunctionWithGcTypes;
const Error = validator.Error;
const GlobalEntry = validator.GlobalEntry;
const ValType = zir.ValType;
const FuncType = zir.FuncType;
const TagEntry = sections.TagEntry;

const testing = std.testing;

const empty_sig: FuncType = .{ .params = &.{}, .results = &.{} };
const i32_arr = [_]ValType{.i32};
const i64_arr = [_]ValType{.i64};
const i32_result_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };
const i64_result_sig: FuncType = .{ .params = &.{}, .results = &i64_arr };
const exnref_arr = [_]ValType{ValType.exnref};
const exnref_result_sig: FuncType = .{ .params = &.{}, .results = &exnref_arr };

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

test "validate: ref.i31 result is non-null (ref i31), not nullable i31ref (10.G cycle 129)" {
    // ref.i31 : [i32] -> [(ref i31)] non-null. A non-null (ref i31)
    // result sig must accept it (the old nullable .i31ref push failed
    // this with StackTypeMismatch — e.g. gc/i31.0's global.set).
    const res = [_]ValType{.{ .ref = zir.RefType.abs(.i31, false) }};
    const sig: FuncType = .{ .params = &.{}, .results = &res };
    // i32.const 0; ref.i31; end
    try validateFunction(sig, &.{}, &[_]u8{ 0x41, 0x00, 0xFB, 0x1C, 0x0B }, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.i31 result satisfies anyref via GC heap lattice (10.G cycle 134)" {
    // (ref i31) <: anyref (i31 <: eq <: any). A func returning anyref
    // must accept `i32.const; ref.i31` — the abstract-head subtype check
    // (was identity-only → StackTypeMismatch; gc/i31.5 anyref global,
    // i31.6 anyref table).
    const res = [_]ValType{ValType.anyref};
    const sig: FuncType = .{ .params = &.{}, .results = &res };
    try validateFunction(sig, &.{}, &[_]u8{ 0x41, 0x00, 0xFB, 0x1C, 0x0B }, &.{}, &.{}, &.{}, 0, &.{}, 0);
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

test "validate (block): typed-ref blocktype (ref null func) via 0x63 0x70 accepted" {
    // function-references §5.3.4 + blocktype §5.4.1: `0x63 ht` =
    // `(ref null ht)`. `(block (result (ref null func)) ref.null
    // func) drop` — empty function. Pre-fix `readBlockType` reads
    // the 0x63 prefix as SLEB -29 and rejects it as BadBlockType.
    //   0x02 0x63 0x70 — block (result (ref null func))
    //   0xD0 0x70      — ref.null func  (pushes (ref null func))
    //   0x0B           — end block (leaves (ref null func) on stack)
    //   0x1A           — drop
    //   0x0B           — end function
    const body = [_]u8{ 0x02, 0x63, 0x70, 0xD0, 0x70, 0x0B, 0x1A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (block): abstract GC reftype blocktype (structref via 0x6B) accepted (10.G cycle 144)" {
    // Wasm 3.0 GC §5.3.4 + blocktype §5.4.1: the single-byte abstract
    // reftype shorthand `0x6B` (= `(ref null struct)` = structref) is a
    // valid blocktype. Pre-fix `readBlockType` reads it as SLEB -21 and
    // rejects it as BadBlockType (the gc/ref_test, ref_cast, br_on_cast
    // fixtures open `(block (result structref) ...)`).
    //   0x02 0x6B — block (result structref)
    //   0xD0 0x6B — ref.null struct  (pushes (ref null struct))
    //   0x0B      — end block
    //   0x1A      — drop
    //   0x0B      — end function
    const body = [_]u8{ 0x02, 0x6B, 0xD0, 0x6B, 0x0B, 0x1A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (block): typed-ref blocktype with out-of-range concrete index rejected" {
    // function-references ref.9 / ref.10 (assert_invalid): `block
    // (result (ref 1))` but the module declares only type 0, so the
    // concrete heap-type index 1 is out of range → BadBlockType.
    //   0x02 0x64 0x01 — block (result (ref 1))
    //   0x00           — unreachable
    //   0x0B 0x1A 0x0B — end block ; drop ; end function
    const one_type = [_]FuncType{empty_sig};
    const body = [_]u8{ 0x02, 0x64, 0x01, 0x00, 0x0B, 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &one_type, 0, &.{}, 0);
    try testing.expectError(Error.BadBlockType, r);
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
        0x41,
        0x14,
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
        0x05, 0x42,
        0x14, 0x0B,
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
        0xFC, 0x07, 0x0B,
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

test "validate: multivalue block typeidx with single-param/single-result validates (D-035 chunk-d035-a)" {
    // module_types[0] = ([i32] -> [i32])
    const i32_arr_local = [_]ValType{.i32};
    const types = [_]FuncType{.{ .params = &i32_arr_local, .results = &i32_arr_local }};
    const body = [_]u8{
        0x41, 0x07, // i32.const 7 (push the param)
        0x02, 0x00, // block typeidx=0 — pops the i32 param, body's stack starts with i32
        0x0B, // end (block) — verifies one i32 is on the body stack
        0x1A, // drop (consume the i32 the block left so function-end sees an empty stack)
        0x0B, // end (function)
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &types, 0, &.{}, 0);
}

test "validate: multivalue block missing param on entry stack → StackUnderflow" {
    // module_types[0] = ([i32] -> [i32]) — but the outer stack is empty.
    const i32_arr_local = [_]ValType{.i32};
    const types = [_]FuncType{.{ .params = &i32_arr_local, .results = &i32_arr_local }};
    const body = [_]u8{
        0x02, 0x00, // block typeidx=0 — needs an i32 on the outer stack
        0x0B, 0x0B,
    };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &types, 0, &.{}, 0);
    try testing.expectError(Error.StackUnderflow, r);
}

test "validate: multivalue loop with params — `br 0` re-transfers params (label type = start)" {
    // module_types[0] = ([i32] -> []) — loop with one i32 param, no result.
    // Body inside loop: drop the param, push i32.const 0, br 0 — must
    // re-transfer the i32 to the loop label.
    const i32_arr_local = [_]ValType{.i32};
    const types = [_]FuncType{.{ .params = &i32_arr_local, .results = &.{} }};
    const body = [_]u8{
        0x41, 0x07, // i32.const 7 (push the param)
        0x03, 0x00, // loop typeidx=0
        0x1A, // drop the loaded i32
        0x41, 0x00, // i32.const 0 (param re-supply)
        0x0C, 0x00, // br 0 — pops the i32 (loop label = params)
        0x0B, // end (loop, unreachable after br)
        0x0B, // end (function)
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &types, 0, &.{}, 0);
}

test "validate: memory.copy (0xFC 10) — pops three i32" {
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; memory.copy ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0A, 0x00, 0x00, 0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: memory.fill (0xFC 11) — pops three i32" {
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0B, 0x00, 0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: memory.copy memidx out of range → UnknownMemory (10.M cycle 67)" {
    // Pre-cycle-67: non-zero reserved byte rejected with BadBlockType
    // (single-memory enforcement). Post-cycle-67: memidx is a real
    // LEB and rejects with UnknownMemory when out-of-range. The
    // test bakes `memory.copy dst=1 src=0` against a single-memory
    // module — dst=1 is out of range.
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0A, 0x01, 0x00, 0x0B,
    };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.UnknownMemory, r);
}

test "validate: memory.init (0xFC 8) with valid dataidx" {
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; memory.init 0 ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x08, 0x00, 0x00, 0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 1, &.{}, 0);
}

test "validate: memory.init dataidx out of range → InvalidFuncIndex" {
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x08, 0x05, 0x00, 0x0B,
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

test "validate: ref.as_non_null (0xD4) narrows (ref null func) to non-null" {
    // function-references §3.3.8.5: ref.as_non_null pops a reftype,
    // pushes the non-null narrowing (traps at runtime on null). Opcode
    // is 0xD4 (0xD3 is GC ref.eq). Pre-fix the dispatch mapped 0xD3 →
    // opRefAsNonNull, leaving the real 0xD4 byte unhandled
    // (NotImplemented) — ref_as_non_null.0 / .2 ParseFailed.
    //   0xD0 0x70 — ref.null func  (pushes (ref null func))
    //   0xD4      — ref.as_non_null (→ (ref func))
    //   0x1A      — drop
    //   0x0B      — end
    const body = [_]u8{ 0xD0, 0x70, 0xD4, 0x1A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.func yields typed (ref N) satisfying a typed-ref param (ADR-0123 D4)" {
    // ADR-0123 D4: `ref.func N` pushes the non-null typed ref (ref to
    // func N's type index), not abstract funcref, so it flows into a
    // `call` whose param is `(ref 0)`. Pre-fix opRefFunc pushed
    // `.funcref` → StackTypeMismatch (the br_on_*.0/.2 entry-func gate).
    //   func 0 : type 0 = () -> i32
    //   func 1 : type 1 = ((ref 0)) -> ()
    //   under test (() -> ()): ref.func 0 ; call 1 ; end
    const ref0: ValType = .{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = 0 } } };
    const t0: FuncType = .{ .params = &.{}, .results = &i32_arr };
    const t1_params = [_]ValType{ref0};
    const t1: FuncType = .{ .params = &t1_params, .results = &.{} };
    const mod_types = [_]FuncType{ t0, t1 };
    const fti = [_]u32{ 0, 1 };
    // ref.func 0 (0xD2 0x00) ; call 1 (0x10 0x01) ; end (0x0B)
    const body = [_]u8{ 0xD2, 0x00, 0x10, 0x01, 0x0B };
    try validator.validateFunctionWithMemIdxAndTags(
        empty_sig,
        &.{},
        &body,
        &mod_types,
        &.{},
        &mod_types,
        0,
        &.{},
        0,
        1,
        .i32,
        &.{},
        &.{},
        &fti,
        &.{}, // module_types_kinds
        &.{}, // struct_defs
        &.{}, // array_defs
    );
}

test "validate: typed (ref N) from ref.func is a subtype of funcref (global.set)" {
    // ADR-0123 subtype: (ref $sig) <: funcref, so a typed ref.func
    // result stores into a `(mut funcref)` global (ref_func.1 pattern).
    //   func 0 : type 0 = () -> () ; global 0 : (mut funcref)
    //   under test (() -> ()): ref.func 0 ; global.set 0 ; end
    const t0: FuncType = .{ .params = &.{}, .results = &.{} };
    const mod_types = [_]FuncType{t0};
    const fti = [_]u32{0};
    const globals = [_]GlobalEntry{.{ .valtype = .funcref, .mutable = true }};
    // ref.func 0 (0xD2 0x00) ; global.set 0 (0x24 0x00) ; end (0x0B)
    const body = [_]u8{ 0xD2, 0x00, 0x24, 0x00, 0x0B };
    try validator.validateFunctionWithMemIdxAndTags(
        empty_sig,
        &.{},
        &body,
        &mod_types,
        &globals,
        &mod_types,
        0,
        &.{},
        0,
        1,
        .i32,
        &.{},
        &.{},
        &fti,
        &.{}, // module_types_kinds
        &.{}, // struct_defs
        &.{}, // array_defs
    );
}

test "validate: ref.as_non_null in unreachable code stays polymorphic (satisfies typed-ref call)" {
    // ref_as_non_null.0 func 6: `unreachable; ref.as_non_null; call 0`
    // where call 0's param is (ref 0). After `unreachable` the stack is
    // polymorphic; ref.as_non_null must push .bot (not a concrete
    // funcref), else funcref mismatches the (ref 0) param.
    //   func 0 : type 0 = ((ref 0)) -> i32  (call target)
    const ref0: ValType = .{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = 0 } } };
    const t0_params = [_]ValType{ref0};
    const t0: FuncType = .{ .params = &t0_params, .results = &i32_arr };
    const mod_types = [_]FuncType{t0};
    // unreachable (0x00) ; ref.as_non_null (0xD4) ; call 0 (0x10 0x00) ; end
    const body = [_]u8{ 0x00, 0xD4, 0x10, 0x00, 0x0B };
    try validator.validateFunctionWithMemIdxAndTags(
        i32_result_sig,
        &.{},
        &body,
        &mod_types,
        &.{},
        &mod_types,
        0,
        &.{},
        0,
        1,
        .i32,
        &.{},
        &.{},
        &.{},
        &.{}, // module_types_kinds
        &.{}, // struct_defs
        &.{}, // array_defs
    );
}

test "validate: br_on_non_null to a concrete (ref N) label in unreachable code" {
    // br_on_non_null.0 func 6: `block (result (ref 0)); unreachable;
    // br_on_non_null 0; ...`. After `unreachable` the popped ref is
    // polymorphic and must unify with the label's concrete (ref 0)
    // type — the ref↔label subtype check is skipped, not failed.
    const mod_types = [_]FuncType{.{ .params = &.{}, .results = &.{} }};
    //   0x02 0x64 0x00  block (result (ref 0))
    //   0x00            unreachable
    //   0xD6 0x00       br_on_non_null 0
    //   0x00            unreachable (fill block result polymorphically)
    //   0x0B            end block (leaves (ref 0))
    //   0x1A            drop
    //   0x0B            end function
    const body = [_]u8{ 0x02, 0x64, 0x00, 0x00, 0xD6, 0x00, 0x00, 0x0B, 0x1A, 0x0B };
    try validator.validateFunctionWithMemIdxAndTags(
        empty_sig,
        &.{},
        &body,
        &mod_types,
        &.{},
        &mod_types,
        0,
        &.{},
        0,
        1,
        .i32,
        &.{},
        &.{},
        &.{},
        &.{}, // module_types_kinds
        &.{}, // struct_defs
        &.{}, // array_defs
    );
}

test "validate: typed (ref N) from ref.func is NOT a subtype of externref" {
    // The subtype rule is narrow: (ref $sig) <: func head only, never
    // externref. Storing a typed funcref into an externref global must
    // still reject.
    const t0: FuncType = .{ .params = &.{}, .results = &.{} };
    const mod_types = [_]FuncType{t0};
    const fti = [_]u32{0};
    const globals = [_]GlobalEntry{.{ .valtype = .externref, .mutable = true }};
    const body = [_]u8{ 0xD2, 0x00, 0x24, 0x00, 0x0B };
    const r = validator.validateFunctionWithMemIdxAndTags(
        empty_sig,
        &.{},
        &body,
        &mod_types,
        &globals,
        &mod_types,
        0,
        &.{},
        0,
        1,
        .i32,
        &.{},
        &.{},
        &fti,
        &.{}, // module_types_kinds
        &.{}, // struct_defs
        &.{}, // array_defs
    );
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: ref.null with bad reftype byte → BadValType" {
    const body = [_]u8{ 0xD0, 0x55, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.BadValType, r);
}

test "validate: ref.test heap_type round-trip (10.G op_gc cycle 7)" {
    // Wasm 3.0 GC §3.3.5.3 — `(ref.null anyref ; ref.test anyref ; end)`.
    // Validator: ref.null anyref pushes anyref; ref.test anyref
    // consumes heap_type byte (0x6E for anyref), pops reftype,
    // pushes i32. Round-trip validates clean against i32-result sig.
    //
    // Opcode encoding:
    //   0xD0 0x6E       — ref.null anyref
    //   0xFB 0x14 0x6E  — ref.test anyref
    //   0x0B            — end
    const body = [_]u8{ 0xD0, 0x6E, 0xFB, 0x14, 0x6E, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.test_null heap_type round-trip (10.G op_gc cycle 7)" {
    // Mirror: ref.test_null variant accepts null operands;
    // validator shape identical to ref.test (sub-op 21 = 0x15).
    const body = [_]u8{ 0xD0, 0x6E, 0xFB, 0x15, 0x6E, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.cast heap_type round-trip (10.G op_gc cycle 8)" {
    // Wasm 3.0 GC §3.3.5.4 — `(ref.null anyref ; ref.cast anyref ;
    // ref.is_null ; end)`. Validator: ref.cast pops reftype, pushes
    // reftype back (heap_type byte consumed but pre-RTT the popped
    // type is preserved). ref.is_null then consumes + pushes i32.
    //
    // Opcode encoding:
    //   0xD0 0x6E       — ref.null anyref
    //   0xFB 0x16 0x6E  — ref.cast anyref
    //   0xD1            — ref.is_null
    //   0x0B            — end
    const body = [_]u8{ 0xD0, 0x6E, 0xFB, 0x16, 0x6E, 0xD1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.cast_null heap_type round-trip (10.G op_gc cycle 8)" {
    // Mirror: ref.cast_null variant accepts null operands;
    // validator shape identical to ref.cast (sub-op 23 = 0x17).
    const body = [_]u8{ 0xD0, 0x6E, 0xFB, 0x17, 0x6E, 0xD1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: br_on_cast inside block round-trip (10.G op_gc cycle 9)" {
    // Wasm 3.0 GC §3.3.5.5. Body:
    //   block (param anyref) (result anyref)
    //     br_on_cast 0 anyref anyref     ;; flags=0, label=0, ht1=ht2=0x6E
    //   end
    //   drop
    //   ref.null anyref
    //   end
    //
    // Encoding (block uses typeidx 1 = (anyref) -> (anyref)):
    //   0xD0 0x6E         — ref.null anyref
    //   0x02 0x01         — block typeidx 1
    //   0xFB 0x18 ...     — br_on_cast flags=0 label=0 ht1=anyref ht2=anyref
    //   0x0B 0x1A 0xD0 0x6E 0x0B
    const body = [_]u8{
        0xD0, 0x6E,
        0x02, 0x01,
        0xFB, 0x18,
        0x00, 0x00,
        0x6E, 0x6E,
        0x0B, 0x1A,
        0xD0, 0x6E,
        0x0B,
    };
    const anyref_arr = [_]ValType{.anyref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &anyref_arr };
    const block_sig: FuncType = .{ .params = &anyref_arr, .results = &anyref_arr };
    const module_types = [_]FuncType{ fn_sig, block_sig };
    try validateFunction(fn_sig, &.{}, &body, &.{}, &.{}, &module_types, 0, &.{}, 0);
}

test "validate: br_on_cast_fail inside block round-trip (10.G op_gc cycle 9)" {
    const body = [_]u8{
        0xD0, 0x6E,
        0x02, 0x01,
        0xFB, 0x19,
        0x00, 0x00,
        0x6E, 0x6E,
        0x0B, 0x1A,
        0xD0, 0x6E,
        0x0B,
    };
    const anyref_arr = [_]ValType{.anyref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &anyref_arr };
    const block_sig: FuncType = .{ .params = &anyref_arr, .results = &anyref_arr };
    const module_types = [_]FuncType{ fn_sig, block_sig };
    try validateFunction(fn_sig, &.{}, &body, &.{}, &.{}, &module_types, 0, &.{}, 0);
}

test "validate: array.len round-trip (10.G op_gc cycle 12)" {
    // Wasm 3.0 GC §3.3.5.6.13 — `(ref.null arrayref ; array.len ; end)`.
    // Validator: ref.null arrayref pushes arrayref; array.len pops
    // arrayref-compatible reftype, pushes i32.
    //
    // Opcode encoding:
    //   0xD0 0x6A        — ref.null arrayref
    //   0xFB 0x0F        — array.len
    //   0x0B             — end
    const body = [_]u8{ 0xD0, 0x6A, 0xFB, 0x0F, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: array.len with i32 operand → StackTypeMismatch (10.G op_gc cycle 12)" {
    // Wrong input type: i32 instead of arrayref.
    const body = [_]u8{ 0x41, 0x00, 0xFB, 0x0F, 0x0B };
    const r = validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: array.get reads i32 element (10.G op_gc cycle 18)" {
    const fn_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .arraydef };
    const struct_defs = [_]?sections.StructDef{ null, null };
    const array_defs = [_]?sections.ArrayDef{
        null,
        .{ .element = .{ .valtype = .i32, .mutable = true } },
    };
    // i32.const 5 ; array.new_default 1 ; i32.const 0 ; array.get 1 ; end
    const body = [_]u8{ 0x41, 0x05, 0xFB, 0x07, 0x01, 0x41, 0x00, 0xFB, 0x0B, 0x01, 0x0B };
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: array.set on mutable element round-trips (10.G op_gc cycle 18)" {
    const arrayref_arr_g = [_]ValType{.arrayref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &arrayref_arr_g };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .arraydef };
    const struct_defs = [_]?sections.StructDef{ null, null };
    const array_defs = [_]?sections.ArrayDef{ null, .{ .element = .{ .valtype = .i32, .mutable = true } } };
    // new ; idx ; val ; set ; new (result) ; end
    const body = [_]u8{
        0x41, 0x05, 0xFB, 0x07, 0x01,
        0x41, 0x00, 0x41, 0x2A, 0xFB,
        0x0E, 0x01, 0x41, 0x05, 0xFB,
        0x07, 0x01, 0x0B,
    };
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: array.set on immutable element → StackTypeMismatch (10.G op_gc cycle 18)" {
    const arrayref_arr_g = [_]ValType{.arrayref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &arrayref_arr_g };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .arraydef };
    const struct_defs = [_]?sections.StructDef{ null, null };
    const array_defs = [_]?sections.ArrayDef{ null, .{ .element = .{ .valtype = .i32, .mutable = false } } };
    const body = [_]u8{
        0x41, 0x05, 0xFB, 0x07, 0x01,
        0x41, 0x00, 0x41, 0x2A, 0xFB,
        0x0E, 0x01, 0x41, 0x05, 0xFB,
        0x07, 0x01, 0x0B,
    };
    const r = validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: array.fill round-trips on mutable element (10.G op_gc cycle 18)" {
    const arrayref_arr_g = [_]ValType{.arrayref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &arrayref_arr_g };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .arraydef };
    const struct_defs = [_]?sections.StructDef{ null, null };
    const array_defs = [_]?sections.ArrayDef{ null, .{ .element = .{ .valtype = .i32, .mutable = true } } };
    // new ; idx ; val ; count ; fill ; new (return) ; end
    const body = [_]u8{
        0x41, 0x05, 0xFB, 0x07, 0x01,
        0x41, 0x00, 0x41, 0x2A, 0x41,
        0x03, 0xFB, 0x10, 0x01, 0x41,
        0x05, 0xFB, 0x07, 0x01, 0x0B,
    };
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: struct.get reads i32 field (10.G op_gc cycle 17)" {
    // struct { i32 var }; body: struct.new_default 1 ; struct.get 1 0 ; end.
    //   0xFB 0x01 0x01           — struct.new_default typeidx=1
    //   0xFB 0x02 0x01 0x00      — struct.get typeidx=1 fieldidx=0
    //   0x0B                     — end
    const fn_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .structdef };
    const sd_fields = [_]sections.StructFieldType{
        .{ .valtype = .i32, .mutable = true },
    };
    const struct_defs = [_]?sections.StructDef{ null, .{ .fields = &sd_fields } };
    const array_defs = [_]?sections.ArrayDef{ null, null };
    const body = [_]u8{ 0xFB, 0x01, 0x01, 0xFB, 0x02, 0x01, 0x00, 0x0B };
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: struct.set on mutable field round-trips (10.G op_gc cycle 17)" {
    // struct { i32 var }; body:
    //   struct.new_default 1 ; i32.const 42 ; struct.set 1 0 ;
    //   struct.new_default 1 ; end  (return any structref).
    //   0xFB 0x01 0x01           — struct.new_default
    //   0x41 0x2A                — i32.const 42
    //   0xFB 0x05 0x01 0x00      — struct.set
    //   0xFB 0x01 0x01           — struct.new_default (result)
    //   0x0B
    // Wait — struct.new_default pushes structref, struct.set pops
    // structref+i32; we want the structref BELOW the i32 at pop
    // time, so order is: structref, i32. Restructure:
    //   0xFB 0x01 0x01           — push structref [SR]
    //   0x41 0x2A                — push i32 [SR, i32]
    //   0xFB 0x05 0x01 0x00      — set pops i32, then SR → []
    //   0xFB 0x01 0x01           — push final structref result
    const structref_arr = [_]ValType{.structref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &structref_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .structdef };
    const sd_fields = [_]sections.StructFieldType{
        .{ .valtype = .i32, .mutable = true },
    };
    const struct_defs = [_]?sections.StructDef{ null, .{ .fields = &sd_fields } };
    const array_defs = [_]?sections.ArrayDef{ null, null };
    const body = [_]u8{
        0xFB, 0x01, 0x01,
        0x41, 0x2A, 0xFB,
        0x05, 0x01, 0x00,
        0xFB, 0x01, 0x01,
        0x0B,
    };
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: struct.set on immutable field → StackTypeMismatch (10.G op_gc cycle 17)" {
    // struct { i32 const }; struct.set rejects.
    const structref_arr = [_]ValType{.structref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &structref_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .structdef };
    const sd_fields = [_]sections.StructFieldType{
        .{ .valtype = .i32, .mutable = false },
    };
    const struct_defs = [_]?sections.StructDef{ null, .{ .fields = &sd_fields } };
    const array_defs = [_]?sections.ArrayDef{ null, null };
    const body = [_]u8{
        0xFB, 0x01, 0x01,
        0x41, 0x2A, 0xFB,
        0x05, 0x01, 0x00,
        0xFB, 0x01, 0x01,
        0x0B,
    };
    const r = validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: struct.get with out-of-range fieldidx → InvalidFuncIndex (10.G op_gc cycle 17)" {
    // struct { i32 } has only fieldidx 0; access fieldidx 7.
    const fn_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .structdef };
    const sd_fields = [_]sections.StructFieldType{
        .{ .valtype = .i32, .mutable = true },
    };
    const struct_defs = [_]?sections.StructDef{ null, .{ .fields = &sd_fields } };
    const array_defs = [_]?sections.ArrayDef{ null, null };
    const body = [_]u8{ 0xFB, 0x01, 0x01, 0xFB, 0x02, 0x01, 0x07, 0x0B };
    const r = validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: array.new_default round-trips (10.G op_gc cycle 16)" {
    // Types: [() -> (arrayref), array<i32 var>].
    //   0x41 0x05        — i32.const 5 (size)
    //   0xFB 0x07 0x01   — array.new_default typeidx=1
    //   0x0B             — end
    const arrayref_arr = [_]ValType{.arrayref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &arrayref_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .arraydef };
    const struct_defs = [_]?sections.StructDef{ null, null };
    const array_defs = [_]?sections.ArrayDef{
        null,
        .{ .element = .{ .valtype = .i32, .mutable = true } },
    };
    const body = [_]u8{ 0x41, 0x05, 0xFB, 0x07, 0x01, 0x0B };
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: array.new with matching init+size round-trips (10.G op_gc cycle 16)" {
    // array<i32 var>; body: i32.const 42 (init) ; i32.const 8 (size) ;
    //   array.new typeidx=1 ; end.
    //   0x41 0x2A 0x41 0x08 0xFB 0x06 0x01 0x0B
    const arrayref_arr = [_]ValType{.arrayref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &arrayref_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .arraydef };
    const struct_defs = [_]?sections.StructDef{ null, null };
    const array_defs = [_]?sections.ArrayDef{
        null,
        .{ .element = .{ .valtype = .i32, .mutable = true } },
    };
    const body = [_]u8{ 0x41, 0x2A, 0x41, 0x08, 0xFB, 0x06, 0x01, 0x0B };
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: array.new with wrong init type → StackTypeMismatch (10.G op_gc cycle 16)" {
    // array<i32>; push i64 init instead.
    //   0x42 0x2A 0x41 0x08 0xFB 0x06 0x01 0x0B
    const arrayref_arr = [_]ValType{.arrayref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &arrayref_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .arraydef };
    const struct_defs = [_]?sections.StructDef{ null, null };
    const array_defs = [_]?sections.ArrayDef{
        null,
        .{ .element = .{ .valtype = .i32, .mutable = true } },
    };
    const body = [_]u8{ 0x42, 0x2A, 0x41, 0x08, 0xFB, 0x06, 0x01, 0x0B };
    const r = validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: array.new_fixed N=3 round-trips (10.G op_gc cycle 16)" {
    // array<i32>; 3 i32 consts then array.new_fixed typeidx=1 N=3.
    //   0x41 0x01 0x41 0x02 0x41 0x03 0xFB 0x08 0x01 0x03 0x0B
    const arrayref_arr = [_]ValType{.arrayref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &arrayref_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .arraydef };
    const struct_defs = [_]?sections.StructDef{ null, null };
    const array_defs = [_]?sections.ArrayDef{
        null,
        .{ .element = .{ .valtype = .i32, .mutable = true } },
    };
    const body = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x41, 0x03, 0xFB, 0x08, 0x01, 0x03, 0x0B };
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: array.new pointing at struct typeidx → InvalidFuncIndex (10.G op_gc cycle 16)" {
    // typeidx 1 is .structdef, not .arraydef.
    const arrayref_arr = [_]ValType{.arrayref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &arrayref_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .structdef };
    const sd_fields = [_]sections.StructFieldType{
        .{ .valtype = .i32, .mutable = true },
    };
    const struct_defs = [_]?sections.StructDef{ null, .{ .fields = &sd_fields } };
    const array_defs = [_]?sections.ArrayDef{ null, null };
    const body = [_]u8{ 0x41, 0x05, 0xFB, 0x07, 0x01, 0x0B };
    const r = validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: struct.new_default round-trips (10.G op_gc cycle 15)" {
    // Types: [() -> (anyref), struct { i32 var }].
    // Body: struct.new_default 1 ; end.
    // struct.new_default pops nothing, pushes .structref (currently
    // marshalled as .anyref shape downstream — see runtime/value.zig).
    //
    // Encoding:
    //   0xFB 0x01 0x01   — struct.new_default typeidx=1
    //   0x0B             — end
    const anyref_arr = [_]ValType{.anyref};
    const i32_arr2 = [_]ValType{.i32};
    const structref_arr = [_]ValType{.structref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &structref_arr };
    const dummy_struct_sig: FuncType = .{ .params = &.{}, .results = &.{} };
    const module_types = [_]FuncType{ fn_sig, dummy_struct_sig };
    var kinds = [_]sections.TypeKind{ .func, .structdef };
    const sd_fields = [_]sections.StructFieldType{
        .{ .valtype = .i32, .mutable = true },
    };
    const struct_defs = [_]?sections.StructDef{
        null,
        .{ .fields = &sd_fields },
    };
    const array_defs = [_]?sections.ArrayDef{ null, null };
    const body = [_]u8{ 0xFB, 0x01, 0x01, 0x0B };
    _ = i32_arr2;
    _ = anyref_arr;
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: struct.new with matching fields round-trips (10.G op_gc cycle 15)" {
    // struct { i32 var, i64 const }; body pushes i32 + i64, calls
    // struct.new 1, returns structref.
    //   0x41 0x2A        — i32.const 42
    //   0x42 0x07        — i64.const 7
    //   0xFB 0x00 0x01   — struct.new typeidx=1
    //   0x0B             — end
    const structref_arr = [_]ValType{.structref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &structref_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .structdef };
    const sd_fields = [_]sections.StructFieldType{
        .{ .valtype = .i32, .mutable = true },
        .{ .valtype = .i64, .mutable = false },
    };
    const struct_defs = [_]?sections.StructDef{ null, .{ .fields = &sd_fields } };
    const array_defs = [_]?sections.ArrayDef{ null, null };
    const body = [_]u8{ 0x41, 0x2A, 0x42, 0x07, 0xFB, 0x00, 0x01, 0x0B };
    try validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
}

test "validate: struct.new with wrong field type → StackTypeMismatch (10.G op_gc cycle 15)" {
    // struct { i32 var } — push i64 instead → mismatch.
    //   0x42 0x07        — i64.const 7
    //   0xFB 0x00 0x01   — struct.new typeidx=1
    //   0x0B             — end
    const structref_arr = [_]ValType{.structref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &structref_arr };
    const module_types = [_]FuncType{ fn_sig, .{ .params = &.{}, .results = &.{} } };
    var kinds = [_]sections.TypeKind{ .func, .structdef };
    const sd_fields = [_]sections.StructFieldType{
        .{ .valtype = .i32, .mutable = true },
    };
    const struct_defs = [_]?sections.StructDef{ null, .{ .fields = &sd_fields } };
    const array_defs = [_]?sections.ArrayDef{ null, null };
    const body = [_]u8{ 0x42, 0x07, 0xFB, 0x00, 0x01, 0x0B };
    const r = validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: struct.new pointing at func typeidx → InvalidFuncIndex (10.G op_gc cycle 15)" {
    // typeidx 0 is .func, not .structdef.
    const structref_arr = [_]ValType{.structref};
    const fn_sig: FuncType = .{ .params = &.{}, .results = &structref_arr };
    const module_types = [_]FuncType{fn_sig};
    var kinds = [_]sections.TypeKind{.func};
    const struct_defs = [_]?sections.StructDef{null};
    const array_defs = [_]?sections.ArrayDef{null};
    const body = [_]u8{ 0xFB, 0x01, 0x00, 0x0B };
    const r = validateFunctionWithGcTypes(
        fn_sig,
        &.{},
        &body,
        &.{},
        &.{},
        &module_types,
        &kinds,
        &struct_defs,
        &array_defs,
        0,
        &.{},
        0,
    );
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: ref.eq round-trip (10.G op_gc cycle 11)" {
    // Wasm 3.0 GC §3.3.5.2 — `(ref.null anyref ; ref.null anyref ;
    //   ref.eq ; end)`. Validator: two ref.null pushes, ref.eq pops
    // both and pushes i32.
    //
    // Opcode encoding:
    //   0xD0 0x6E        — ref.null anyref
    //   0xD0 0x6E        — ref.null anyref
    //   0xFB 0x13        — ref.eq
    //   0x0B             — end
    const body = [_]u8{ 0xD0, 0x6E, 0xD0, 0x6E, 0xFB, 0x13, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.eq with i32 operand → StackTypeMismatch (10.G op_gc cycle 11)" {
    // Wrong input: push i32 instead of a reftype.
    //   0x41 0x00 0xD0 0x6E 0xFB 0x13 0x0B
    const body = [_]u8{ 0x41, 0x00, 0xD0, 0x6E, 0xFB, 0x13, 0x0B };
    const r = validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: any.convert_extern round-trip (10.G op_gc cycle 10)" {
    // Wasm 3.0 GC §3.3.5.7 — `(ref.null externref ; any.convert_extern ;
    //   ref.is_null ; end)`. Validator: ref.null externref pushes
    // externref; any.convert_extern pops externref, pushes anyref;
    // ref.is_null pops + pushes i32.
    //
    // Opcode encoding:
    //   0xD0 0x6F        — ref.null externref
    //   0xFB 0x1A        — any.convert_extern
    //   0xD1             — ref.is_null
    //   0x0B             — end
    const body = [_]u8{ 0xD0, 0x6F, 0xFB, 0x1A, 0xD1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: extern.convert_any round-trip (10.G op_gc cycle 10)" {
    // Mirror direction: `(ref.null anyref ; extern.convert_any ;
    //   ref.is_null ; end)`. Validator: pops anyref, pushes externref.
    //
    // Opcode encoding:
    //   0xD0 0x6E        — ref.null anyref
    //   0xFB 0x1B        — extern.convert_any
    //   0xD1             — ref.is_null
    //   0x0B             — end
    const body = [_]u8{ 0xD0, 0x6E, 0xFB, 0x1B, 0xD1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: any.convert_extern with anyref input → StackTypeMismatch (10.G op_gc cycle 10)" {
    // Wrong input type: pushing anyref but the op expects externref.
    // 0xD0 0x6E ; 0xFB 0x1A ; 0xD1 ; 0x0B
    const body = [_]u8{ 0xD0, 0x6E, 0xFB, 0x1A, 0xD1, 0x0B };
    const r = validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: ref.i31 → i31.get_s round-trip (10.G op_gc cycle 5; ADR-0115 §6 typed precision)" {
    // Wasm 3.0 GC §3.x — `(i32.const 42 ; ref.i31 ; i31.get_s)`
    // round-trips through ValType.i31ref (no longer the .funcref
    // stand-in from pre-cycle-5). Validator: ref.i31 pops i32,
    // pushes .i31ref; i31.get_s pops the reftype (accepts
    // .i31ref via cycle 4's cascade), pushes i32. Pins the typed-
    // precision wire after the cycle 1 ADR amendment authorised
    // the ValType extension.
    // Opcode encoding: 0x41 0x2A (i32.const 42) ; 0xFB 0x1C
    // (ref.i31) ; 0xFB 0x1D (i31.get_s) ; 0x0B (end).
    const body = [_]u8{ 0x41, 0x2A, 0xFB, 0x1C, 0xFB, 0x1D, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate: ref.null i31ref pushes i31ref; ref.is_null consumes + pushes i32 (10.G op_gc cycle 4)" {
    // Wasm 3.0 GC §3.3.5.1 — `ref.null i31ref` pushes a null
    // i31ref onto the operand stack; `ref.is_null` then consumes
    // the reftype and pushes i32 (1 for null, 0 otherwise). Pins
    // cycle 4 of the 10.G-op_gc bundle: the validator's reftype-
    // check sites (opRefNull / opRefIsNull / opRefAsNonNull /
    // br_on_null / br_on_non_null / etc.) accept i31ref alongside
    // funcref/externref via the `t != .i31ref` cascade addition.
    // i31ref encoded as byte 0x6C (cycle 3 parser wire).
    const body = [_]u8{ 0xD0, 0x6C, 0xD1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
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
        0x1C, 0x01,
        0x7F, 0x1A,
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
        0x1C, 0x01,
        0x70, 0x1A,
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

// ============================================================
// §9.9 / 9.3 — SIMD-128 prefix-`0xFD` validator tests
// (per ADR-0041 + Revision 2). MVP catalogue covers v128.const
// + v128.load/store + splat + extract/replace_lane + binop +
// type-mismatch rejection. Remaining op coverage extends in
// 9.4 IR + 9.5-9.8 emit chunks.
// ============================================================

const v128_arr = [_]ValType{.v128};
const v128_result_sig: FuncType = .{ .params = &.{}, .results = &v128_arr };

test "validate (simd): v128.const + end produces v128 result" {
    // 0xFD 0x0C [16 bytes] 0x0B
    var body: [19]u8 = undefined;
    body[0] = 0xFD;
    body[1] = 0x0C;
    @memset(body[2..18], 0); // 16 immediate bytes (all zero)
    body[18] = 0x0B;
    try validateFunction(v128_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (simd): v128.const truncated immediate fails" {
    // Header says v128.const but only 8 immediate bytes follow.
    var body: [11]u8 = undefined;
    body[0] = 0xFD;
    body[1] = 0x0C;
    @memset(body[2..10], 0); // truncated: 8 bytes instead of 16
    body[10] = 0x0B;
    const r = validateFunction(v128_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.UnexpectedEnd, r);
}

test "validate (simd): i32x4.splat consumes i32, pushes v128" {
    // i32.const 0 ; 0xFD 17 (i32x4.splat) ; end
    const body = [_]u8{ 0x41, 0x00, 0xFD, 0x11, 0x0B };
    try validateFunction(v128_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (simd): i32x4.splat with wrong scalar type fails" {
    // i64.const 0 ; 0xFD 17 (i32x4.splat — expects i32) ; end
    const body = [_]u8{ 0x42, 0x00, 0xFD, 0x11, 0x0B };
    const r = validateFunction(v128_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate (simd): f64x2.splat consumes f64, pushes v128" {
    // f64.const 0.0 (8 bytes) ; 0xFD 20 (f64x2.splat) ; end
    var body: [13]u8 = undefined;
    body[0] = 0x44; // f64.const
    @memset(body[1..9], 0); // 8 immediate bytes
    body[9] = 0xFD;
    body[10] = 0x14; // sub-opcode 20 = f64x2.splat
    body[11] = 0x0B;
    // Adjust slice length to 12 (we declared 13 but use 12).
    try validateFunction(v128_result_sig, &.{}, body[0..12], &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (simd): i32x4.extract_lane consumes v128, pushes i32" {
    // v128.const [16 bytes] ; 0xFD 27 (i32x4.extract_lane) lane=0 ; end
    var body: [22]u8 = undefined;
    body[0] = 0xFD;
    body[1] = 0x0C;
    @memset(body[2..18], 0);
    body[18] = 0xFD;
    body[19] = 0x1B; // sub-opcode 27 = i32x4.extract_lane
    body[20] = 0x00; // lane index 0
    body[21] = 0x0B;
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (simd): i32x4.replace_lane consumes v128 + i32, pushes v128" {
    // v128.const ; i32.const 7 ; 0xFD 28 (i32x4.replace_lane) lane=0 ; end
    var body: [24]u8 = undefined;
    body[0] = 0xFD;
    body[1] = 0x0C;
    @memset(body[2..18], 0);
    body[18] = 0x41; // i32.const
    body[19] = 0x07;
    body[20] = 0xFD;
    body[21] = 0x1C; // sub-opcode 28 = i32x4.replace_lane
    body[22] = 0x00; // lane index
    body[23] = 0x0B;
    try validateFunction(v128_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (simd): v128 binop (sub 110) consumes 2× v128, pushes v128" {
    // v128.const ; v128.const ; 0xFD 110 (in the i32x4-arith range) ; end
    var body: [40]u8 = undefined;
    var i: usize = 0;
    body[i] = 0xFD;
    i += 1;
    body[i] = 0x0C;
    i += 1;
    @memset(body[i .. i + 16], 0);
    i += 16;
    body[i] = 0xFD;
    i += 1;
    body[i] = 0x0C;
    i += 1;
    @memset(body[i .. i + 16], 0);
    i += 16;
    body[i] = 0xFD;
    i += 1;
    body[i] = 0x6E; // sub-opcode 110 (LEB128: single byte since < 128)
    i += 1;
    body[i] = 0x0B;
    i += 1;
    try validateFunction(v128_result_sig, &.{}, body[0..i], &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (simd): v128 binop with wrong stack types fails" {
    // i32.const ; i32.const ; 0xFD 110 — expects v128 + v128, not i32 + i32.
    const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0xFD, 0x6E, 0x0B };
    const r = validateFunction(v128_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate (simd): unknown 0xFD sub-opcode → NotImplemented" {
    // 0xFD with sub 0xFFFF (way past defined SIMD range; LEB128 multi-byte)
    const body = [_]u8{ 0xFD, 0xFF, 0xFF, 0x03, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.NotImplemented, r);
}

// ============================================================
// Wasm 3.0 tail-call validator coverage (10.TC-1b)
// ============================================================

test "validate (tail-call): return_call with matching callee sig + matching fn return" {
    // body: return_call 0 ; end
    // caller sig: () -> i32; callee[0] sig: () -> i32 → tail call OK.
    const body = [_]u8{ 0x12, 0x00, 0x0B };
    const callee_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };
    const func_types = [_]FuncType{callee_sig};
    try validateFunction(i32_result_sig, &.{}, &body, &func_types, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (tail-call): return_call with callee.results != fn.results fails" {
    // caller sig: () -> () (empty); callee[0] sig: () -> i32 → mismatch.
    const body = [_]u8{ 0x12, 0x00, 0x0B };
    const callee_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };
    const func_types = [_]FuncType{callee_sig};
    const r = validateFunction(empty_sig, &.{}, &body, &func_types, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate (tail-call): return_call with funcidx out of range fails" {
    // body: return_call 99 ; end
    const body = [_]u8{ 0x12, 0x63, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate (tail-call): return_call_indirect with matching sig + funcref table" {
    // body: i32.const 0 ; return_call_indirect typeidx=0 tableidx=0 ; end
    // caller sig: () -> i32; module_types[0] = () -> i32; table[0] = funcref.
    const body = [_]u8{ 0x41, 0x00, 0x13, 0x00, 0x00, 0x0B };
    const fn_type: FuncType = .{ .params = &.{}, .results = &i32_arr };
    const module_types = [_]FuncType{fn_type};
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 1 }};
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &module_types, 0, &tables, 0);
}

test "validate (tail-call): return_call_indirect with non-funcref table fails" {
    // table[0] = externref → return_call_indirect rejects (same as call_indirect §3.3.5.6).
    const body = [_]u8{ 0x41, 0x00, 0x13, 0x00, 0x00, 0x0B };
    const fn_type: FuncType = .{ .params = &.{}, .results = &.{} };
    const module_types = [_]FuncType{fn_type};
    const tables = [_]zir.TableEntry{.{ .elem_type = .externref, .min = 1 }};
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &module_types, 0, &tables, 0);
    try testing.expectError(Error.InvalidFuncIndex, r);
}

// ============================================================
// Wasm 3.0 EH try_table parse/validator coverage (10.E-3b)
// ============================================================

test "validate (try_table): empty catch vec, empty body → OK" {
    // body: 0x1F (try_table) 0x40 (empty blocktype) 0x00 (count=0)
    //       0x0B (end of try_table) 0x0B (end of function)
    const body = [_]u8{ 0x1F, 0x40, 0x00, 0x0B, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (try_table): catch_all targeting outer label → OK" {
    // body: try_table () (catch_all 0) end ; end
    // 0x1F 0x40 0x01 0x02 0x00 0x0B 0x0B
    // catch_all label_idx=0 → function frame (always exists).
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x02, 0x00, 0x0B, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (try_table): catch_all with out-of-range label_idx fails" {
    // catch_all label_idx=99 → no such label.
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x02, 0x63, 0x0B, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.InvalidBranchDepth, r);
}

test "validate (try_table): catch (0x00) with tag_idx + label_idx parses + validates label range" {
    // try_table () (catch 0 0) end ; end — tag 0 declared (empty params).
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x00, 0x00, 0x00, 0x0B, 0x0B };
    const empty_ft: FuncType = .{ .params = &.{}, .results = &.{} };
    const types_arr = [_]FuncType{empty_ft};
    const tags_arr = [_]TagEntry{.{ .attribute = 0, .typeidx = 0 }};
    try validateFunctionWithTags(empty_sig, &.{}, &body, &.{}, &.{}, &types_arr, 0, &.{}, 0, &tags_arr);
}

test "validate (try_table): unknown catch kind byte rejected" {
    // 0x04 is not a valid catch kind (only 0x00..0x03 defined).
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x04, 0x00, 0x0B, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.BadBlockType, r);
}

test "validate (try_table): catch_all_ref to [exnref] label → OK (10.E cycle 113; exnref landed cyc112)" {
    // () -> (exnref): try_table () (catch_all_ref 0) end ; ref.null exn ; end.
    // catch_all_ref pushes [exnref] to label 0 (function frame, results
    // = [exnref]) → structural match. Was a blanket StackTypeMismatch
    // reject pre-cycle-113 ("tighten once exnref lands", validator.zig).
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x03, 0x00, 0x0B, 0xD0, 0x69, 0x0B };
    try validateFunction(exnref_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (try_table): catch_ref (empty-param tag) to [exnref] label → OK (10.E cycle 113)" {
    // () -> (exnref): try_table () (catch_ref 0 0) end ; ref.null exn ; end.
    // tag 0 = () -> () (empty params) → catch_ref pushes [] ++ [exnref]
    // = [exnref], matching the function-frame label type.
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x01, 0x00, 0x00, 0x0B, 0xD0, 0x69, 0x0B };
    const empty_ft: FuncType = .{ .params = &.{}, .results = &.{} };
    const types_arr = [_]FuncType{empty_ft};
    const tags_arr = [_]TagEntry{.{ .attribute = 0, .typeidx = 0 }};
    try validateFunctionWithTags(exnref_result_sig, &.{}, &body, &.{}, &.{}, &types_arr, 0, &.{}, 0, &tags_arr);
}

test "validate (try_table): catch_all_ref to non-exnref ([i32]) label → StackTypeMismatch" {
    // () -> i32: catch_all_ref pushes [exnref] but label 0 expects [i32]
    // → structural mismatch (locks the matching, not a blanket accept).
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x03, 0x00, 0x0B, 0x41, 0x00, 0x0B };
    const r = validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

// ============================================================
// Wasm 3.0 EH throw / throw_ref validator coverage (10.E-4)
// ============================================================

test "validate (throw): polymorphic-stack from terminator" {
    // body: throw 0 ; end
    // Even though caller is () -> i32, throw marks the rest unreachable
    // and the function's end_type (i32) is satisfied polymorphically.
    // Tag 0 = empty-param tag (module_types[0] = () -> ()).
    const body = [_]u8{ 0x08, 0x00, 0x0B };
    const empty_ft: FuncType = .{ .params = &.{}, .results = &.{} };
    const types_arr = [_]FuncType{empty_ft};
    const tags_arr = [_]TagEntry{.{ .attribute = 0, .typeidx = 0 }};
    try validateFunctionWithTags(i32_result_sig, &.{}, &body, &.{}, &.{}, &types_arr, 0, &.{}, 0, &tags_arr);
}

test "validate (throw): code after throw is unreachable" {
    // body: throw 0 ; i32.const 99 ; end
    // i32.const after throw runs in polymorphic mode; end_type i32
    // satisfied polymorphically (no explicit value left on stack).
    const body = [_]u8{ 0x08, 0x00, 0x41, 0x63, 0x0B };
    const empty_ft: FuncType = .{ .params = &.{}, .results = &.{} };
    const types_arr = [_]FuncType{empty_ft};
    const tags_arr = [_]TagEntry{.{ .attribute = 0, .typeidx = 0 }};
    try validateFunctionWithTags(i32_result_sig, &.{}, &body, &.{}, &.{}, &types_arr, 0, &.{}, 0, &tags_arr);
}

// Wasm 3.0 EH Module.tags wiring (10.E-N-1)

test "validate (throw): tag_idx >= tags.len → InvalidTagIndex" {
    // body: throw 1 ; end  — tag_idx=1 but only 1 tag declared (idx 0).
    const body = [_]u8{ 0x08, 0x01, 0x0B };
    const empty_ft: FuncType = .{ .params = &.{}, .results = &.{} };
    const types_arr = [_]FuncType{empty_ft};
    const tags_arr = [_]TagEntry{.{ .attribute = 0, .typeidx = 0 }};
    const r = validateFunctionWithTags(empty_sig, &.{}, &body, &.{}, &.{}, &types_arr, 0, &.{}, 0, &tags_arr);
    try testing.expectError(Error.InvalidTagIndex, r);
}

test "validate (throw): no tags declared at all → InvalidTagIndex" {
    // body: throw 0 ; end — module has no tag section.
    const body = [_]u8{ 0x08, 0x00, 0x0B };
    const r = validateFunctionWithTags(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0, &.{});
    try testing.expectError(Error.InvalidTagIndex, r);
}

test "validate (throw): pops tag's params (i32) from operand stack" {
    // body: i32.const 5 ; throw 0 ; end
    // Tag 0 = (param i32). throw 0 pops the i32 then markUnreachable.
    const body = [_]u8{ 0x41, 0x05, 0x08, 0x00, 0x0B };
    const params = [_]ValType{.i32};
    const ft: FuncType = .{ .params = &params, .results = &.{} };
    const types_arr = [_]FuncType{ft};
    const tags_arr = [_]TagEntry{.{ .attribute = 0, .typeidx = 0 }};
    try validateFunctionWithTags(empty_sig, &.{}, &body, &.{}, &.{}, &types_arr, 0, &.{}, 0, &tags_arr);
}

test "validate (throw): missing tag params on stack → StackUnderflow" {
    // body: throw 0 ; end — tag 0 expects i32 param but stack is empty.
    const body = [_]u8{ 0x08, 0x00, 0x0B };
    const params = [_]ValType{.i32};
    const ft: FuncType = .{ .params = &params, .results = &.{} };
    const types_arr = [_]FuncType{ft};
    const tags_arr = [_]TagEntry{.{ .attribute = 0, .typeidx = 0 }};
    const r = validateFunctionWithTags(empty_sig, &.{}, &body, &.{}, &.{}, &types_arr, 0, &.{}, 0, &tags_arr);
    try testing.expectError(Error.StackUnderflow, r);
}

test "validate (throw): wrong tag-param type on stack → StackTypeMismatch" {
    // body: i64.const 5 ; throw 0 ; end — tag 0 wants i32, got i64.
    const body = [_]u8{ 0x42, 0x05, 0x08, 0x00, 0x0B };
    const params = [_]ValType{.i32};
    const ft: FuncType = .{ .params = &params, .results = &.{} };
    const types_arr = [_]FuncType{ft};
    const tags_arr = [_]TagEntry{.{ .attribute = 0, .typeidx = 0 }};
    const r = validateFunctionWithTags(empty_sig, &.{}, &body, &.{}, &.{}, &types_arr, 0, &.{}, 0, &tags_arr);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate (try_table): catch with out-of-range tag_idx → InvalidTagIndex" {
    // try_table () (catch 3 0) end ; end — only 1 tag (idx 0) declared.
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x00, 0x03, 0x00, 0x0B, 0x0B };
    const empty_ft: FuncType = .{ .params = &.{}, .results = &.{} };
    const types_arr = [_]FuncType{empty_ft};
    const tags_arr = [_]TagEntry{.{ .attribute = 0, .typeidx = 0 }};
    const r = validateFunctionWithTags(empty_sig, &.{}, &body, &.{}, &.{}, &types_arr, 0, &.{}, 0, &tags_arr);
    try testing.expectError(Error.InvalidTagIndex, r);
}

test "validate (try_table): catch_all (no tag_idx) still accepts with empty tags" {
    // try_table () (catch_all 0) end ; end — catch_all has no tag_idx
    // so tags.len=0 doesn't gate it. Validates label_idx normally.
    const body = [_]u8{ 0x1F, 0x40, 0x01, 0x02, 0x00, 0x0B, 0x0B };
    try validateFunctionWithTags(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0, &.{});
}

test "validate (throw_ref): pops reftype + marks unreachable" {
    // body: ref.null funcref ; throw_ref ; end
    // ref.null 0x70 (funcref) pushes a funcref; throw_ref pops it
    // and marks unreachable.
    const body = [_]u8{ 0xD0, 0x70, 0x0A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
}

test "validate (throw_ref): empty stack → StackUnderflow" {
    // body: throw_ref ; end (no reftype on stack)
    const body = [_]u8{ 0x0A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackUnderflow, r);
}

test "validate (throw_ref): non-reftype on stack → StackTypeMismatch" {
    // body: i32.const 0 ; throw_ref ; end
    const body = [_]u8{ 0x41, 0x00, 0x0A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{}, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate (tail-call): return_call_indirect with fn-return mismatch fails" {
    // caller sig: () -> () (empty); module_types[0] = () -> i32 → mismatch.
    const body = [_]u8{ 0x41, 0x00, 0x13, 0x00, 0x00, 0x0B };
    const fn_type: FuncType = .{ .params = &.{}, .results = &i32_arr };
    const module_types = [_]FuncType{fn_type};
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 1 }};
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &module_types, 0, &tables, 0);
    try testing.expectError(Error.StackTypeMismatch, r);
}

// ============================================================
// ADR-0124 — WasmGC structural subtype validation (10.G cycle 124)
// ============================================================

fn gcField(vt: ValType, mut: bool) sections.StructFieldType {
    return .{ .valtype = vt, .mutable = mut };
}

test "typeDefIsSubtype: struct width + depth (10.G ADR-0124 cycle 124)" {
    // type0 (super) = struct { i32 const }; type1 (sub) = struct { i32 const, i64 const }.
    const f1 = [_]sections.StructFieldType{gcField(.i32, false)};
    const f2 = [_]sections.StructFieldType{ gcField(.i32, false), gcField(.i64, false) };
    var kinds = [_]sections.TypeKind{ .structdef, .structdef };
    var sdefs = [_]?sections.StructDef{ .{ .fields = &f1 }, .{ .fields = &f2 } };
    var adefs = [_]?sections.ArrayDef{ null, null };
    var items = [_]FuncType{ .{ .params = &.{}, .results = &.{} }, .{ .params = &.{}, .results = &.{} } };
    var sup = [_][]const u32{ &.{}, &.{} };
    var fin = [_]bool{ true, true };
    const t: sections.Types = .{ .arena = undefined, .items = &items, .kinds = &kinds, .struct_defs = &sdefs, .array_defs = &adefs, .supertypes = &sup, .finals = &fin };
    try testing.expect(validator.typeDefIsSubtype(1, 0, &t)); // sub(2 fields) <: super(1)
    try testing.expect(!validator.typeDefIsSubtype(0, 1, &t)); // super(1) NOT <: sub(2) — width
}

test "typeDefIsSubtype: array covariant lattice + cross-kind (10.G ADR-0124 cycle 124)" {
    // type0 = array (eqref const), type1 = array (i31ref const), type2 = struct{}.
    const a_eq = sections.ArrayDef{ .element = gcField(ValType.eqref, false) };
    const a_i31 = sections.ArrayDef{ .element = gcField(ValType.i31ref, false) };
    var kinds = [_]sections.TypeKind{ .arraydef, .arraydef, .structdef };
    const empty_fields = [_]sections.StructFieldType{};
    var sdefs = [_]?sections.StructDef{ null, null, .{ .fields = &empty_fields } };
    var adefs = [_]?sections.ArrayDef{ a_eq, a_i31, null };
    var items = [_]FuncType{ .{ .params = &.{}, .results = &.{} }, .{ .params = &.{}, .results = &.{} }, .{ .params = &.{}, .results = &.{} } };
    var sup = [_][]const u32{ &.{}, &.{}, &.{} };
    var fin = [_]bool{ true, true, true };
    const t: sections.Types = .{ .arena = undefined, .items = &items, .kinds = &kinds, .struct_defs = &sdefs, .array_defs = &adefs, .supertypes = &sup, .finals = &fin };
    try testing.expect(validator.typeDefIsSubtype(1, 0, &t)); // array(i31ref) <: array(eqref): i31 <: eq, const covariant
    try testing.expect(!validator.typeDefIsSubtype(0, 1, &t)); // array(eqref) NOT <: array(i31ref)
    try testing.expect(!validator.typeDefIsSubtype(0, 2, &t)); // array NOT <: struct (cross-kind)
}

test "validateTypeSection: accepts conformant sub, rejects finality/structural/bounds (10.G ADR-0124 cycle 125)" {
    // type0 = struct{i32} (non-final, sub), type1 declares supertype $0.
    const f1 = [_]sections.StructFieldType{gcField(.i32, false)};
    const f2 = [_]sections.StructFieldType{ gcField(.i32, false), gcField(.i64, false) };
    var kinds = [_]sections.TypeKind{ .structdef, .structdef };
    var sdefs = [_]?sections.StructDef{ .{ .fields = &f1 }, .{ .fields = &f2 } };
    var adefs = [_]?sections.ArrayDef{ null, null };
    var items = [_]FuncType{ .{ .params = &.{}, .results = &.{} }, .{ .params = &.{}, .results = &.{} } };
    const super0 = [_]u32{0};

    // Conformant: type0 non-final, type1 (width-extends $0) structurally conforms.
    {
        var sup = [_][]const u32{ &.{}, &super0 };
        var fin = [_]bool{ false, true };
        const t: sections.Types = .{ .arena = undefined, .items = &items, .kinds = &kinds, .struct_defs = &sdefs, .array_defs = &adefs, .supertypes = &sup, .finals = &fin };
        try testing.expect(validator.validateTypeSection(&t));
    }
    // Finality: type0 is final → extending it is invalid (even though structure conforms).
    {
        var sup = [_][]const u32{ &.{}, &super0 };
        var fin = [_]bool{ true, true };
        const t: sections.Types = .{ .arena = undefined, .items = &items, .kinds = &kinds, .struct_defs = &sdefs, .array_defs = &adefs, .supertypes = &sup, .finals = &fin };
        try testing.expect(!validator.validateTypeSection(&t));
    }
    // Structural: type1 narrower than its declared supertype $1 (forward) — and reversed roles.
    {
        // type0 declares supertype $1 (forward ref) → reject regardless of structure.
        var sup = [_][]const u32{ &super0, &.{} }; // type0 → super index 0 == self
        var fin = [_]bool{ false, false };
        const t: sections.Types = .{ .arena = undefined, .items = &items, .kinds = &kinds, .struct_defs = &sdefs, .array_defs = &adefs, .supertypes = &sup, .finals = &fin };
        try testing.expect(!validator.validateTypeSection(&t)); // s (0) >= i (0): self/forward
    }
    // Bounds: supertype index out of range.
    {
        const bad = [_]u32{5};
        var sup = [_][]const u32{ &.{}, &bad };
        var fin = [_]bool{ false, true };
        const t: sections.Types = .{ .arena = undefined, .items = &items, .kinds = &kinds, .struct_defs = &sdefs, .array_defs = &adefs, .supertypes = &sup, .finals = &fin };
        try testing.expect(!validator.validateTypeSection(&t));
    }
}
