---
paths:
  - "src/**/*.zig"
  - "build.zig"
---

# Zone Dependency Rules

Auto-loaded when editing Zig source. Authoritative version of the
layering contract in ROADMAP §4.1 / §A1.

## Zone architecture

```
Zone 3: src/cli/, src/main.zig         -- CLI entry, argparse, subcommand
        src/c_api/                      -- C ABI export layer (wasm.h / wasi.h / zwasm.h)
                                        ↓ may import anything below

Zone 2: src/interp/                     -- Threaded-code interpreter
        src/jit/                        -- Shared JIT (regalloc, reg_class, prologue, emit_common, aot)
        src/jit_arm64/                  -- ARM64-specific emit
        src/jit_x86/                    -- x86-specific emit
        src/wasi/                       -- WASI 0.1 implementation
                                        ↓ may import Zone 0+1

Zone 1: src/ir/                         -- ZIR + verifier + analysis
        src/runtime/                    -- Module / Instance / Store / Memory / Trap / Float / Value / GC
        src/frontend/                   -- Parser / Validator / Lowerer (wasm body → ZIR)
        src/feature/                    -- Per-spec-feature modules (registered into dispatch tables)
                                        ↓ may import Zone 0 only

Zone 0: src/util/                       -- LEB128, duration, hash, sort
        src/platform/                   -- Linux / Darwin / Windows / POSIX abstractions
                                        ↑ imports nothing above
```

## NEVER: upward imports

```
util/ + platform/  must NOT import from ir/, runtime/, frontend/, feature/, interp/, jit*/, wasi/, c_api/, cli/
ir/ + runtime/ + frontend/ + feature/  must NOT import from interp/, jit*/, wasi/, c_api/, cli/
interp/ + jit*/ + wasi/  must NOT import from c_api/, cli/
```

## Inter-zone-2 isolation

`jit_arm64/` and `jit_x86/` must NOT import from each other (A3).
Both share via `jit/` only. This keeps the per-arch backend
independent and discoverable; cross-arch dependency would defeat
the W54-class bug detection design.

## Feature module direction

`src/feature/<feature>/mod.zig` registers handlers into central
dispatch tables (`src/ir/dispatch_table.zig`). The main parser /
validator / interp / emitter NEVER `@import` a specific feature
module — they consult the dispatch table only. This is what enables
ROADMAP §4.5 / A12 (no pervasive build-time `if`-branching).

## When a lower zone needs to call a higher zone

Use the **VTable pattern**: the lower zone declares the type, the
higher zone injects function pointers at startup.

```zig
// Layer 0 (runtime/) declares only the type
pub const VTable = struct {
    exec: *const fn(*Instance, FuncIdx, []const Value) anyerror![]Value,
    compile: *const fn(*Instance, FuncIdx) anyerror!void,
};

// Layer 2 (interp/ or jit/) installs at startup
runtime.vtable = .{
    .exec = interp.exec,
    .compile = jit.compile,
};
```

This inverts the *compile-time* dependency direction while
preserving the logical call flow.

## Enforcement

`scripts/zone_check.sh` parses every `@import("…/foo.zig")` in the
source tree and flags upward-direction violations and cross-arch
imports (A3).

- `bash scripts/zone_check.sh` — informational; always exits 0.
- `bash scripts/zone_check.sh --strict` — exit 1 on any violation.
- `bash scripts/zone_check.sh --gate` — exit 1 if violation count
  exceeds the in-script BASELINE (currently 0).

Tests are exempt: everything after the first `test "…"` line in a
file is skipped (test code may legitimately cross zones).
