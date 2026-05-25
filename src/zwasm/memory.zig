//! `Memory` — typed view onto an instance's linear memory per
//! ADR-0109 §3.4 + `docs/zig_api_design.md` §3.4.
//!
//! Wraps the runtime's flat `memory: []u8` slice (Wasm spec §4.2.8)
//! so Zig hosts can read / write typed scalars through it without
//! going through `wasm_memory_t*`. v0.1 scope: scalar integer
//! read / write + raw byte slice. `grow` and v128 lane access
//! land in J.5+ (`docs/zig_api_design.md` §3.4 / Phase 10.M).

const std = @import("std");

const _runtime = @import("../runtime/runtime.zig");

pub const Memory = struct {
    rt: *_runtime.Runtime,

    pub const Error = error{ OutOfBoundsLoad, OutOfBoundsStore };

    /// Wasm spec §4.2.8 — returns the raw underlying byte slice.
    /// Lifetime ties to the owning `Instance`.
    pub fn slice(self: Memory) []u8 {
        return self.rt.memory;
    }

    /// Wasm spec §4.4.7 — page size 65536 bytes.
    pub fn size(self: Memory) u32 {
        return @intCast(self.rt.memory.len / 65536);
    }

    /// Wasm spec §4.4.7 (memory.load) — little-endian typed read.
    /// Supported `T`: i8 / u8 / i16 / u16 / i32 / u32 / i64 / u64 /
    /// f32 / f64. The float types round-trip via bit-cast (no NaN
    /// canonicalisation per ADR-0109 §3.4 + `zig_api_design.md` §4.3).
    pub fn read(self: Memory, comptime T: type, addr: u32) Error!T {
        const sz = @sizeOf(T);
        const mem = self.rt.memory;
        if (@as(u64, addr) + sz > mem.len) return error.OutOfBoundsLoad;
        const bytes = mem[addr..][0..sz];
        return switch (T) {
            f32 => @bitCast(std.mem.readInt(u32, bytes, .little)),
            f64 => @bitCast(std.mem.readInt(u64, bytes, .little)),
            else => std.mem.readInt(T, bytes, .little),
        };
    }

    /// Wasm spec §4.4.7 (memory.store) — little-endian typed write.
    pub fn write(self: Memory, addr: u32, val: anytype) Error!void {
        const T = @TypeOf(val);
        const sz = @sizeOf(T);
        const mem = self.rt.memory;
        if (@as(u64, addr) + sz > mem.len) return error.OutOfBoundsStore;
        const bytes = mem[addr..][0..sz];
        switch (T) {
            f32 => std.mem.writeInt(u32, bytes, @bitCast(val), .little),
            f64 => std.mem.writeInt(u64, bytes, @bitCast(val), .little),
            else => std.mem.writeInt(T, bytes, val, .little),
        }
    }
};
