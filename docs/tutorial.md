# Getting started

A short walkthrough: build the CLI, run + compile a module, then embed
zwasm as a library from Zig and C. Reference docs:
[`docs/reference/`](reference/).

## 1. Build

zwasm pins Zig 0.16.0 via Nix:

```sh
direnv allow          # loads the flake dev shell (Zig 0.16.0 + tools)
zig build             # builds the `zwasm` binary into zig-out/bin/
zig build test        # unit tests
```

(Without Nix, install Zig 0.16.0 yourself; the toolchain for generating
realworld `.wasm` fixtures is Mac-only via `nix develop .#gen`.)

## 2. Run a module (CLI)

```sh
zwasm run hello.wasm                 # WASI _start / main; exits with proc_exit code
zwasm run --invoke add hello.wasm    # run a named export instead (zero-arg)
zwasm run --invoke 'add=2,3' math.wasm   # pass typed args; prints the result (→ 5)
zwasm run --dir .:/ guest.wasm       # preopen the cwd as the guest's /
```

The default engine is the interpreter. `--engine jit` runs the JIT, which
does full WASI too and additionally executes SIMD. Full flags:
[`reference/cli.md`](reference/cli.md).

## 3. Compile ahead-of-time

```sh
zwasm compile hello.wasm -o hello.cwasm   # produce an AOT artifact
zwasm run hello.cwasm                      # load + run it directly
```

## 4. Embed in Zig

Add zwasm to your `build.zig.zon` `.dependencies` (a `path`/`url` dep),
then in `build.zig`:

```zig
const zw = b.dependency("zwasm", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zwasm", zw.module("zwasm"));
```

Then drive it (Engine → compile → instantiate → call):

```zig
const zwasm = @import("zwasm");

var eng = try zwasm.Engine.init(alloc, .{});
defer eng.deinit();
var mod = try eng.compile(&wasm_bytes);
defer mod.deinit();
var inst = try mod.instantiate(.{});
defer inst.deinit();

const add = inst.typedFunc(fn (i32, i32) i32, "add");
std.debug.print("{d}\n", .{try add.call(.{ 2, 40 })}); // 42
```

To provide **host imports**, build a `Linker` and `defineFunc` (the
Wasm signature is comptime-derived from your Zig fn; first param is
`*zwasm.Caller`):

```zig
fn hostAdd(_: *zwasm.Caller, a: i32, b: i32) i32 { return a + b; }
// ...
var lk = zwasm.Linker.init(&eng);
defer lk.deinit();
try lk.defineFunc("env", "add", fn (*zwasm.Caller, i32, i32) i32, hostAdd);
var inst = try lk.instantiate(&mod);
```

Runnable: [`examples/zig_dep/`](../examples/zig_dep/) (external path-dep
consumer, exercises the full surface) and
[`examples/zig_host/`](../examples/zig_host/). Surface reference:
[`reference/zig_api.md`](reference/zig_api.md).

## 5. Embed in C

zwasm implements the standard wasm-c-api ([`include/wasm.h`](../include/wasm.h)).
A C host that drives any wasm-c-api runtime drives zwasm unchanged; WASI
is configured via [`include/wasi.h`](../include/wasi.h). Runnable:
[`examples/c_host/`](../examples/c_host/). Reference:
[`reference/c_api.md`](reference/c_api.md).

## 6. Migrating from v1

v2 breaks v1's ABI by design. See
[`migration_v1_to_v2.md`](migration_v1_to_v2.md).
