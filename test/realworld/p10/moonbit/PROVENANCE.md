# MoonBit `--target wasm-gc` fixture (Phase 10 / GC)

**Toolchain**: `moon 0.1.20260819 (fc2a4ee 2026-08-19)`,
`moonc v0.10.9+6e6c44045 (2026-08-19)`, installed via the official MoonBit
installer (`~/.moon/bin`). **Not** in `devShells.gen` — nixpkgs availability
was not verified, so this follows the hand-generated realworld pattern: the
`.wasm` is committed and runs on every host through the edge-runner.

- `gc_shapes.{mbt,wasm,expect}` — the corpus's first fixture emitted by a
  toolchain whose native backend is wasm-gc. `test()->i32` = 658.
  moonc scalar-replaces structs that stay local, so the guest deliberately
  routes every allocation through a function boundary or a recursive call
  to keep the GC instructions in the emitted code.

**Emitted GC surface** (`wasm-tools print`, custom sections excluded):
8 GC typedefs in a `(sub …)` / `(sub final …)` hierarchy, 48 GC instructions
— `struct.new` ×8, `struct.get` ×25, `ref.cast` ×3, and non-nullable
`(ref $t)` in function params, results, and struct fields.

**Build**:

```sh
moon new gc_shapes    # then replace the three files below
moon build --target wasm-gc --release
cp _build/wasm-gc/release/build/cmd/main/main.wasm gc_shapes.wasm
```

`moon.mod`:

```
name = "zwasm/gc_shapes"

version = "0.1.0"
```

`cmd/main/moon.pkg.json` — `test` is a MoonBit keyword, so the export is
renamed at link time to the name the edge-runner invokes:

```json
{
  "is-main": true,
  "link": { "wasm-gc": { "exports": ["compute:test"] } }
}
```

`cmd/main/main.mbt` = `gc_shapes.mbt`.

**Determinism**: no imports, no `memory.grow`, no float, no time or
randomness source (`wasm-tools print` count = 0 for all of those). Three
wasmtime runs byte-identical; two clean rebuilds byte-identical by sha256.

**Result-check**: `zig build test-edge-cases` → `run_edge_realworld_p10` →
`runI32Export` `test` → `.expect` = `i32: 658`. That lane is JIT-only; the
interpreter was verified by hand (`zwasm run --engine interp --invoke test`
= 658, matching wasmtime 47.0.3). **Status**: ACTIVE.

## Scope: what this fixture does NOT cover

Measured 2026-08-22 at `5328f7005`, x86_64-linux, Debug. Three engine defects
bound the guest; each is a `src/` product defect, filed separately, not worked
around here:

- **No loops.** A `loop` whose block type takes a parameter traps
  `unreachable` in the interpreter (wasmtime and the JIT both compute it).
  moonc emits that shape for every `for`, so any looping guest is
  interp-red. GC is not involved — it reproduces in plain wat.
- **No arrays.** `array.get` on an array with a *reference* element type
  returns wrong values under the JIT, silently, with no trap.
- **No `ref.null none` reaching a concrete ref slot** — the bottom edge that
  #224 reported and #231 fixed. A guest carrying it (a `Node?` linked list)
  now validates where it previously did not, but the JIT then computes 0
  against wasmtime's and the interpreter's 140. So this fixture **does not
  guard the #231 regression**: it is verified to pass both pre-#231
  (`28964b42a`) and post-#231, because the shapes that separate them are the
  shapes the JIT gets wrong.

What it does do is put a real wasm-gc-emitting toolchain into a lane that
walks it and checks a value — the gap #226 records for the GC leg.
