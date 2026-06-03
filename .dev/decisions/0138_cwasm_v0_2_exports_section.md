# 0138 — `.cwasm` v0.2 adds an exports section so `zwasm run *.cwasm` resolves entry points self-containedly

- **Status**: Accepted (2026-06-03; autonomous per ADR-0132 — Phase-12 format finalisation, within §12 scope)
- **Date**: 2026-06-03
- **Author**: claude (autonomous Phase-12 design decision)
- **Tags**: Phase 12, §12.1, AOT, `.cwasm`, format, exports, entry-point, v0.2, ADR-0039
- **Amends**: ADR-0039 (`.cwasm` skeleton — adds the v0.2 exports section + grows the header 60→68 bytes)

## Context

§12.1's exit criterion is `zwasm run *.cwasm` running a real artefact end-to-end. The CLI run path
(`src/cli/run.zig`) resolves which function to invoke by name: `--invoke <name>` override → `_start`
→ `main` → first func-export → error `NoFuncExport`, mapping a name to a wasm func index via the
**export table** (`runner.findExportFunc`, which re-parses the `.wasm` export section).

A `.cwasm` artefact has no `.wasm` bytes to re-parse — that is the entire point of AOT (skip
parse + compile). The v0.1 format (ADR-0039) serialises header + per-func metadata + types + relocs +
code, but **no export/name information**: `serialise.Input` has no export field and
`produce.produceFromCompiledWasm` has nothing to forward (`runner.CompiledWasm` drops the export
table after `compileWasm`). So a loaded `.cwasm` cannot today answer "which func is `_start`?".

The v0.1 header is exactly 60 bytes with **no spare room** (the `flags` u32 at offset 12 is the only
reserved field, too small for a section offset+size pair). v0.1 is **unreleased** (pre-v0.1.0), so
there is no committed/shipped v0.1 artefact a loader must remain compatible with.

## Decision

Add an **exports section** to the `.cwasm` format and bump the version to **v0.2**
(`0x0002_0000`). This makes the artefact self-describing for entry resolution, preserving full parity
with the `.wasm` run path (`--invoke <name>` / `_start` / `main` / first-export).

**Header grows 60 → 68 bytes**: append `exports_offset` (u32 @ 60) + `exports_size` (u32 @ 64) after
the relocs fields. `header_size` = 68; `version_v0_2` is the current version.

**Exports section layout** (little-endian, func-kind exports only — `zwasm run` invokes functions):

```
[0..4)   n_exports : u32
then n_exports entries, each:
  [0..4)        name_len  : u32
  [4..4+L)      name      : name_len bytes (UTF-8, not NUL-terminated)
  [4+L..8+L)    func_idx  : u32   (wasm-space function index)
```

Section order becomes: `header → metadata → types → relocs → exports → code`. The exports section
is empty (`n_exports = 0`) for modules with no func exports — zero overhead beyond the 4-byte count.

`load.LoadedModule` gains a parsed export map + `resolveEntry(invoke_name: ?[]const u8) → ?usize`
mirroring `run.zig`'s precedence, so the CLI picks the defined-func index without re-parsing wasm.

### Rejected alternatives

- **`func[0]` convention** — invoke the first defined function. Brittle (breaks the moment a module's
  first func is not the entry), loses `--invoke <name>` and `_start`/`main` semantics; a workaround,
  not a design (violates the no-workaround rule for a shippable artefact format).
- **Header `entry_idx` only** — a single u32 entry index in the header (repurposing `flags`). Covers
  the single-`_start` case but discards every other export, so `zwasm run --invoke <name>` against a
  `.cwasm` would be a feature regression vs the same command on `.wasm`. Half-measure.
- **Re-parse the original `.wasm` at run time** — defeats AOT (the artefact would need its source
  alongside) and contradicts ADR-0039's "inline-bytes self-contained container" intent.

## Consequences

- `format.zig`: `version_v0_2`, `header_size` 68, two new header fields + write/parse, exports-entry
  write/parse helpers. Existing v0.1-pinned tests update to v0.2 (unreleased format, no compat debt).
- `serialise.zig`: `Input` gains an exports list; `produceCwasm` writes the section + header offsets.
- `load.zig`: parse the exports section into `LoadedModule`; add `resolveEntry`.
- `produce.zig` + `runner.CompiledWasm` + `cli/compile.zig`: carry exports from compile through to the
  producer (the wasm export table is available at `compileWasm` and the CLI compile entry). Wired in a
  follow-on cycle of the `12.1-aot-cwasm-loader` bundle.
- `cli/run.zig`: a `.cwasm` branch that loads + `resolveEntry` + invokes, closing §12.1 end-to-end.
- 3-host: format is arch-blind; exec on Mac + ubuntu, windowsmini at phase boundary (mirrors the
  loader's `skip.phaseEnd(.win64)`).

> **Doc-state**: ACTIVE
