//! `Global` — typed accessor onto an instance's exported global per
//! ADR-0109 (D-272). Mirrors `Memory`: holds the runtime pointer plus
//! the export's cached valtype + mutability, and goes through the
//! shared `value_conv` for the runtime⇄facade `Value` mapping. Lifetime
//! ties to the owning `Instance` (the borrowed `*Runtime` stays valid
//! as long as the instance is alive).

const _runtime = @import("../runtime/runtime.zig");
const _runner = @import("../engine/runner.zig"); // ADR-0200 JIT engine (Zone 2; `lib`-exempt)
const _zir = @import("../ir/zir.zig");
const _zwasm = @import("../zwasm.zig");
const _vc = @import("value_conv.zig");

pub const Global = struct {
    /// Engine the cell lives in (ADR-0200 increment 5). Interp dereferences
    /// `Runtime.globals` (a `[]*Value` pointer-slice); JIT indexes the flat
    /// `JitRuntime.globals_base` (`[*]Value`). Both element-deref to the
    /// shared `runtime.value.Value`, so `value_conv` bridges either.
    backing: Backing,
    global_idx: u32,
    valtype: _zir.ValType,
    mutable: bool,

    pub const Backing = union(enum) {
        interp: *_runtime.Runtime,
        jit: *_runner.JitInstance,
    };

    pub const Error = error{Immutable};

    /// Wasm spec §4.5.5 (global.get) — read the current value.
    pub fn get(self: Global) _zwasm.Value {
        const raw = switch (self.backing) {
            .interp => |rt| rt.globals[self.global_idx].*,
            .jit => |jit| jit.owned.rt.globals_base[self.global_idx],
        };
        return _vc.runtimeToZwasm(raw, self.valtype);
    }

    /// Wasm spec §4.5.6 (global.set) — write a new value. Returns
    /// `error.Immutable` for a `const` global rather than silently
    /// dropping the write (the host chooses how to react).
    pub fn set(self: Global, val: _zwasm.Value) Error!void {
        if (!self.mutable) return error.Immutable;
        const rv = _vc.zwasmToRuntime(val);
        switch (self.backing) {
            .interp => |rt| rt.globals[self.global_idx].* = rv,
            .jit => |jit| jit.owned.rt.globals_base[self.global_idx] = rv,
        }
    }
};

const std = @import("std");
const testing = std.testing;

test "Global engine=.jit: get/set the live globals_base cell; guest sees the host write (ADR-0200 incr 5)" {
    // (module (global (export "g") (mut i32) (i32.const 7))
    //         (global (export "c") i32 (i32.const 5))
    //         (func (export "f") (result i32) global.get 0))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: ()->i32
        0x03, 0x02, 0x01, 0x00, // func: type 0
        0x06, 0x0b, 0x02, 0x7f, 0x01, 0x41, 0x07, 0x0b, 0x7f, 0x00, 0x41, 0x05, 0x0b, // globals: g0 mut=7, g1 const=5
        0x07, 0x0d, 0x03, 0x01, 'g', 0x03, 0x00, 0x01, 'c', 0x03, 0x01, 0x01, 'f', 0x00, 0x00, // exports
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b, // code: global.get 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();
    try testing.expect(inst.handle.runtime == null); // JIT-backed

    var g = inst.global("g").?;
    try testing.expectEqual(@as(i32, 7), g.get().i32);
    try g.set(.{ .i32 = 99 });
    try testing.expectEqual(@as(i32, 99), g.get().i32);
    // the JIT-compiled guest body reads the same cell → sees the host write.
    var results = [_]_zwasm.Value{.{ .i32 = 0 }};
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 99), results[0].i32);

    // const global resolves mutable=false → set is rejected, read still works.
    const c = inst.global("c").?;
    try testing.expectEqual(@as(i32, 5), c.get().i32);
    try testing.expectError(error.Immutable, c.set(.{ .i32 = 1 }));
}
