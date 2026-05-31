---
paths:
  - "src/**/*.zig"
  - "build.zig"
---

# Zig 0.16.0 idioms (project rules)

> Lean stub (ADR-0118 D2). Full detail: [`../references/zig_tips.md`](../references/zig_tips.md) (which cross-links the full [`zig_0_16_complete_api.md`](../references/zig_0_16_complete_api.md) + [`zig_idioms_quick_ref.md`](../references/zig_idioms_quick_ref.md)).

## Invariant

Use the **Zig 0.16 API surface** — AI reverts to pre-0.14 APIs by
default; consult before typing any stdlib reference.

## Enforcement

`zig build lint -- --max-warnings 0` (Mac-host, ADR-0009). Five rules:
no empty `catch {}`-only-form, `x.?` not `orelse unreachable`,
exhaustive enum switch (no `else` on exhaustive), no unused, no deprecated.

## Key cases (most bite-prone 0.16 renames)

- `std.io` → **`std.Io`**; `std.fs.*` → **`std.Io.File`/`std.Io.Dir`** (take `io`).
- `std.Thread.Mutex/RwLock/...` → **gone** (`std.Io.Mutex` / `std.atomic`).
- `GeneralPurposeAllocator` → **`DebugAllocator`**.
- `std.mem.copy` → **`@memcpy`**; `std.mem.indexOf*` → **`std.mem.find*`**.
- `@intToFloat`/`@floatToInt`/`@enumToInt`/`@ptrToInt` etc → **From-form**
  (`@floatFromInt`/`@intFromFloat`/`@intFromEnum`/`@intFromPtr`).
- `usingnamespace` **removed**; ArrayList/HashMap = **`.empty` + per-call allocator**.
- **NOT renamed** (don't migrate): `std.mem.eql`/`startsWith`/`splitScalar`/`readInt`/`writeInt`.

Full rename/removal table + extended idioms:
[`../references/zig_tips.md`](../references/zig_tips.md).
