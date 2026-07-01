//! Minimal external consumer of zwasm v2's native Zig embedding API
//! (ADR-0109): Engine → compile → instantiate → typedFunc().call(), plus
//! the host-import path (Linker.defineFunc + Caller). Imported through the
//! package boundary (`@import("zwasm")` resolves to the path-dep's public
//! module), unlike `docs/examples/zig_host/` which shares the in-repo private
//! module. Proves true library consumability of the full embedding surface
//! (§16.5 dogfooding).

const std = @import("std");
const zwasm = @import("zwasm");
const Caller = zwasm.Caller;

// (module (func (export "add") (param i32 i32) (result i32)
//   local.get 0  local.get 1  i32.add))
const add_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0a, 0x09,
    0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a,
    0x0b,
};

// (module (import "env" "add" (func (param i32 i32) (result i32)))
//   (func (export "go") (param i32 i32) (result i32)
//     local.get 0  local.get 1  call 0))
const host_add_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x02, 0x0b, 0x01, 0x03, 0x65, 0x6e, 0x76,
    0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x03, 0x02,
    0x01, 0x00, 0x07, 0x06, 0x01, 0x02, 0x67, 0x6f,
    0x00, 0x01, 0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20,
    0x00, 0x20, 0x01, 0x10, 0x00, 0x0b,
};

// (module (memory (export "mem") 1))
const mem_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x07, 0x01,
    0x03, 0x6d, 0x65, 0x6d, 0x02, 0x00,
};

// (module (global (export "counter") (mut i32) (i32.const 7)))
const global_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x07, 0x0b,
    0x07, 0x0b, 0x01, 0x07, 0x63, 0x6f, 0x75, 0x6e,
    0x74, 0x65, 0x72, 0x03, 0x00,
};

// (module (table (export "t") 2 8 externref))
// Bounded max (8) so `table.grow` works under BOTH engines: the JIT
// pre-allocates a table to its declared max, so a no-max table has no JIT
// grow headroom (interp-only grow — tracked as D-501). A max makes the demo
// engine-agnostic under the default `.auto` (JIT-preferring) engine.
const table_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x04, 0x05, 0x01, 0x6f, 0x01, 0x02, 0x08, 0x07,
    0x05, 0x01, 0x01, 0x74, 0x01, 0x00,
};

fn hostAdd(_: *Caller, a: i32, b: i32) i32 {
    return a +% b;
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var eng = try zwasm.Engine.init(alloc, .{});
    defer eng.deinit();

    // (1) Direct export call via a comptime-typed function handle.
    {
        var mod = try eng.compile(&add_wasm);
        defer mod.deinit();
        var inst = try mod.instantiate(.{});
        defer inst.deinit();

        const add = inst.typedFunc(fn (i32, i32) i32, "add");
        const r = try add.call(.{ 2, 40 });
        std.debug.print("zwasm zig_dep: add(2, 40) = {d}\n", .{r});
        if (r != 42) std.process.exit(2);
    }

    // (2) Host-import round-trip: the guest imports `env.add`, the host
    // supplies it via Linker.defineFunc, and `go` calls back into it.
    {
        var mod = try eng.compile(&host_add_wasm);
        defer mod.deinit();

        var lk = zwasm.Linker.init(&eng);
        defer lk.deinit();
        try lk.defineFunc("env", "add", fn (*Caller, i32, i32) i32, hostAdd);

        var inst = try lk.instantiate(&mod, .{});
        defer inst.deinit();

        const go = inst.typedFunc(fn (i32, i32) i32, "go");
        const r = try go.call(.{ 4, 7 });
        std.debug.print("zwasm zig_dep: go(4, 7) via host env.add = {d}\n", .{r});
        if (r != 11) std.process.exit(3);
    }

    // (3) Linear-memory access from the host via the Memory facade.
    {
        var mod = try eng.compile(&mem_wasm);
        defer mod.deinit();
        var inst = try mod.instantiate(.{});
        defer inst.deinit();

        const mem = inst.memory() orelse std.process.exit(4);
        try mem.write(0x100, @as(i32, 1234));
        const got = try mem.read(i32, 0x100);
        std.debug.print("zwasm zig_dep: memory[0x100] = {d} ({d} page(s))\n", .{ got, mem.size() });
        if (got != 1234) std.process.exit(5);
    }

    // (4) Read + write an exported global via the Global accessor (D-272).
    {
        var mod = try eng.compile(&global_wasm);
        defer mod.deinit();
        var inst = try mod.instantiate(.{});
        defer inst.deinit();

        const counter = inst.global("counter") orelse std.process.exit(6);
        try counter.set(.{ .i32 = counter.get().i32 + 35 });
        const v = counter.get().i32;
        std.debug.print("zwasm zig_dep: global counter = {d}\n", .{v});
        if (v != 42) std.process.exit(7);
    }

    // (5) Read/write/grow an exported table via the Table accessor (D-272).
    {
        var mod = try eng.compile(&table_wasm);
        defer mod.deinit();
        var inst = try mod.instantiate(.{});
        defer inst.deinit();

        const t = inst.table("t") orelse std.process.exit(8);
        try t.set(1, .{ .externref = 0xCAFE });
        try t.grow(2, .{ .externref = null });
        const slot = (try t.get(1)).externref orelse std.process.exit(9);
        std.debug.print("zwasm zig_dep: table[1]=0x{x} size={d}\n", .{ slot, t.size() });
        if (slot != 0xCAFE or t.size() != 4) std.process.exit(10);
    }
}
