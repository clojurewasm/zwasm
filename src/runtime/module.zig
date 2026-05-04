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
