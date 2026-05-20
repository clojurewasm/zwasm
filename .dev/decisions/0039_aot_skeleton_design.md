# 0039 — AOT skeleton: inline-bytes .cwasm format + JIT-pipeline reuse

- **Status**: Accepted
- **Date**: 2026-05-09
- **Author**: Phase 8 / §9.8b / 8b.3-b autonomous /continue cycle
- **Tags**: roadmap, phase8, jit, aot, format, cold-start

## Context

§9.8b / 8b.3 delivers the AOT (ahead-of-time) **generator
pipeline**: `zwasm compile foo.wasm -o foo.cwasm` produces a
loadable artifact. Phase 12 finalises the consumer side
(loader + execution). The slot `engine/codegen/aot/` is
already reserved per ADR-0023.

Step 0 survey at `private/notes/p8-8b3-aot-survey.md` (423
lines, gitignored) covered five reference codebases
(wasmer / WasmEdge / wasmtime+cranelift / WAMR / v1 zwasm).
Headline findings:

- **Format space splits into two camps**: (a) inline-bytes-
  and-metadata in a single container (cranelift `.cwasm`,
  WAMR `.aot`); (b) standalone executable objects (wasmer
  `engine-dylib`, WasmEdge LLVM-emitted `.so`). For P3 cold-
  start (load + first-call < N ms) the inline-bytes camp is
  superior — 2-5 ms parse vs 20+ ms for ELF/Mach-O loader
  invocation, no OS-coupling, simpler relocation handling.
- **Pipeline reuse opportunity**: zwasm v2's JIT pipeline
  (`compile.zig`: lower → loop_info → hoist → liveness →
  regalloc → coalesce → emit) ends with `emit.compile()`
  returning bytes for in-memory execution. AOT can reuse
  the entire pipeline; only the output sink changes (disk
  vs JIT memory). Net new code: thin serialiser (~300 LOC).
- **Bench-delta defers to Phase 12**: the loader doesn't
  exist yet. 8b.3-c's deliverable is generator-pipeline
  correctness validated against a synthetic load simulator;
  cold-start vs JIT first-invocation lands in Phase 12.

## Decision

**Adopt inline-bytes `.cwasm` format with magic-bytes
container + JIT-pipeline reuse for the 8b.3-c MVP.** The
generator wraps `compile.zig`'s existing output (machine
code bytes + relocation list + per-function metadata) in a
custom container; arch tag identifies the producer (Mac
aarch64 vs Linux x86_64 vs Windows x86_64); cross-arch
production deferred to Phase 12+.

### `.cwasm` v0.1 binary format

```
struct CwasmHeader {
    magic: [4]u8 = "CWAS",        // identifies the container
    version: u32 = 1,             // major.minor packed (0x00010000 = v0.1)
    arch: u32,                    // 1 = arm64, 2 = x86_64; LE encoding
    flags: u32 = 0,               // reserved for v0.2 (debug info, etc.)
    n_funcs: u32,                 // count of functions
    n_types: u32,                 // count of FuncType entries
    n_imports: u32,               // count of imported funcs
    code_offset: u32,             // byte offset of the code section
    code_size: u32,               // length of the code section
    metadata_offset: u32,         // byte offset of per-func metadata
    metadata_size: u32,           // length of metadata section
    types_offset: u32,            // byte offset of types section
    types_size: u32,              // length of types section
    relocs_offset: u32,           // byte offset of relocs section
    relocs_size: u32,             // length of relocs section
}
// All u32 fields little-endian. Total header size: 60 bytes
// (4 magic + 14 × u32; Revision 2 corrected the original
// "56 bytes" miscount).

// Per-func metadata (n_funcs entries):
struct CwasmFuncMeta {
    code_offset: u32,             // offset within code section
    code_size: u32,               // bytes of machine code
    n_slots: u16,                 // regalloc.Allocation.n_slots
    sig_idx: u16,                 // index into types section
}
// 12 bytes per func.

// Types section: a tightly-packed FuncType list
// (params_count: u8, results_count: u8, then ValType bytes).

// Relocs section: list of (code_offset: u32, target_func_idx: u32,
// reloc_kind: u8) triples. Phase 12's loader applies these.

// Code section: raw machine code bytes for all functions, padded
// to 4-byte alignment per func. Loader mmap()s this region with
// PROT_EXEC after applying relocs.
```

### Pipeline shape

```zig
// New: src/engine/codegen/aot/serialise.zig
pub fn produceCwasm(
    allocator: Allocator,
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
    func_sigs: []const FuncType,
    module_types: []const FuncType,
    num_imports: u32,
) Error![]u8 {
    // Reuse: arm64.emit.compile (or x86_64.emit.compile) is
    // arch-blind from the producer's perspective; only the
    // arch tag in the header changes. Existing emit returns
    // bytes + relocs; serialise wraps them in CwasmHeader +
    // sections and returns the full .cwasm payload.
}

// New: src/engine/codegen/aot/format.zig
pub const CwasmHeader = ...;
pub const CwasmFuncMeta = ...;
pub fn writeHeader(w: *std.Io.Writer, h: CwasmHeader) !void;
pub fn writeFuncMeta(w: *std.Io.Writer, m: CwasmFuncMeta) !void;
// Phase 12 reads via parseHeader / parseFuncMeta — symmetric.
```

The `aot/` module is **shared** (Zone 2 per ADR-0023; no
per-arch logic in shared code per A12). It composes
`engine/codegen/{arm64, x86_64}/emit` outputs without
importing them cross-arch — the producer pre-selects the
arch backend at `compile.zig` time, identical to JIT today.

### Concrete revised exit criterion (8b.3)

8b.3-c marks `[x]` when:

- `src/engine/codegen/aot/{format, serialise}.zig` exist.
- `produceCwasm` returns a valid `.cwasm` byte stream for
  a 3-fixture set (tinygo/fib + shootout/sieve + a
  hand-crafted single-function test).
- Round-trip parser test: write `.cwasm`, parse the header
  + per-func metadata, assert structural integrity (all
  offsets resolve in-bounds; magic/version match).
- Mac local + 3-host gate green.

8b.3-d adds `zwasm compile <input.wasm> -o <out.cwasm>` CLI
wiring; bench-delta capture is **deferred to Phase 12**
when the loader lands. The 8b.3-d commit body documents
this honestly per the ADR-0036 / ADR-0038 precedent
("0% per-row bench-delta; aggregate at risk; Phase 8b
target-revision via ADR-0040 to follow").

8b.3-e adds 3-host gate.

## Alternatives considered

### Alternative A — ELF / Mach-O native object format

Wasmer's `engine-dylib` produces `.dylib` / `.so` via system
linker; loader uses `dlopen`. Rejected: P3 cold-start budget
penalises OS dynamic-linker invocation (20+ ms vs 2-5 ms
parse for inline-bytes); cross-OS portability requires
per-host build infrastructure; A2 file-size cap pressure on
the format module (ELF spec is large).

### Alternative B — LLVM-based AOT (WasmEdge style)

WasmEdge emits LLVM IR → `.so`. Rejected: introduces LLVM
dependency contradicting ADR-0001's minimum-external-
dependencies stance; defeats P6's single-pass compile budget
(LLVM's optimisation passes are multi-pass by design).

### Alternative C — Defer the entire AOT row to Phase 12

Mark 8b.3 as "consumer-side only; generator deferred". Rejected:
Phase 12 is a year-out concern; landing the generator
pipeline now lets v0.1.0 shipping include `zwasm compile`
even if `zwasm run-cwasm` waits. The slot reservation in
ADR-0023 commits to landing **something** for `aot/` in
Phase 8.

### Alternative D — Cross-arch production from day 1

Producer on Mac aarch64 emits Linux x86_64 `.cwasm`.
Rejected: requires cross-compilation infrastructure (per-
arch emit code already separated by zone, but the host's
ABI knowledge is inherent in the running binary). Cross-
arch is a Phase 12+ concern; v0.1.0 ships producer-on-
matching-arch.

## Consequences

### Positive

- **Pipeline reuse minimises new code**: ~300 LOC for the
  serialiser + format types vs ~1000+ for a parallel
  pipeline. Most of 8b.3 is mechanical.
- **`.cwasm` v0.1 is forward-compatible**: the `flags` and
  `version` fields support v0.2 (debug info, signing, cross-
  arch tags) without breaking the v0.1 loader.
- **Phase 12 loader contract is precise**: this ADR's
  format spec is the contract; Phase 12 implementer reads
  it, no design ambiguity.
- **Cold-start measurement infrastructure prepared**: 8b.3-d
  (deferred bench-delta) becomes a single test case in
  Phase 12; the format's parse cost is the dominant factor
  and is bounded by header size (56 bytes) + metadata
  (12 bytes × N).

### Negative

- **8b.3's per-row bench-delta = 0%** (same as 8b.1, 8b.2):
  the third Phase 8b row producing scaffolding/format-
  specification work without runtime measurement. **8b.4's
  ≥10% aggregate is now structurally unattainable** with
  the current row plan. Resolution path: **ADR-0040** to
  revise §9.8b's exit criterion (file after 8b.3-c lands;
  options: lower the aggregate target, defer the
  measurement to Phase 12, or extend §9.8b with a
  measurement-focused row 8b.7).
- **`.cwasm` arch-tagging is producer-only**: cross-arch
  production (e.g. Mac developer producing Linux artifact)
  defers to Phase 12+. Acceptable for v0.1.0 but worth
  flagging in release notes.
- **No debug info / source maps in v0.1**: Phase 11's
  diagnostic story (per ADR-0028) doesn't extend to
  `.cwasm` until v0.2. Trapping a `.cwasm`-loaded function
  surfaces with no source location info in Phase 12.

### Neutral / follow-ups

- **ADR-0040 prerequisite**: file after 8b.3-c lands and
  before 8b.3-d's commit body needs the §9.8b exit
  criterion update.
- **Phase 12 loader contract reference**: this ADR is the
  authoritative spec for Phase 12's loader. Phase 12's
  ADR-NNNN cites this back.
- **Format versioning rule**: header `version` is
  `(major << 16) | minor`. Major bumps on format-breaking
  change; minor bumps on additive changes (new flags,
  new metadata fields appended at end). Phase 12 loader
  rejects `major != 1`.

## References

- ROADMAP §9.8b / 8b.3 (AOT skeleton row), §9.8b / 8b.4
  (≥10% aggregate exit; at risk per this ADR's
  acknowledgement), §18 (amendment policy), §P3 (cold-
  start), §P6 (single-pass JIT), §P7 (backend parity),
  §A2 (file-size cap), §A12 (no per-arch logic in shared)
- ADR-0001 (minimum external dependencies)
- ADR-0023 (`engine/codegen/aot/` slot reservation)
- ADR-0024 (module graph; `core` module shape)
- ADR-0032 (Phase 8 foundation-first reorg; bench-driven
  discipline at risk per this ADR)
- ADR-0036 + ADR-0038 (0% per-row bench-delta precedents)
- 8b.3-a survey: `private/notes/p8-8b3-aot-survey.md`
  (gitignored, 423 lines)
- wasmer engine-dylib reference: `~/Documents/OSS/wasmer/
  lib/engine-dylib/`
- WasmEdge AOT reference: `~/Documents/OSS/WasmEdge/lib/
  aot/`
- wasmtime/cranelift `.cwasm` reference: `~/Documents/OSS/
  wasmtime/cranelift/codegen/src/machinst/compiled.rs`
- WAMR `.aot` reference: `~/Documents/OSS/wasm-micro-
  runtime/core/iwasm/aot/`

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-09 | `b01be4dc` | Initial accepted version (§9.8b / 8b.3-b design framing; inline-bytes `.cwasm` v0.1 format + pipeline reuse + bench-delta deferred to Phase 12) |
| 2026-05-09 | `b1720a1e` | **Implementation amendment** during 8b.3-c: `CwasmHeader` is **60 bytes** not 56. The original "Total header size: 56 bytes" comment in the Decision § miscounted (4 magic + 14 × u32 = 60, not 4 magic + 13 × u32 = 56). The field shape is unchanged — `relocs_size` was always intended to fit at offset 56..60 — only the byte-count comment was off. `src/engine/codegen/aot/format.zig:header_size = 60` is the authoritative constant; Phase 12 loader reads against it. No load-bearing design change; numeric correction only. |
