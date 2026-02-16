# Getting Started

This guide gets you from zero to running a WebAssembly module in under 5 minutes.

## Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) or later

## Install

### Build from source

```bash
git clone https://github.com/syumai/zwasm.git
cd zwasm
zig build -Doptimize=ReleaseSafe
```

The binary is at `zig-out/bin/zwasm`. Copy it to your PATH:

```bash
cp zig-out/bin/zwasm ~/.local/bin/
```

### Verify installation

```bash
zwasm version
```

## Run your first module

### 1. From a WAT file

Create `hello.wat`:

```wat
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add))
```

Run it:

```bash
zwasm run --invoke add hello.wat 2 3
# Output: 5
```

### 2. WASI module

For modules that use WASI (filesystem, stdout, etc.):

```bash
zwasm run --allow-all hello_wasi.wasm
```

Grant only the capabilities you need:

```bash
zwasm run --allow-read --dir ./data hello_wasi.wasm
```

### 3. Inspect a module

See what a module exports and imports:

```bash
zwasm inspect hello.wasm
```

### 4. Validate a module

Check if a module is valid without running it:

```bash
zwasm validate hello.wasm
```

## Use as a Zig library

Add zwasm as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .zwasm = .{
        .url = "https://github.com/syumai/zwasm/archive/refs/tags/v0.3.0.tar.gz",
        .hash = "...",  // zig build will tell you the correct hash
    },
},
```

Then in `build.zig`:

```zig
const zwasm_dep = b.dependency("zwasm", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zwasm", zwasm_dep.module("zwasm"));
```

See the [Embedding Guide](./embedding-guide.md) for API usage.

## Next steps

- [CLI Reference](./cli-reference.md) — all commands and flags
- [Embedding Guide](./embedding-guide.md) — use zwasm as a Zig library
- [Spec Coverage](./spec-coverage.md) — supported Wasm proposals
