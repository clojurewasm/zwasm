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

| Removed / renamed (0.14 / 0.15)                                         | Use in 0.16.0                                                                                                                  | Notes                                                                      |
|-------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------|
| `std.io` (lowercase namespace)                                          | `std.Io` (capital I)                                                                                                           | `std.io` namespace effectively gone; `std.Io` is the only canonical module |
| `std.io.AnyWriter` / `AnyReader`                                        | `*std.Io.Writer` / `*std.Io.Reader`                                                                                            | Type-erased pointer to concrete vtable type                                |
| `std.io.fixedBufferStream(&buf)`                                        | `var w: std.Io.Writer = .fixed(&buf);`                                                                                         | Reader: `var r: std.Io.Reader = .fixed(&buf);`                             |
| `std.io.getStdOut/Err/In`                                               | `std.Io.File.stdout/stderr/stdin()`                                                                                            | Returns `File`, then `.writer(io, &buf).interface`                         |
| `std.io.bufferedWriter` / `BufferedWriter`                              | `file.writer(io, &buf)`                                                                                                        | Buffer is the user-supplied byte slice                                     |
| `std.io.tty.*`                                                          | `std.Io.Terminal`                                                                                                              | TTY detection / colour                                                     |
| `list.writer().any()` (allocating)                                      | `var aw: std.Io.Writer.Allocating = .init(alloc);` then `&aw.writer`                                                           | `aw.toOwnedSlice()` extracts                                               |
| `std.fs.File` (and `.OpenError` / `.Writer` / etc.)                     | `std.Io.File`                                                                                                                  | All file ops now take `io: std.Io`                                         |
| `std.fs.cwd()`                                                          | `std.Io.Dir.cwd()`                                                                                                             | —                                                                         |
| `std.fs.openFileAbsolute(path, ...)`                                    | `std.Io.Dir.cwd().openFile(io, path, ...)`                                                                                     | `io` arg now mandatory                                                     |
| `std.fs.Dir`                                                            | `std.Io.Dir`                                                                                                                   | All dir ops take `io: std.Io`                                              |
| `std.fs.path.*`                                                         | `std.Io.Dir.path.*`                                                                                                            | `std.fs.path` left as deprecated re-export                                 |
| `std.fs.max_path_bytes` / `max_name_bytes`                              | `std.Io.Dir.max_path_bytes` / `.max_name_bytes`                                                                                | —                                                                         |
| `std.Thread.Mutex` / `RwLock` / `Condition` / `Semaphore` / `WaitGroup` | `std.Io.Mutex` / `Io.RwLock` / `Io.Semaphore` (with `io: Io` arg), or `std.atomic.Mutex` (lock-free `tryLock` / `unlock` only) | **All `std.Thread.*` sync primitives are gone**                            |
| `std.heap.GeneralPurposeAllocator(.{})`                                 | `std.heap.DebugAllocator(.{})`                                                                                                 | Same config struct, renamed                                                |
| `std.mem.copy(T, dest, src)`                                            | `@memcpy(dest, src)` (or `@memmove` if overlapping; or `std.mem.copyForwards` / `copyBackwards` for explicit direction)        | `mem.copy` removed                                                         |
| `std.mem.indexOf`                                                       | `std.mem.find`                                                                                                                 | —                                                                         |
| `std.mem.lastIndexOf`                                                   | `std.mem.findLastLinear`                                                                                                       | —                                                                         |
| `std.mem.indexOfScalar`                                                 | `std.mem.findScalar`                                                                                                           | —                                                                         |
| `std.mem.lastIndexOfScalar`                                             | `std.mem.findScalarLast`                                                                                                       | —                                                                         |
| `std.mem.indexOfScalarPos`                                              | `std.mem.findScalarPos`                                                                                                        | —                                                                         |
| `std.mem.indexOfAny` / `lastIndexOfAny` / `indexOfAnyPos`               | `findAny` / `findLastAny` / `findAnyPos`                                                                                       | —                                                                         |
| `std.mem.indexOfNone` / `lastIndexOfNone`                               | `findNone` / `findLastNone`                                                                                                    | —                                                                         |
| `std.mem.indexOfDiff`                                                   | `std.mem.findDiff`                                                                                                             | —                                                                         |
| `std.mem.indexOfSentinel`                                               | `std.mem.findSentinel`                                                                                                         | —                                                                         |
| `std.mem.indexOfPos`                                                    | `std.mem.findPos`                                                                                                              | —                                                                         |
| `std.mem.containsAtLeastScalar(...)`                                    | `std.mem.containsAtLeastScalar2(...)`                                                                                          | Signature changed                                                          |
| `std.mem.readPackedIntNative` / `*Foreign` (read+write)                 | `readPackedInt(T, bytes, bit_offset, .native)` (or `.foreign`)                                                                 | Unified API                                                                |
| `std.mem.Alignment` as `u29` int                                        | `enum (Alignment)` — use `.fromByteUnits(n)` / `@enumFromInt`                                                                 | No more `@as(u29, ...)` for alignment                                      |
| `c_void`                                                                | `anyopaque`                                                                                                                    | C ABI                                                                      |
| `usingnamespace`                                                        | (removed — no replacement; redesign with explicit re-exports)                                                                 | Compile error in 0.16                                                      |
| `@intToFloat(T, x)` / `@floatToInt(T, x)`                               | `@floatFromInt(x)` / `@intFromFloat(x)`                                                                                        | Result-location inferred                                                   |
| `@boolToInt(x)`                                                         | `@intFromBool(x)`                                                                                                              | —                                                                         |
| `@enumToInt(x)` / `@intToEnum(T, x)`                                    | `@intFromEnum(x)` / `@enumFromInt(x)`                                                                                          | —                                                                         |
| `@errToInt` / `@intToErr`                                               | `@intFromError` / `@errorFromInt`                                                                                              | —                                                                         |
| `@ptrToInt` / `@intToPtr`                                               | `@intFromPtr` / `@ptrFromInt`                                                                                                  | —                                                                         |
| `@branch`                                                               | `@branchHint(.likely)` (or `.unlikely` / `.cold`); placed **inside** the branch body                                           | —                                                                         |
| Old `format(self, comptime fmt, options, writer: anytype)`              | `pub fn format(self: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void`                                                     | `{}` → `{f}` at call sites                                                |
| `std.process.argsAlloc(alloc)` (manual main)                            | `pub fn main(init: std.process.Init)` then `init.minimal.args.iterateAllocator(gpa)`                                           | "Juicy Main"                                                               |
| `Args.Iterator.initAllocator(args, gpa)` (long form)                    | `args.iterateAllocator(gpa)`                                                                                                   | Both compile; the short form is the 0.16 idiom                             |

**Rule of thumb**: any time you reach for `std.io`, `std.fs`,
`std.Thread.Mutex`, `GeneralPurposeAllocator`, `mem.indexOf*`, `mem.copy`,
an `@intToFloat`-shaped builtin, a 4-arg `format` method, or
`usingnamespace` — STOP and consult the table above.

## std.mem aliases that still work (informational)

These remain canonical in 0.16, **don't migrate them**:

- `std.mem.eql` / `startsWith` / `endsWith` / `trim` / `trimStart` / `trimEnd`
- `std.mem.splitScalar` / `splitAny` / `splitSequence` (NOT renamed)
- `std.mem.tokenizeScalar` / `tokenizeAny` / `tokenizeSequence` (NOT renamed)
- `std.mem.readInt(T, bytes, .little)` (or `.big`) / `writeInt`
- `@memcpy` / `@memset` / `@memmove` (builtins; replace `mem.copy`)

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
"unable to resolve inferred error set" with recursion.

```zig
const Writer = std.Io.Writer;

pub fn format(self: Form, w: *Writer) Writer.Error!void { ... }

// Tests (replaces std.io.fixedBufferStream)
var buf: [256]u8 = undefined;
var w: Writer = .fixed(&buf);
try form.format(&w);
try std.testing.expectEqualStrings("expected", w.buffered());
```

For an allocating writer (replaces `ArrayList(u8).writer().any()`):

```zig
var aw: std.Io.Writer.Allocating = .init(allocator);
errdefer aw.deinit();
try form.format(&aw.writer);
return aw.toOwnedSlice();
```

## Mutex: `std.Thread.Mutex` is gone

Replacements:

- `std.Io.Mutex` — full blocking mutex; `lock`/`unlock` take an `io: Io`
  argument, so the call site must already be threading `Io` through.
- `std.atomic.Mutex` — lock-free `tryLock` / `unlock` only (no blocking
  `lock`).

Phase 1–10 is single-threaded; prefer no mutex over a half-wired one. Wire
through `Runtime.io` when concurrency actually arrives (Phase 11+ multi-store; the threads proposal is post-v0.1.0).

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

## Custom format: `{f}`, not `{}`

Types with a `format` method: `{}` raises "ambiguous format string".

```zig
try w.print("{f}", .{my_value});
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

## Juicy Main

`pub fn main(init: std.process.Init)` receives `init.io` (`std.Io`),
`init.arena` (process-lifetime arena), `init.gpa` (thread-safe GPA),
`init.minimal.args`, `init.environ_map`, `init.preopens` in one bundle.
Use this signature; do not roll your own arg parsing for stdlib paths.

## `extern struct` for ABI

When laying out structures that cross language / Wasm boundaries, prefer
`extern struct` (C ABI) for top-level layout and `packed struct(<width>)`
for bit-precise sub-fields.
