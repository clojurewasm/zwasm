# zwasm Public API Boundary

Defines the stable public surface of `@import("zwasm")`.
Types and functions listed here are covered by SemVer guarantees.

## Stable types

| Type | Description | Since |
|------|-------------|-------|
| `WasmModule` | Load, execute, and manage a Wasm module | v0.1.0 |
| `WasmFn` | Bound wrapper for an exported function | v0.1.0 |
| `WasmValType` | Enum of Wasm value types (i32, i64, f32, f64, v128, funcref, externref) | v0.1.0 |
| `ExportInfo` | Metadata for an exported function (name, param/result types) | v0.1.0 |
| `ImportEntry` | Maps an import module name to a source | v0.2.0 |
| `ImportSource` | Union: wasm_module or host_fns | v0.2.0 |
| `HostFnEntry` | A single host function (name, callback, context) | v0.2.0 |
| `HostFn` | Function type: `fn (*anyopaque, usize) anyerror!void` | v0.2.0 |
| `ImportFuncInfo` | Import metadata (module, name, param/result count) | v0.2.0 |
| `WasiOptions` | WASI configuration (args, env, preopen, capabilities). Default caps: `cli_default` | v0.2.0 |
| `Capabilities` | WASI capability flags (presets: `all`, `cli_default`, `sandbox`) | v1.0.0 |
| `Vm` | VM type for host function callbacks | v0.2.0 |

## Stable functions

### WasmModule

| Method | Signature | Since |
|--------|-----------|-------|
| `load` | `(Allocator, []const u8) !*WasmModule` | v0.1.0 |
| `loadFromWat` | `(Allocator, []const u8) !*WasmModule` | v0.2.0 |
| `loadWasi` | `(Allocator, []const u8) !*WasmModule` | v0.2.0 |
| `loadWasiWithOptions` | `(Allocator, []const u8, WasiOptions) !*WasmModule` | v0.2.0 |
| `loadWithImports` | `(Allocator, []const u8, []const ImportEntry) !*WasmModule` | v0.2.0 |
| `loadWasiWithImports` | `(Allocator, []const u8, []const ImportEntry, WasiOptions) !*WasmModule` | v0.2.0 |
| `loadWithFuel` | `(Allocator, []const u8, u64) !*WasmModule` | v0.3.0 |
| `deinit` | `(*WasmModule) void` | v0.1.0 |
| `invoke` | `(*WasmModule, []const u8, []u64, []u64) !void` | v0.1.0 |
| `memoryRead` | `(*WasmModule, Allocator, u32, u32) ![]const u8` | v0.2.0 |
| `memoryWrite` | `(*WasmModule, u32, []const u8) !void` | v0.2.0 |
| `getExportInfo` | `(*WasmModule, []const u8) ?ExportInfo` | v0.2.0 |
| `getExportFn` | `(*WasmModule, []const u8) ?*const WasmFn` | v0.2.0 |
| `getWasiExitCode` | `(*WasmModule) ?u32` | v0.2.0 |
| `registerExports` | `(*WasmModule, []const u8) !void` | v0.3.0 |

### WasmFn

| Method | Signature | Since |
|--------|-----------|-------|
| `invokeRaw` | `(*const WasmFn, []u64, []u64) !void` | v0.2.0 |

### Free functions

| Function | Signature | Since |
|----------|-----------|-------|
| `inspectImportFunctions` | `(Allocator, []const u8) ![]const ImportFuncInfo` | v0.2.0 |

## Experimental (may change)

| Type/Function | Description |
|---------------|-------------|
| `runtime.Store` | Internal store for cross-module testing |
| `runtime.Module` | Internal decoded module |
| `runtime.Instance` | Internal instance |
| `runtime.VmImpl` | Internal VM implementation |
| `WasmModule.loadLinked` | Two-phase instantiation with shared store |
| `WasmModule.registerExportsTo` | Register to external store |
| `WasmModule.setWitInfo` | Attach WIT metadata |
| `WasmModule.getWitFunc` | Lookup WIT function |
| `WasmFn.cabiRealloc` | Component Model memory realloc |

## Internal (not exported)

All types in `src/` files other than `types.zig` are internal and not accessible
to library consumers. They may change without notice.
