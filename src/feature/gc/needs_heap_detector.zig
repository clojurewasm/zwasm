//! `needs_gc_heap` parse-time predicate per ADR-0115 D2.
//!
//! Scans a parsed Module for GC indicators — struct / array /
//! recursive type-group declarations in the type section. When
//! true, the runtime must materialise a GC heap slab at
//! instantiation; when false, GC infrastructure is zero-overhead
//! (skipped allocation, skipped root walk, no collector setup).
//!
//! Per ADR-0115 D2: the predicate is parse-time, not lower-time,
//! because a glue / re-export module declares GC types + holds
//! cross-instance refs but allocates zero objects itself (per
//! J-1 patterns observed in `wasm_of_ocaml` re-export glue);
//! lower-time would false-negative (zero alloc ops → predicate
//! false → root scan skipped → ref drops). False positives
//! ("declared but never alloc") are acceptable — root scan
//! correctly no-ops on empty heap.
//!
//! Current coverage:
//! - Type section: struct (0x5F) / array (0x5E) / recursive type
//!   group (0x4E) declaration bytes.
//!
//! Future coverage (lights up as the GC catalog extends — tracked
//! in ADR-0115 D2's amended detection list):
//! - Heap-top reftype byte (anyref 0x6E / eqref 0x6D / i31ref
//!   0x6C / exnref 0x69) in function-type / global / table /
//!   element / locals contexts.
//! - GC type imports (typeidx-import after RecGroup landing).
//!
//! Phase 10 v0.1 modules without GC type declarations return
//! `false` cleanly; modules that declare any GC type return
//! `true`. The runtime side gates collector setup on this flag.
//!
//! Zone 1 (`src/feature/gc/`).

const std = @import("std");

const parser = @import("../../parse/parser.zig");
const module_mod = @import("../../runtime/module.zig");

const Module = module_mod.Module;
const SectionId = parser.SectionId;

/// Wasm 3.0 GC proposal §5.3 (type encoding) — single-byte tags
/// that introduce a non-functype declaration in the type section.
/// Their presence anywhere in the type-section body implies the
/// module declared a GC type and so the runtime needs a heap.
const RECURSIVE_TYPE_TAG: u8 = 0x4E;
const ARRAY_TYPE_TAG: u8 = 0x5E;
const STRUCT_TYPE_TAG: u8 = 0x5F;

/// Returns true when the module declares any GC type
/// (struct / array / recursive type group). The runtime gates
/// GC heap materialisation on this flag — false means zero
/// overhead from the GC subsystem.
///
/// Phase 10 v0.1 only scans the type section's byte stream for
/// the three GC declaration tags. Heap-top reftype scanning (in
/// func sigs / globals / tables / locals) lands per future
/// ADR-0115 D2 amendments when the typed-ref catalog extends.
pub fn detectNeedsGcHeap(module: *const Module) bool {
    const type_section = module.find(.type) orelse return false;
    return scanTypeSectionForGcTags(type_section.body);
}

/// Byte-stream scan of the type section's raw body. Looks for
/// any GC type-declaration tag. The scan is conservative — a
/// type-section byte that happens to equal one of the tags but
/// belongs to a different sub-field (e.g. inside a valtype list)
/// could trigger a false positive. Per ADR-0115 D2 false
/// positives are acceptable; the root scan no-ops on empty heap.
///
/// A precise decoder lands per future ADR-0115 D2 amendments
/// (or when the type section gets a structured decoder beyond
/// the current `decodeTypes`'s functype-only shape).
fn scanTypeSectionForGcTags(body: []const u8) bool {
    for (body) |b| {
        if (b == RECURSIVE_TYPE_TAG or b == ARRAY_TYPE_TAG or b == STRUCT_TYPE_TAG) {
            return true;
        }
    }
    return false;
}

const testing = std.testing;

// ============================================================
// Tests
// ============================================================

const MAGIC_AND_VERSION = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version 1
};

test "needs_gc_heap: empty module → false" {
    var m = try parser.parse(testing.allocator, &MAGIC_AND_VERSION);
    defer m.deinit(testing.allocator);
    try testing.expect(!detectNeedsGcHeap(&m));
}

test "needs_gc_heap: type section with only functype (0x60) → false" {
    // type section: count=1, (0x60 → functype, 0 params, 0 results)
    const bytes = MAGIC_AND_VERSION ++ [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 };
    var m = try parser.parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expect(!detectNeedsGcHeap(&m));
}

test "needs_gc_heap: type section with struct (0x5F) → true" {
    // type section body containing a 0x5F byte → struct declaration.
    // Body shape: count=1, then 0x5F + (fake) struct body. We just
    // need the 0x5F to appear in the body; the scan is byte-level.
    const bytes = MAGIC_AND_VERSION ++ [_]u8{ 0x01, 0x03, 0x01, 0x5F, 0x00 };
    var m = try parser.parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expect(detectNeedsGcHeap(&m));
}

test "needs_gc_heap: type section with array (0x5E) → true" {
    const bytes = MAGIC_AND_VERSION ++ [_]u8{ 0x01, 0x03, 0x01, 0x5E, 0x7F };
    var m = try parser.parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expect(detectNeedsGcHeap(&m));
}

test "needs_gc_heap: type section with rec-type (0x4E) → true" {
    const bytes = MAGIC_AND_VERSION ++ [_]u8{ 0x01, 0x02, 0x01, 0x4E };
    var m = try parser.parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expect(detectNeedsGcHeap(&m));
}

test "needs_gc_heap: no type section at all → false" {
    // Module with only a custom section; no type section present.
    const bytes = MAGIC_AND_VERSION ++ [_]u8{ 0x00, 0x01, 0x00 };
    var m = try parser.parse(testing.allocator, &bytes);
    defer m.deinit(testing.allocator);
    try testing.expect(!detectNeedsGcHeap(&m));
}
