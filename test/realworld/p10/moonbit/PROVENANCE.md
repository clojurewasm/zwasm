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

Measured 2026-08-22, x86_64-linux, Debug. Two engine defects bound the guest;
both are `src/` product defects, filed separately, not worked around here.

The guest is written to steer around them, but what matters is the **emitted**
module, not the source — moonc is free to introduce either shape on its own.
Audit the committed bytes:

```sh
wasm-tools print gc_shapes.wasm | grep -cE 'ref\.as_non_null|\bloop\b'   # must be 0
```

Measured 0. The same command returns 1 on a guest that carries the bottom
edge and 1 on the #244 repro, so it fires rather than being vacuous. The
widest functype in the module has 1 result, well under #246's cap of 16.
**Re-run this after any regeneration.**

The audit is a diagnostic, not the safety net — the static `.expect` is.
Measured by simulation: dropping a module that *does* emit `ref.as_non_null`
into this lane with its wasmtime-correct expectation fails it
(`expected i32:140, got i32:0`, lane exit 1). A regeneration that introduces
a miscompiled shape therefore cannot pass quietly; it turns the lane red and
the audit says why.

- **No loops** (#244, with #246 behind how it surfaces). A `loop` whose block
  type takes a parameter traps `unreachable` in the interpreter, where
  wasmtime and the JIT both compute it; `block (param …)` is fine. moonc
  emits that shape for every `for`, so any looping guest is interp-red. GC is
  not involved — it reproduces in plain wat.
- **No `ref.as_non_null` whose result outlives one more allocation** (#245).
  Liveness models the op `1 → 1` while both emitters implement it as an
  identity passthrough, so the allocator reuses the operand's register while
  it is still live and the JIT returns wrong values silently. That single
  root cause covers reference-element `array.get`, structs held in ref-typed
  globals, and the bottom edge below. Substituting `ref.cast` — modelled
  consistently — makes the same shapes correct, which is how the op was
  isolated.

**This fixture does not guard the #231 regression**, which was the original
intent. The bottom edge #224 reported and #231 fixed (`ref.null none` into a
concrete ref slot) needs a guest like a `Node?` linked list; that guest now
validates where it previously did not, and the JIT then answers 0 against
wasmtime's and the interpreter's 140 — #245 again. So the fixture is verified
to pass identically at `28964b42a` (pre-#231) and after, because every shape
separating the two is a shape #245 breaks.

**Upgrade path**: #245 alone unblocks it. With that issue's candidate
one-line liveness change applied to `19df5e6e2` in a throwaway worktree, the
bottom-edge guest returns 140 on both engines and this fixture still returns
658. The linked-list shape uses recursion, not loops, so #244 does not also
have to land first. When #245 ships, extend `gc_shapes.mbt` with the
nullable-reference walk and this fixture starts guarding #231.

What it does today is put a real wasm-gc-emitting toolchain into a lane that
walks it and checks a value — the gap #226 records for the GC leg.
