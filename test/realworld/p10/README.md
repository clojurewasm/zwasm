# `test/realworld/p10/` — Wasm 3.0 realworld fixtures

Per Phase 10 design plan §4.3. 6 toolchains × planned-fixture
count covers the 4 proposal axes:

| Toolchain | Sub | Planned fixtures |
|---|---|---|
| `dart/` | GC + EH | HelloWorld / collection ops / async error |
| `wasm_of_ocaml/` | GC + EH + TC | List.fold (TC) / exception raise / record alloc |
| `hoot/` | GC + TC | Scheme tail-call factorial / list manipulation |
| `emscripten_eh/` | EH | C++ exception throw / catch (`try_table` output) |
| `clang_musttail/` | TC | C continuation-passing style (musttail attribute) |
| `clang_wasm64/` | memory64 | > 4 GiB allocate + memcpy (host 64-bit only) |

Per-fixture skip-list managed via per-file header (wasmtime
shape adopted per §4.4). `.wasm` artifacts land cycle-by-cycle as
the corresponding impl rows (10.M / 10.TC / 10.E / 10.G) exercise
each toolchain.

10.T-5 deliverable: directory skeleton + per-toolchain PROVENANCE
stubs. Artifact landing happens later (post-Accept of the 7 ADRs
in 10.D).

`moonbit/` is **not** one of those six and claims none of their exit
criteria. It is a MoonBit `--target wasm-gc` fixture added because the GC
row above is still unfilled and the lane had no wasm-gc-emitting toolchain
walking it at all (#226). The four empty exit-criteria directories stay
empty and stay #226's to account for. `moonbit/PROVENANCE.md` records what
the fixture covers and the three engine defects that bound it.

## Skip-list

Per-file header convention (wasmtime model, adopted per §4.4):

```wat
;; ZWASM-SKIP: SKIP-P10-GC-GAP (10.G impl pending)
(module
  ...)
```

The runner reads the first 10 lines of each fixture's `.wat`
source (when bundled) or a sidecar `.skip` file (for `.wasm`-only
fixtures). Reasons:

- `SKIP-P10-PARSER-GAP` — parser doesn't yet handle the Wasm 3.0
  feature in question
- `SKIP-P10-GC-GAP` — needs `feature/gc/` (10.G impl row)
- `SKIP-P10-EH-GAP` — needs `feature/exception_handling/` (10.E)
- `SKIP-P10-TC-GAP` — needs tail-call codegen (10.TC)
- `SKIP-P10-MEM64-GAP` — needs memory64 codegen (10.M)
- `SKIP-P10-CROSS-GAP` — needs cross-subsystem invariants (10.E + 10.G + 10.TC)

Per ADR-0078 SKIP-* taxonomy + ADR-0050 D-5 ratchet — new
SKIP-P10-* tokens get added to ADR-0078 when first emitted.
