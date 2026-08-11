//! WASI 0.3 `wasi:http/types` host backing (ADR-0205 phase D).
//!
//! The OS-agnostic data model half: the `fields` resource (RFC 9110
//! field-name/field-value validation + ordered storage) and, as phase D
//! progresses, the request/request-options/response models. The component
//! trampolines (`http3*` in `component_wasi_p2.zig`) lower WIT records onto
//! this surface; nothing here touches guest memory.
//!
//! DIVERGENCE note (pinned by the official http-fields test): field NAMES
//! are stored LOWERCASED and `copy-all` returns them that way — the WIT
//! prose asks for original casing, but the official corpus asserts
//! wasmtime's lowercasing behavior (bytecodealliance/wasmtime#11770), and
//! matching the corpus is the campaign's conformance bar.
//!
//! Zone 2 (`src/wasi/`).

const std = @import("std");

/// `header-error` failure classes; `headerErrorOrdinal` maps them onto the
/// WIT variant ordinals (declaration order).
pub const FieldsError = error{ InvalidSyntax, Forbidden, Immutable, SizeExceeded, Other };

pub fn headerErrorOrdinal(e: FieldsError) u8 {
    return switch (e) {
        error.InvalidSyntax => 0,
        error.Forbidden => 1,
        error.Immutable => 2,
        error.SizeExceeded => 3,
        error.Other => 4,
    };
}

/// RFC 9110 §5.6.2 `token` / `tchar`: the valid `field-name` alphabet.
pub fn validFieldName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => true,
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

/// RFC 9110 §5.6.2 `field-value`: SP / HTAB / VCHAR (0x21-0x7E) /
/// obs-text (0x80-0xFF). (The full ABNF also forbids leading/trailing
/// SP/HTAB; the official corpus treats them as valid — e.g. `" \t \t "` —
/// so only the byte alphabet is enforced, matching wasmtime.)
pub fn validFieldValue(value: []const u8) bool {
    for (value) |c| {
        const ok = switch (c) {
            ' ', '\t' => true,
            0x21...0x7e => true,
            0x80...0xff => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

/// The `fields` resource: ordered (name, value) pairs — a flat list, NOT a
/// map, because `copy-all` must reproduce every pair in insertion order
/// (repeated names = repeated entries). Names are stored lowercased
/// (module docstring); values verbatim.
pub const HttpFields = struct {
    entries: std.ArrayList(Pair) = .empty,
    /// `set` / `append` / `delete` fail `immutable` (e.g. headers minted
    /// by `request.get-headers`).
    immutable: bool = false,

    pub const Pair = struct { name: []u8, value: []u8 };

    pub fn deinit(self: *HttpFields, alloc: std.mem.Allocator) void {
        for (self.entries.items) |p| {
            alloc.free(p.name);
            alloc.free(p.value);
        }
        self.entries.deinit(alloc);
        self.* = .{};
    }

    fn appendPair(self: *HttpFields, alloc: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const n = try alloc.alloc(u8, name.len);
        errdefer alloc.free(n);
        for (name, 0..) |c, i| n[i] = std.ascii.toLower(c);
        const v = try alloc.dupe(u8, value);
        errdefer alloc.free(v);
        try self.entries.append(alloc, .{ .name = n, .value = v });
    }

    fn nameEql(stored_lower: []const u8, query: []const u8) bool {
        if (stored_lower.len != query.len) return false;
        for (stored_lower, query) |s, q| {
            if (s != std.ascii.toLower(q)) return false;
        }
        return true;
    }

    /// `get` — all values for `name` (case-insensitive), insertion order.
    /// An invalid name is gracefully "not present" (empty), per the WIT.
    pub fn get(self: *const HttpFields, out: *std.ArrayList([]const u8), alloc: std.mem.Allocator, name: []const u8) !void {
        for (self.entries.items) |p| {
            if (nameEql(p.name, name)) try out.append(alloc, p.value);
        }
    }

    /// `has` — invalid names are simply "not present" (false), per the WIT.
    pub fn has(self: *const HttpFields, name: []const u8) bool {
        for (self.entries.items) |p| {
            if (nameEql(p.name, name)) return true;
        }
        return false;
    }

    /// `set` — clear existing values then append the new ones (at the end;
    /// an empty value list is equivalent to delete).
    pub fn set(self: *HttpFields, alloc: std.mem.Allocator, name: []const u8, values: []const []const u8) FieldsError!void {
        if (self.immutable) return error.Immutable;
        if (!validFieldName(name)) return error.InvalidSyntax;
        for (values) |v| if (!validFieldValue(v)) return error.InvalidSyntax;
        self.removeAll(alloc, name);
        for (values) |v| self.appendPair(alloc, name, v) catch return error.Other;
    }

    /// `delete` — no-op when absent; invalid names still error.
    pub fn delete(self: *HttpFields, alloc: std.mem.Allocator, name: []const u8) FieldsError!void {
        if (self.immutable) return error.Immutable;
        if (!validFieldName(name)) return error.InvalidSyntax;
        self.removeAll(alloc, name);
    }

    /// `get-and-delete` — collect (into `out`, caller frees the VALUE
    /// slices it receives — ownership transfers out) then remove.
    pub fn getAndDelete(self: *HttpFields, out: *std.ArrayList([]u8), alloc: std.mem.Allocator, name: []const u8) FieldsError!void {
        if (self.immutable) return error.Immutable;
        if (!validFieldName(name)) return error.InvalidSyntax;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const p = self.entries.items[i];
            if (nameEql(p.name, name)) {
                out.append(alloc, p.value) catch return error.Other;
                alloc.free(p.name);
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
    }

    /// `append` — one value at the end.
    pub fn append(self: *HttpFields, alloc: std.mem.Allocator, name: []const u8, value: []const u8) FieldsError!void {
        if (self.immutable) return error.Immutable;
        if (!validFieldName(name)) return error.InvalidSyntax;
        if (!validFieldValue(value)) return error.InvalidSyntax;
        self.appendPair(alloc, name, value) catch return error.Other;
    }

    /// `from-list` seed / `clone` body: validate + append each pair.
    pub fn appendChecked(self: *HttpFields, alloc: std.mem.Allocator, name: []const u8, value: []const u8) FieldsError!void {
        if (!validFieldName(name)) return error.InvalidSyntax;
        if (!validFieldValue(value)) return error.InvalidSyntax;
        self.appendPair(alloc, name, value) catch return error.Other;
    }

    /// `clone` — deep copy; the result is mutable regardless of source.
    pub fn cloneInto(self: *const HttpFields, alloc: std.mem.Allocator, dest: *HttpFields) !void {
        for (self.entries.items) |p| try dest.appendPair(alloc, p.name, p.value);
    }

    fn removeAll(self: *HttpFields, alloc: std.mem.Allocator, name: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const p = self.entries.items[i];
            if (nameEql(p.name, name)) {
                alloc.free(p.name);
                alloc.free(p.value);
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
    }
};

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "field-name / field-value alphabets pin RFC 9110 tchar / field-vchar" {
    try testing.expect(validFieldName("kebab-data-100"));
    try testing.expect(validFieldName("FOO"));
    try testing.expect(validFieldName("!#$%&'*+-.^_`|~"));
    try testing.expect(!validFieldName(""));
    try testing.expect(!validFieldName("hey ho"));
    try testing.expect(!validFieldName("(what)"));
    try testing.expect(!validFieldName("voil\xc3\xa0"));
    try testing.expect(validFieldValue(""));
    try testing.expect(validFieldValue(" \t \t "));
    try testing.expect(validFieldValue("Foo"));
    try testing.expect(validFieldValue("\x80\xff"));
    try testing.expect(!validFieldValue("\n"));
    try testing.expect(!validFieldValue("\r"));
    try testing.expect(!validFieldValue("\x00"));
}

test "fields: ordered storage, case-insensitive access, lowercased copy-all" {
    const alloc = testing.allocator;
    var f: HttpFields = .{};
    defer f.deinit(alloc);

    try f.append(alloc, "foo", "val1");
    try f.append(alloc, "FOO", "val2");
    try testing.expect(f.has("foo"));
    try testing.expect(f.has("FOO"));
    // copy-all: insertion order, names lowercased.
    try testing.expectEqual(@as(usize, 2), f.entries.items.len);
    try testing.expectEqualStrings("foo", f.entries.items[0].name);
    try testing.expectEqualStrings("foo", f.entries.items[1].name);
    try testing.expectEqualStrings("val1", f.entries.items[0].value);

    // get via either casing sees both, in order.
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(alloc);
    try f.get(&got, alloc, "FOO");
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqualStrings("val2", got.items[1]);

    // set [] clears; delete via the other casing removes all.
    try f.set(alloc, "foo", &.{});
    try testing.expect(!f.has("foo"));
    try f.append(alloc, "foo", "x");
    try f.delete(alloc, "FOO");
    try testing.expect(!f.has("foo"));

    // invalid names: mutators error, has/get are graceful.
    try testing.expectError(error.InvalidSyntax, f.append(alloc, "hey ho", "v"));
    try testing.expectError(error.InvalidSyntax, f.delete(alloc, ""));
    try testing.expect(!f.has("hey ho"));

    // immutable: mutators fail, readers work.
    try f.append(alloc, "foo", "v");
    f.immutable = true;
    try testing.expectError(error.Immutable, f.append(alloc, "foo", "w"));
    try testing.expectError(error.Immutable, f.set(alloc, "foo", &.{}));
    try testing.expectError(error.Immutable, f.delete(alloc, "foo"));
    try testing.expect(f.has("foo"));
    f.immutable = false;
}

test "fields: get-and-delete transfers values out in order" {
    const alloc = testing.allocator;
    var f: HttpFields = .{};
    defer f.deinit(alloc);
    try f.append(alloc, "foo", "val1");
    try f.append(alloc, "FOO", "val2");

    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |v| alloc.free(v);
        out.deinit(alloc);
    }
    try f.getAndDelete(&out, alloc, "Foo");
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("val1", out.items[0]);
    try testing.expectEqualStrings("val2", out.items[1]);
    try testing.expect(!f.has("foo"));
    try testing.expectEqual(@as(usize, 0), f.entries.items.len);
}
