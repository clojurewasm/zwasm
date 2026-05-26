//! Parsed Module — WASM Spec §4.2.1 "Modules" runtime structure
//! counterpart of the wasm-c-api `wasm_module_t` handle.
//!
//! Per ADR-0023 §3 P-A and §3 reference table: extracted from the
//! pre-ADR `parse/parser.zig`'s Module struct. Parser logic
//! (magic/version validation + section iteration) stays in
//! `parse/parser.zig`; this file owns only the parsed-module
//! data shape so that downstream consumers (`api/wasm.zig`'s
//! `wasm_module_*`, validator, lowerer, instance binding) can
//! depend on `runtime/` without importing `frontend/`.
//!
//! Section / SectionId types remain in `parse/parser.zig` —
//! they are parsing concerns (binary-format byte ids, ordering
//! rules per Wasm 1.0 §5.5) rather than runtime structure. The
//! Module struct holds a `[]Section` for iteration but does not
//! own the parsing rules.
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

const parser = @import("../parse/parser.zig");

const Allocator = std.mem.Allocator;
const Section = parser.Section;
const SectionId = parser.SectionId;

pub const Module = struct {
    input: []const u8,
    sections: std.ArrayList(Section),
    /// 10.G-foundation (ADR-0115 §1 + ROADMAP §10 row 10.G first
    /// sub-task) — parse-time flag set true iff the module's type /
    /// import / global / table / element / function sections
    /// reference any GC valtype (anyref / eqref / structref /
    /// arrayref / (ref $struct/$array) / i31ref). Drives the
    /// zero-overhead gate: when false, GC heap allocation +
    /// collector vtable + root walk + stack-map per-Instance side-
    /// table are all skipped at runtime. Detector lands at a
    /// subsequent cycle (`needs_heap_detector.zig`); for cycle 1
    /// the field stays additive with default `false`.
    needs_gc_heap: bool = false,

    pub fn deinit(self: *Module, alloc: Allocator) void {
        self.sections.deinit(alloc);
    }

    /// Returns the first section with the given known id, or null.
    /// O(N) but Phase 1's MVP corpora carry ≤ 13 sections.
    pub fn find(self: *const Module, id: SectionId) ?Section {
        for (self.sections.items) |s| {
            if (s.id == id) return s;
        }
        return null;
    }

    pub fn countCustom(self: *const Module) usize {
        var n: usize = 0;
        for (self.sections.items) |s| {
            if (s.id == .custom) n += 1;
        }
        return n;
    }
};

const testing = std.testing;

test "Module.needs_gc_heap: parse-time flag defaults to false (10.G-foundation cycle 1; ADR-0115 §1)" {
    // Cycle-1 substrate: the flag exists, defaults false. Future
    // cycle wires needs_heap_detector.zig to walk sections and set
    // it true when GC valtypes are present. Until the detector
    // lands, every module sees the zero-overhead gate fall through
    // (GC heap + collector vtable + root walk all skipped).
    var sections: std.ArrayList(parser.Section) = .empty;
    defer sections.deinit(testing.allocator);
    const m: Module = .{ .input = &.{}, .sections = sections };
    try testing.expectEqual(false, m.needs_gc_heap);
}
