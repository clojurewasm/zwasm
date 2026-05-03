---
paths:
  - "src/**/*.zig"
  - "build.zig"
---

# Zig 0.16.0 idioms (project rules)

Auto-loaded when editing Zig source. **AI assistants tend to revert to
pre-0.16 (often pre-0.14) APIs by default — consult this list before
typing any stdlib reference.** When in doubt, grep
`/nix/store/*-zig-0.16.0/lib/std/` for the canonical surface.

## 0.14 → 0.16 removals & renames (must-know)

These are the patterns that compile-fail (or fail silently via deprecated
shim) but AI training corpora overwhelmingly use the old names. Memorise.

| Removed / renamed (0.14 / 0.15)                                         | Use in 0.16.0                                                                                                                  | Notes                                                                                   |
|-------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| `std.io` (lowercase namespace)                                          | `std.Io` (capital I)                                                                                                           | `std.io` namespace effectively gone; `std.Io` is the only canonical module              |
| `std.io.AnyWriter` / `AnyReader`                                        | `*std.Io.Writer` / `*std.Io.Reader`                                                                                            | Type-erased pointer to concrete vtable type                                             |
| `std.io.fixedBufferStream(&buf)`                                        | `var w: std.Io.Writer = .fixed(&buf);`                                                                                         | Reader: `var r: std.Io.Reader = .fixed(&buf);`                                          |
| `std.io.getStdOut/Err/In`                                               | `std.Io.File.stdout/stderr/stdin()`                                                                                            | Returns `File`, then `.writer(io, &buf).interface`                                      |
| `std.io.bufferedWriter` / `BufferedWriter`                              | `file.writer(io, &buf)`                                                                                                        | Buffer is the user-supplied byte slice                                                  |
| `std.io.tty.*`                                                          | `std.Io.Terminal`                                                                                                              | TTY detection / colour                                                                  |
| `list.writer().any()` (allocating)                                      | `var aw: std.Io.Writer.Allocating = .init(alloc);` then `&aw.writer`                                                           | `aw.toOwnedSlice()` extracts                                                            |
| `std.fs.File` (and `.OpenError` / `.Writer` / etc.)                     | `std.Io.File`                                                                                                                  | All file ops now take `io: std.Io`                                                      |
| `std.fs.cwd()`                                                          | `std.Io.Dir.cwd()`                                                                                                             | —                                                                                      |
| `std.fs.openFileAbsolute(path, ...)`                                    | `std.Io.Dir.cwd().openFile(io, path, ...)`                                                                                     | `io` arg now mandatory                                                                  |
| `std.fs.Dir`                                                            | `std.Io.Dir`                                                                                                                   | All dir ops take `io: std.Io`                                                           |
| `std.fs.path.*`                                                         | `std.Io.Dir.path.*`                                                                                                            | `std.fs.path` left as deprecated re-export                                              |
| `std.fs.max_path_bytes` / `max_name_bytes`                              | `std.Io.Dir.max_path_bytes` / `.max_name_bytes`                                                                                | —                                                                                      |
| `std.Thread.Mutex` / `RwLock` / `Condition` / `Semaphore` / `WaitGroup` | `std.Io.Mutex` / `Io.RwLock` / `Io.Semaphore` (with `io: Io` arg), or `std.atomic.Mutex` (lock-free `tryLock` / `unlock` only) | **All `std.Thread.*` sync primitives are gone**                                         |
| `std.heap.GeneralPurposeAllocator(.{})`                                 | `std.heap.DebugAllocator(.{})`                                                                                                 | Same config struct, renamed                                                             |
| `std.mem.copy(T, dest, src)`                                            | `@memcpy(dest, src)` (or `@memmove` if overlapping; or `std.mem.copyForwards` / `copyBackwards` for explicit direction)        | `mem.copy` removed                                                                      |
| `std.mem.indexOf`                                                       | `std.mem.find`                                                                                                                 | —                                                                                      |
| `std.mem.lastIndexOf`                                                   | `std.mem.findLastLinear`                                                                                                       | —                                                                                      |
| `std.mem.indexOfScalar`                                                 | `std.mem.findScalar`                                                                                                           | —                                                                                      |
| `std.mem.lastIndexOfScalar`                                             | `std.mem.findScalarLast`                                                                                                       | —                                                                                      |
| `std.mem.indexOfScalarPos`                                              | `std.mem.findScalarPos`                                                                                                        | —                                                                                      |
| `std.mem.indexOfAny` / `lastIndexOfAny` / `indexOfAnyPos`               | `findAny` / `findLastAny` / `findAnyPos`                                                                                       | —                                                                                      |
| `std.mem.indexOfNone` / `lastIndexOfNone`                               | `findNone` / `findLastNone`                                                                                                    | —                                                                                      |
| `std.mem.indexOfDiff`                                                   | `std.mem.findDiff`                                                                                                             | —                                                                                      |
| `std.mem.indexOfSentinel`                                               | `std.mem.findSentinel`                                                                                                         | —                                                                                      |
| `std.mem.indexOfPos`                                                    | `std.mem.findPos`                                                                                                              | —                                                                                      |
| `std.mem.containsAtLeastScalar(...)`                                    | `std.mem.containsAtLeastScalar2(...)`                                                                                          | Signature changed                                                                       |
| `std.meta.Int(.signed, n)` / `std.meta.Int(.unsigned, n)`               | `@Int(.signed, n)` / `@Int(.unsigned, n)`                                                                                      | Now a builtin in 0.16; `std.meta.Int` is a deprecated wrapper                           |
| `std.mem.readPackedIntNative` / `*Foreign` (read+write)                 | `readPackedInt(T, bytes, bit_offset, .native)` (or `.foreign`)                                                                 | Unified API                                                                             |
| `std.mem.Alignment` as `u29` int                                        | `enum (Alignment)` — use `.fromByteUnits(n)` / `@enumFromInt`                                                                 | No more `@as(u29, ...)` for alignment                                                   |
| `c_void`                                                                | `anyopaque`                                                                                                                    | C ABI                                                                                   |
| `usingnamespace`                                                        | (removed — no replacement; redesign with explicit re-exports)                                                                 | Compile error in 0.16                                                                   |
| `@intToFloat(T, x)` / `@floatToInt(T, x)`                               | `@floatFromInt(x)` / `@intFromFloat(x)`                                                                                        | Result-location inferred                                                                |
| `@boolToInt(x)`                                                         | `@intFromBool(x)`                                                                                                              | —                                                                                      |
| `@enumToInt(x)` / `@intToEnum(T, x)`                                    | `@intFromEnum(x)` / `@enumFromInt(x)`                                                                                          | —                                                                                      |
| `@errToInt` / `@intToErr`                                               | `@intFromError` / `@errorFromInt`                                                                                              | —                                                                                      |
| `@ptrToInt` / `@intToPtr`                                               | `@intFromPtr` / `@ptrFromInt`                                                                                                  | —                                                                                      |
| `@branch`                                                               | `@branchHint(.likely)` (or `.unlikely` / `.cold`); placed **inside** the branch body                                           | —                                                                                      |
| Old `format(self, comptime fmt, options, writer: anytype)`              | `pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void`                                                     | `{}` → `{f}` at call sites                                                             |
| `std.process.argsAlloc(alloc)` (manual main)                            | `pub fn main(init: std.process.Init)` then `init.minimal.args.iterateAllocator(gpa)`                                           | "Juicy Main": `init` bundles `io / arena / gpa / minimal.args / environ_map / preopens` |
| `Args.Iterator.initAllocator(args, gpa)` (long form)                    | `args.iterateAllocator(gpa)`                                                                                                   | Both compile; the short form is the 0.16 idiom                                          |

## std.mem aliases that still work (informational)

These remain canonical in 0.16, **don't migrate them**:

- `std.mem.eql` / `startsWith` / `endsWith` / `trim` / `trimStart` / `trimEnd`
- `std.mem.splitScalar` / `splitAny` / `splitSequence` (NOT renamed)
- `std.mem.tokenizeScalar` / `tokenizeAny` / `tokenizeSequence` (NOT renamed)
- `std.mem.readInt(T, bytes, .little)` (or `.big`) / `writeInt`
- `@memcpy` / `@memset` / `@memmove` (builtins; replace `mem.copy`)

## Empty `catch`: `catch {}` is the only form Zig 0.16 accepts

Surprising but real. The Zig 0.16 compiler **rejects** the two
"more explicit" forms that AI training data favours:

```zig
something() catch |_| {};                // ERROR: discard of error capture; omit it instead
something() catch |err| { _ = err; };    // ERROR: error set is discarded
something() catch {};                    // OK
```

If a `catch {}` is genuinely the right pattern (best-effort I/O
where there is no recovery and nothing to log to), leave the bare
`catch {}` and add a comment above it explaining *why* swallowing
is fine. Don't try to be cleverer — the compiler has decided.

zlinter's `no_swallow_error` rule flags this pattern, but it is
**not enabled** in our chain (ADR-0009 / Phase B) precisely
because it is mutually unsatisfiable with the compiler. See
`private/zlinter-builtins-survey-2026-05-03.md` for the full
rationale.

## Optionals: `x.?`, not `x orelse unreachable`

The `.?` shorthand is the canonical "definitely-present optional"
in Zig 0.16. It triggers identical safety checks in safe build
modes, costs the same in release modes, and is shorter.

```zig
const arg0 = arg_it.next().?;                     // OK (canonical)
const arg0 = arg_it.next() orelse unreachable;    // gate-rejected (no_orelse_unreachable)
```

The lint chain enforces this (ADR-0009 / Phase B).

## Exhaustive enum `switch`: list every tag, no `else`

For non-extensible enums (almost all project enums), enumerating
every tag is preferred over `else => ...`. When a new tag is added
later, the compiler raises a missing-case error at every switch —
which is exactly the W54-class regression the v2 redesign exists
to prevent.

```zig
return switch (self.kind) {
    .loop => .empty,
    .block, .if_then, .else_open => self.block_type,   // OK
};
```

```zig
return switch (self.kind) {
    .loop => .empty,
    else => self.block_type,                           // gate-rejected
};
```

The lint chain enforces this (`require_exhaustive_enum_switch`,
ADR-0009 / Phase B). Use `else =>` only on non-exhaustive enums
(those declared `enum(T) { ..., _ }`) or external enums whose
tag set we do not own.

## Empty function / `if` body: comment inside

Empty bodies are gate-rejected unless they carry a comment
explaining the intent.

```zig
fn nopOp(_: *InterpCtx, _: *const ZirInstr) anyerror!void {
    // Wasm `nop` — intentionally empty.
}
```

The lint chain enforces this (`no_empty_block`, ADR-0009 /
Phase B). The friction is the point: forces a sentence about
intent at the only moment the author is writing the code.

## Short identifiers (`i`, `n`, `rt`, `ea`) are fine

zlinter's `declaration_naming` rule (length ≥ 3) is **not
enabled** in our chain. WebAssembly / IR / register-allocator
code uses math conventions — `i` for index, `n` for count, `rt`
for runtime, `ea` for effective address. Don't rename them.

## Inferred error sets at the implementation layer are fine

`pub fn main(init: std.process.Init) !void` and internal helpers
that propagate `anyerror!T` are intentional: w-i-d-e error sets
threaded through the interpreter would re-introduce the W54-class
Implicit Contract Sprawl that v2 exists to prevent. zlinter's
`no_inferred_error_unions` rule is **not enabled** in our chain
(ADR-0009 / Phase B not-adopted list).

## `undefined` for fixed-size stack buffers is the canonical idiom

```zig
var operand_buf: [max_operand_stack]Value = undefined;
```

Zero-initializing wastes work; the bookkeeping (cursor / index)
is what guarantees no read-before-write. zlinter's `no_undefined`
rule is **not enabled** for this reason.

## What the lint gate (ADR-0009) actually enforces

`zig build lint -- --max-warnings 0` runs five rules:

| Rule                             | What it catches                           |
|----------------------------------|-------------------------------------------|
| `no_deprecated`                  | any stdlib `/// Deprecated:` reference    |
| `no_orelse_unreachable`          | `x orelse unreachable` instead of `x.?`   |
| `no_empty_block`                 | empty `{}` body without an inside comment |
| `require_exhaustive_enum_switch` | `else =>` on a non-extensible enum        |
| `no_unused`                      | unused `const`, function, import          |

The gate is Mac-host only (per ADR-0009). For the **not-enabled**
rules and why, see `private/zlinter-builtins-survey-2026-05-03.md`.

## tagged union: `switch`, not `==`

```zig
return switch (self) { .nil => true, else => false };  // OK
return self == .nil;                                    // unreliable
```

Initialise with type annotation: `const nil: Value = .nil;`
(not `Value.nil`).

## ArrayList / HashMap: `.empty` + per-call allocator

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
const v = list.pop();   // returns ?T, not T
```

Same pattern for `HashMap`: `.empty`, `put(alloc, k, v)`, `deinit(alloc)`.

## stdout via `std.Io.File`

```zig
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
const stdout = &stdout_writer.interface;
try stdout.print("hello {s}\n", .{"world"});
try stdout.flush();    // do not forget
```

`writer(io, buf)` requires `io` (a `std.Io` value) — get it from
`std.process.Init` (Juicy Main) or from `Runtime.io`.

## `*std.Io.Writer` for writer params

Type-erased writer; replaces `anytype` for writer parameters and avoids
"unable to resolve inferred error set" with recursion. For tests use
`var w: std.Io.Writer = .fixed(&buf);` then `w.buffered()`.

Allocating writer (replaces `ArrayList(u8).writer().any()`):

```zig
var aw: std.Io.Writer.Allocating = .init(allocator);
errdefer aw.deinit();
try form.format(&aw.writer);
return aw.toOwnedSlice();
```

## `@branchHint` (not `@branch`)

The hint goes inside the branch body:

```zig
if (cond) {
    @branchHint(.likely);
} else {
    @branchHint(.unlikely);
    return error.Fail;
}
```

## Variable shadowing

Zig disallows locals that shadow struct method names. Rename the local.

```zig
pub fn next(self: *Tokenizer) Token {
    const next_char = self.peek();   // not `next`
}
```

## `comptime StaticStringMap`

Zero-cost lookup at compile time. Use for keyword / opcode tables.

```zig
const keywords = std.StaticStringMap(Keyword).initComptime(.{
    .{ "if",  .if_kw  },
    .{ "def", .def_kw },
});
```

## `ArenaAllocator` for phase-based memory

Bulk-free at phase boundaries. No individual `free` calls.

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const alloc = arena.allocator();
```

## Doc comments

- `//!` — module-level (top of file, before imports). ZLS hover on module.
- `///` — declaration-level (on `pub` types/fns/fields).
- `//`  — inline notes (inside bodies only).

Every file gets `//!`. Every `pub` gets `///` unless the name is
self-evident. No decorative banners (`// ---`).

## `packed struct(<width>)`

Bit-level layout, e.g. `HeapHeader.flags`:

```zig
flags: packed struct(u8) {
    marked: bool,
    frozen: bool,
    _pad: u6,
};
```

## `extern struct` for ABI

When laying out structures that cross language / Wasm boundaries, prefer
`extern struct` (C ABI) for top-level layout and `packed struct(<width>)`
for bit-precise sub-fields.
