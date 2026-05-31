# Zig 0.16.0 idioms (project rules) — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/zig_tips.md`](../rules/zig_tips.md).

Cross-links (already-detailed, do not duplicate): full rename/removal
table → [`zig_0_16_complete_api.md`](zig_0_16_complete_api.md);
extended idioms → [`zig_idioms_quick_ref.md`](zig_idioms_quick_ref.md).

Auto-loaded when editing Zig source. **AI assistants tend to revert to
pre-0.16 (often pre-0.14) APIs by default — consult this list before
typing any stdlib reference.** When in doubt, grep
`/nix/store/*-zig-0.16.0/lib/std/` for the canonical surface.

## Most-used 0.16 surface (gate)

The forms below are the ones that bite hardest in practice; the full
rename / removal table lives in
[`references/zig_0_16_complete_api.md`](../references/zig_0_16_complete_api.md).

- `std.io` → **`std.Io`** (capital I). `AnyWriter`/`AnyReader` →
  `*std.Io.Writer` / `*std.Io.Reader`.
- `std.fs.*` → **`std.Io.File`** / **`std.Io.Dir`** (all ops take
  `io: std.Io`).
- `std.Thread.Mutex` / `RwLock` / `Condition` / `Semaphore` /
  `WaitGroup` → **gone**. Use `std.Io.Mutex` etc. (`io: Io` arg) or
  `std.atomic.Mutex` (lock-free).
- `std.heap.GeneralPurposeAllocator(.{})` → **`std.heap.DebugAllocator(.{})`**.
- `std.mem.copy(T, dst, src)` → **`@memcpy(dst, src)`** (or
  `@memmove` if overlapping).
- `std.mem.indexOf*` family → **`std.mem.find*`** (`indexOf` →
  `find`, `indexOfScalar` → `findScalar`, `lastIndexOf` →
  `findLastLinear`, `indexOfPos` → `findPos`, etc.).
- `std.meta.Int(.signed, n)` → **`@Int(.signed, n)`** (now a
  builtin).
- `usingnamespace` → **removed** (no replacement; explicit re-exports).
- `c_void` → **`anyopaque`**.
- `@intToFloat`/`@floatToInt`/`@boolToInt`/`@enumToInt`/`@intToEnum`/
  `@errToInt`/`@intToErr`/`@ptrToInt`/`@intToPtr` → **`@floatFromInt`/
  `@intFromFloat`/`@intFromBool`/`@intFromEnum`/`@enumFromInt`/
  `@intFromError`/`@errorFromInt`/`@intFromPtr`/`@ptrFromInt`**.
- `@branch` → **`@branchHint(.likely | .unlikely | .cold)`** placed
  **inside** the branch body.
- Old `format(self, comptime fmt, opts, writer: anytype)` →
  **`pub fn format(self: @This(), w: *std.Io.Writer)
  std.Io.Writer.Error!void`**; call sites: `{}` → `{f}`.
- "Juicy Main": `pub fn main(init: std.process.Init)` then
  `init.minimal.args.iterateAllocator(gpa)`.

`std.mem.eql` / `startsWith` / `endsWith` / `splitScalar` /
`tokenizeScalar` / `readInt` / `writeInt` are **NOT renamed** —
don't migrate them.

## Lint-gate idioms (ADR-0009 enforced)

These gates run via `zig build lint -- --max-warnings 0` (Mac-host).
Five rules: `no_deprecated`, `no_orelse_unreachable`,
`no_empty_block`, `require_exhaustive_enum_switch`, `no_unused`.

- **Empty `catch`**: only `catch {}` compiles. `catch |_| {}` and
  `catch |err| { _ = err; }` are rejected by the compiler itself.
- **Optionals**: `x.?` (canonical), not `x orelse unreachable`.
- **Exhaustive enum switch**: list every tag, no `else =>`. Use
  `else =>` only on non-exhaustive enums (`enum(T) { ..., _ }`) or
  external enums.
- **Empty body**: a `{}` body is gate-rejected unless it carries a
  comment explaining intent.

## Project-canonical surface (load-bearing)

- **Tagged union**: `switch (self) { .nil => ..., else => ... }`
  (not `self == .nil`). Init: `const nil: Value = .nil;`.
- **ArrayList / HashMap**: `.empty` + per-call allocator.
  `try list.append(allocator, x)`, `list.deinit(allocator)`.
- **`*std.Io.Writer`** for writer params (replaces `anytype`); avoids
  inferred-error-set issues with recursion.
- **`std.Io.File.stdout()`**: requires `io` from `std.process.Init`
  (Juicy Main) or `Runtime.io`; remember `try stdout.flush()`.
- **`undefined`** is canonical for fixed-size stack buffers
  (the caller writes before reading).
- **`undefined` in extern struct fields shared across an ABI
  boundary is a time bomb** (D-142, 2026-05-17). Zig fills
  `undefined` with `0xAA` poison bytes in Debug. If the struct
  is read by JIT-emitted code or a signal handler, the
  poisoned field is dereferenced FAR from the construction
  site; the fault address `0xAA...AA + offset` reveals it but
  the call stack doesn't point at the originating struct init.
  **For pointer / slice fields in `extern struct`s that will be
  read by JIT-emitted code, signal handlers, or any code you
  did not write yourself**, use safe sentinels:
  `[*]const T = @ptrFromInt(0x1000)` (a stub address) or an
  empty static array's `.ptr` (always non-null, dereferences
  cleanly to zero if accidentally read), NOT `undefined`. See
  `RegisteredExporter.ensureCompiledAndRt` in
  `test/spec/spec_assert_runner_base.zig` for the v2-side
  pattern this rule was extracted from.
- **Short identifiers** (`i`, `n`, `rt`, `ea`) are fine — math
  conventions in WebAssembly / IR / regalloc code.
- **Inferred error sets** at the implementation layer (`anyerror!T`)
  are intentional — wide explicit error sets re-introduce the
  W54-class Implicit Contract Sprawl.
- **`extern struct`** for ABI-crossing layouts; **`packed struct(<width>)`**
  for bit-precise sub-fields.
- **Cross-platform footgun**: `std.posix.STDIN_FILENO` is
  `comptime_int` on non-Linux. For placeholder fds in tests use
  `const fd: std.posix.fd_t = undefined;`.

詳細・例・追加 idiom (StaticStringMap, ArenaAllocator, doc comments,
shadowing, full lint rationale) は
[`references/zig_idioms_quick_ref.md`](../references/zig_idioms_quick_ref.md)
を参照。
