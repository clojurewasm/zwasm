# Getting Started

This guide gets you from zero to running a WebAssembly module in under 5 minutes.

## Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) or later

## Install

### Build from source

```bash
git clone https://github.com/clojurewasm/zwasm.git
cd zwasm
zig build -Doptimize=ReleaseSafe
```

The binary is at `zig-out/bin/zwasm`. Copy it to your PATH:

```bash
cp zig-out/bin/zwasm ~/.local/bin/
```

### Install script

```bash
curl -fsSL https://raw.githubusercontent.com/clojurewasm/zwasm/main/install.sh | bash
```

### Homebrew (macOS/Linux)

```bash
brew install clojurewasm/tap/zwasm
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
zwasm hello.wat --invoke add 2 3
# Output: 5
```

### 2. WASI module

For modules that use WASI (filesystem, stdout, etc.):

```bash
zwasm hello_wasi.wasm --allow-all
```

Grant only the capabilities you need:

```bash
zwasm hello_wasi.wasm --allow-read --dir ./data
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
        .url = "https://github.com/clojurewasm/zwasm/archive/refs/tags/v0.3.0.tar.gz",
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

## More examples

The repository includes 33 numbered WAT examples in `examples/wat/`, ordered from beginner to advanced:

```bash
zwasm examples/wat/01_hello_add.wat --invoke add 2 3      # basics
zwasm examples/wat/02_if_else.wat --invoke abs -7          # if/else
zwasm examples/wat/03_loop.wat --invoke sum 100            # loops → 5050
zwasm examples/wat/05_fibonacci.wat --invoke fib 10        # recursion → 55
zwasm examples/wat/24_call_indirect.wat --invoke apply 0 10 3  # tables → 13
zwasm examples/wat/25_return_call.wat --invoke sum 1000000 # tail calls
zwasm examples/wat/30_wasi_hello.wat --allow-all           # WASI → Hi!
zwasm examples/wat/32_wasi_args.wat --allow-all -- hi      # WASI args
```

Each file includes run instructions in its header comment. Zig embedding examples are in `examples/zig/`.

## Next steps

- [CLI Reference](./cli-reference.md) — all commands and flags
- [Embedding Guide](./embedding-guide.md) — use zwasm as a Zig library
- [Spec Coverage](./spec-coverage.md) — supported Wasm proposals
