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
const _zir = @import("../ir/zir.zig");
const _zwasm = @import("../zwasm.zig");
const _vc = @import("value_conv.zig");

pub const Table = struct {
    rt: *_runtime.Runtime,
    table_idx: u32,
    elem_type: _zir.ValType,
    /// Declared upper bound (`null` = unbounded); enforced by `grow`.
    max: ?u32,

    pub const Error = error{ OutOfBounds, GrowFailed };

    /// Wasm spec §4.4.7 (table.size) — current slot count.
    pub fn size(self: Table) u32 {
        return @intCast(self.rt.tables[self.table_idx].refs.len);
    }

    /// Wasm spec §4.4.6 (table.get) — read the ref at `idx`, marshalled
    /// to a facade `Value` per the table's elem-type.
    pub fn get(self: Table, idx: u32) Error!_zwasm.Value {
        const tab = self.rt.tables[self.table_idx];
        if (idx >= tab.refs.len) return error.OutOfBounds;
        return _vc.runtimeToZwasm(tab.refs[idx], self.elem_type);
    }

    /// Wasm spec §4.4.6 (table.set) — write `val` into slot `idx`.
    pub fn set(self: Table, idx: u32, val: _zwasm.Value) Error!void {
        const tab = &self.rt.tables[self.table_idx];
        if (idx >= tab.refs.len) return error.OutOfBounds;
        tab.refs[idx] = _vc.zwasmToRuntime(val);
    }

    /// Wasm spec §4.4.7 (table.grow) — append `delta` slots filled with
    /// `init`, honouring the declared `max`. Mirrors `wasm_table_grow`'s
    /// realloc semantics (`src/api/instance.zig`); `error.GrowFailed`
    /// on a max-limit breach or allocator failure.
    pub fn grow(self: Table, delta: u32, init: _zwasm.Value) Error!void {
        const tab = &self.rt.tables[self.table_idx];
        const old_len = tab.refs.len;
        const new_len = old_len + delta;
        if (self.max) |m| {
            if (new_len > m) return error.GrowFailed;
        }
        // D-316: honour a host element cap (set via `Instance.setTableElementsLimit`),
        // mirroring how `Memory.grow` honours `store_memory_pages_max`.
        if (self.rt.store_table_elements_max) |cap| {
            if (new_len > cap) return error.GrowFailed;
        }
        const grown = self.rt.alloc.realloc(tab.refs, new_len) catch return error.GrowFailed;
        const fill = _vc.zwasmToRuntime(init);
        for (grown[old_len..new_len]) |*slot| slot.* = fill;
        tab.refs = grown;
    }
};
