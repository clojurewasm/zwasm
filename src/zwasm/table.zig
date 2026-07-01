//! `Table` — typed accessor onto an instance's exported table per
//! ADR-0109 (D-272). Mirrors `Global`/`Memory`: holds the runtime
//! pointer + table index + the export's cached elem-type/max, and
//! marshals ref cells through the shared `value_conv`. Lifetime ties
//! to the owning `Instance`.
//!
//! Funcref slots surface as an opaque `?u64` inside a `.funcref`
//! `Value` (null = empty slot); the host cannot yet *call* that
//! funcref directly (a callable funcref handle is a deeper, separate
//! enhancement — D-269). Externref slots round-trip the host's opaque
//! u64 handle.

const _runtime = @import("../runtime/runtime.zig");
const _runner = @import("../engine/runner.zig"); // ADR-0200 JIT engine (Zone 2; `lib`-exempt)
const _zir = @import("../ir/zir.zig");
const _zwasm = @import("../zwasm.zig");
const _vc = @import("value_conv.zig");

pub const Table = struct {
    /// Engine the table storage lives in (ADR-0200 increment 5). Interp uses
    /// `Runtime.tables[i].refs` (a `[]Value`); JIT uses the flat
    /// `JitRuntime.tables_ptr[i].refs` (`[*]u64`, each a `Value.ref` encoding).
    backing: Backing,
    table_idx: u32,
    elem_type: _zir.ValType,
    /// Declared upper bound (`null` = unbounded); enforced by `grow`.
    max: ?u32,

    pub const Backing = union(enum) {
        interp: *_runtime.Runtime,
        jit: *_runner.JitInstance,
    };

    pub const Error = error{ OutOfBounds, GrowFailed };

    /// Wasm spec §4.4.7 (table.size) — current slot count.
    pub fn size(self: Table) u32 {
        return switch (self.backing) {
            .interp => |rt| @intCast(rt.tables[self.table_idx].refs.len),
            .jit => |jit| jit.owned.rt.tables_ptr[self.table_idx].len,
        };
    }

    /// Wasm spec §4.4.6 (table.get) — read the ref at `idx`, marshalled
    /// to a facade `Value` per the table's elem-type.
    pub fn get(self: Table, idx: u32) Error!_zwasm.Value {
        switch (self.backing) {
            .interp => |rt| {
                const tab = rt.tables[self.table_idx];
                if (idx >= tab.refs.len) return error.OutOfBounds;
                return _vc.runtimeToZwasm(tab.refs[idx], self.elem_type);
            },
            .jit => |jit| {
                const ts = jit.owned.rt.tables_ptr[self.table_idx];
                if (idx >= ts.len) return error.OutOfBounds;
                // refs[i] carries the same `Value.ref` encoding as interp.
                return _vc.runtimeToZwasm(.{ .ref = ts.refs[idx] }, self.elem_type);
            },
        }
    }

    /// Wasm spec §4.4.6 (table.set) — write `val` into slot `idx`.
    pub fn set(self: Table, idx: u32, val: _zwasm.Value) Error!void {
        switch (self.backing) {
            .interp => |rt| {
                const tab = &rt.tables[self.table_idx];
                if (idx >= tab.refs.len) return error.OutOfBounds;
                tab.refs[idx] = _vc.zwasmToRuntime(val);
            },
            .jit => |jit| {
                const descs = @constCast(jit.owned.rt.tables_ptr);
                const ts = &descs[self.table_idx];
                if (idx >= ts.len) return error.OutOfBounds;
                // D-478: a funcref slot also has a parallel `funcptrs[]` native-entry
                // mirror (ADR-0068) the guest `table.set` op keeps in sync; the host
                // cannot synthesise that native entry from an encoded funcref here.
                // externref tables have no mirror (zero sentinel) → safe to write.
                if (@intFromPtr(ts.funcptrs) != 0)
                    @panic("Table.set on a JIT funcref table needs the funcptrs mirror (D-478)");
                ts.refs[idx] = _vc.zwasmToRuntime(val).ref;
            },
        }
    }

    /// Wasm spec §4.4.7 (table.grow) — append `delta` slots filled with
    /// `init`, honouring the declared `max`. Mirrors `wasm_table_grow`'s
    /// realloc semantics (`src/api/instance.zig`); `error.GrowFailed`
    /// on a max-limit breach or allocator failure.
    pub fn grow(self: Table, delta: u32, init: _zwasm.Value) Error!void {
        switch (self.backing) {
            .interp => |rt| {
                const tab = &rt.tables[self.table_idx];
                const old_len = tab.refs.len;
                const new_len = old_len + delta;
                if (self.max) |m| {
                    if (new_len > m) return error.GrowFailed;
                }
                // D-316: honour a host element cap (set via `Instance.setTableElementsLimit`),
                // mirroring how `Memory.grow` honours `store_memory_pages_max`.
                if (rt.store_table_elements_max) |cap| {
                    if (new_len > cap) return error.GrowFailed;
                }
                const grown = rt.alloc.realloc(tab.refs, new_len) catch return error.GrowFailed;
                const fill = _vc.zwasmToRuntime(init);
                for (grown[old_len..new_len]) |*slot| slot.* = fill;
                tab.refs = grown;
            },
            .jit => |jit| {
                // `jitTableGrow` honours the declared/host caps and rejects funcref
                // tables (no host-synthesisable funcptr mirror) → `GrowFailed`.
                const fill = _vc.zwasmToRuntime(init).ref;
                if (jit.growTable(self.table_idx, fill, delta) == null) return error.GrowFailed;
            },
        }
    }
};

const std = @import("std");
const testing = std.testing;

test "Table engine=.jit: externref get/set/size/grow through the live tables_ptr (ADR-0200 incr 5)" {
    // (module (table (export "t") 2 4 externref)
    //         (func (export "f") (result i32) i32.const 0))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: ()->i32
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x04, 0x05, 0x01, 0x6f, 0x01, 0x02, 0x04, // table: externref, min 2, max 4
        0x07, 0x09, 0x02, 0x01, 't', 0x01, 0x00, 0x01, 'f', 0x00, 0x00, // exports "t"(table0) "f"(func0)
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x00, 0x0b, // code: i32.const 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();
    try testing.expect(inst.handle.runtime == null); // JIT-backed

    var t = inst.table("t").?;
    try testing.expectEqual(@as(u32, 2), t.size());
    // empty externref slot reads as null.
    try testing.expectEqual(@as(?u64, null), (try t.get(0)).externref);
    // host writes a handle; reads it back through the live tables_ptr.
    try t.set(1, .{ .externref = 0x1234 });
    try testing.expectEqual(@as(?u64, 0x1234), (try t.get(1)).externref);
    // out-of-bounds get/set are rejected.
    try testing.expectError(error.OutOfBounds, t.get(2));
    try testing.expectError(error.OutOfBounds, t.set(2, .{ .externref = 1 }));
    // grow within the declared max (4) appends null-filled slots.
    try t.grow(1, .{ .externref = null });
    try testing.expectEqual(@as(u32, 3), t.size());
    try testing.expectEqual(@as(?u64, null), (try t.get(2)).externref);
    // grow past the declared max (4) → refused.
    try testing.expectError(error.GrowFailed, t.grow(5, .{ .externref = null }));
}

test "Table engine=.jit: a NO-MAX table grows within a synthesized cap (D-501)" {
    // (module (table (export "t") 1 externref))  — declared WITHOUT a max.
    // The baked-base JIT pre-allocates each table to its cap; a no-max table used
    // to get min-only headroom → any grow failed under the JIT (stricter than
    // wasmtime/wasmer/wazero which realloc, and than WAMR which synthesizes a
    // default cap). D-501: synthesize a WAMR-style cap so no-max grow works.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x04, 0x04, 0x01, 0x6f, 0x00, 0x01, // table: externref, min 1, NO max
        0x07, 0x05, 0x01, 0x01, 't', 0x01, 0x00, // export "t" (table 0)
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();
    try testing.expect(inst.handle.runtime == null); // JIT-backed

    var t = inst.table("t").?;
    try testing.expectEqual(@as(u32, 1), t.size());
    try t.set(0, .{ .externref = 0xBEEF });
    // Grow well within the synthesized cap — succeeds (was error.GrowFailed).
    try t.grow(3, .{ .externref = null }); // 1 → 4
    try testing.expectEqual(@as(u32, 4), t.size());
    try testing.expectEqual(@as(?u64, 0xBEEF), (try t.get(0)).externref); // preserved
    try testing.expectEqual(@as(?u64, null), (try t.get(3)).externref);
}
