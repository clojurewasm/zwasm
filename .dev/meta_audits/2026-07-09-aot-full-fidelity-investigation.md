# AOT full-fidelity campaign — Phase I investigation findings

> **Doc-state**: ACTIVE
> Campaign: AOT-full-fidelity (user-ratified 2026-07-09). Phase I of the
> ADR-0153 five-phase structure. Detail notes (gitignored):
> `private/notes/aot-campaign-{inventory,wasmtime,wazero-wamr,roi-and-parity}.md`
> + `private/notes/d508-cache-survey.md`.

## Mission (user directive, 2026-07-09)

本当の cwasm/AOT: deploy artifact stays `.wasm`; `.cwasm` is (a) the explicit
`zwasm compile` output and (b) the transparent-cache value (D-508). A `.cwasm`
must load back into the FULL runtime — cache-hit == cache-miss — and cover all
module classes. Peers ship exactly this split (wasmtime `Config::cache`,
wazero `NewCompilationCacheWithDir`): users deploy `.wasm`; the runtime keeps
its own hashed, versioned artifact store.

## Measured ROI (arm64 Mac, ReleaseSafe, hyperfine)

| fixture         | size  | fresh `.wasm` | pre `.cwasm` | saved |
|-----------------|-------|---------------|--------------|-------|
| cpp_json_parse  | 250KB | 3.5 ms        | 1.5 ms       | 57%   |
| tinygo_json     | 600KB | 8.5 ms        | 3.4 ms       | 60%   |
| go_json_marshal | 3.2MB | —             | (grow gap)   | compile alone = **112 ms** |
| go_regex        | 3.0MB | —             | (grow gap)   | compile alone = **108 ms** |

Compile tax scales with module size; ~110 ms/run for 3MB Go modules is the
headline a transparent cache buys. Execution-dominated fixtures see ~0.

## Live fidelity bugs found by direct experiment (2026-07-09)

1. **`.cwasm` with GC code fatally crashes in a fresh process (D-516,
   now-class)**. Repro: `struct.new` module → `zwasm run` = 42;
   `zwasm compile` = exit 0 (silent); `zwasm run x.cwasm` = "internal error —
   caught a fatal signal", exit 70. Root cause (inventory): 13 Zig helper
   addresses (`jitGcAlloc`, `jitCallIndirectResolve`, `rethrowFromExnref`,
   GC array family, `jitGcRefCast/RefTest`) are baked as `MOVZ/MOVK` /
   `movabs` imm64 into emitted code across 32 op files; the only reloc kind is
   `direct_call`; zwasm is PIE (verified `otool -hv`: PIE) so per-exec ASLR
   invalidates them. `produceFromCompiledWasm` has NO refusal for
   call_indirect/GC/EH modules — it serializes the landmine silently.
   (call_indirect happens to survive because elem-initialized slots are
   pre-resolved into `funcptr_base` and the happy path never calls the
   resolve helper — the bake is still live on the lazy path.)
2. **`memory.grow` is entirely unsupported on the `.cwasm` run path** —
   go_json_marshal/go_regex die "runtime: out of memory: cannot allocate
   4194304-byte block" (exit 2) on `.cwasm` while `.wasm` runs fine; zero
   `grow` hits in `aot/{run,load}.zig`. The mini-runtime allocs min_pages
   plain-heap per call and frees it.

## Gap inventory (condensed; full table in the private note)

- **Serialized today** (`.cwasm` v0.4): code bytes, per-func offsets/n_slots,
  direct-call relocs, defined-func sigs, exports, pre-evaluated global init
  VALUES, memory min/max + active data, table-0 size + active elems, imports
  metadata (module/name/kind), arch tag + format version. Magic `CWAS`.
- **Lost / never serialized**: exception_table + tag_param_counts (EH),
  per-func oob_stub_off + trap_func_entries (guard elision, D-515),
  global valtypes, raw typeidxs, IMPORT func sigs, start-function idx (!),
  passive segments, GC type info, memory idx_type/page-size/shared.
- **Refused by produce**: elided bounds (ADR-0202 D5), non-const global/data/
  elem init offsets, >4096-page memories, >255 param/result counts.
- **Silent-landmine accepted**: GC / EH / call_indirect modules (D-516).
- **The load side is a parallel mini-runtime** (`aot/load.zig::LoadedModule`
  + `aot/run.zig`): throwaway per-call runtime, plain-heap non-growable
  memory, void/i32 results only, table-0 only, no EH/GC/fuel/interrupt, no
  trap-registry registration. "COMPUTE-ONLY" by its own doc.

## The good news (what makes full fidelity tractable)

- `setupRuntimeLinked` (setup.zig) depends ONLY on `CompiledWasm` +
  `wasm_bytes`; it bakes no absolute addresses — every runtime pointer is
  computed at setup from live allocations. **Deserialize-into-CompiledWasm →
  reuse the normal setup path** is architecturally viable and reuses ONE code
  path for fresh and cached runs (the wasmtime property "cache hit takes the
  exact same load path as deserialize").
- Runtime trampolines that already go through `JitRuntime` struct fields
  (`memory_grow_fn` / `table_grow_fn` / `reify_exnref_fn`, called via
  `[rt+off]`) are position-independent — the model the 13 baked helpers
  should move to.
- SIMD const pools are PC-relative in-body; br_table is CMP+B chains;
  direct-call relocs are already load-time patched. All PIC. ✅

## Peer patterns adopted (wasmtime 48 / wazero @c0f3a4e / WAMR @9bc0cda)

- **wasmtime**: artifact == runtime image; loader REJECTS relocations;
  host/builtin calls go PC-relative → trampoline → VMContext fn-ptr array.
  Trap table = offset-relative binary-searchable side section (the D-515
  blueprint). Two-tier gate: metadata section (loadability, hard error) vs
  SHA-256 content cache key. Cache: `modules/<compiler>-<ver>/<hash>`, zstd,
  temp+rename, background LRU (65536 files / 512 MiB → 70%).
- **wazero**: serialize ONLY relocation-free function bodies (+ offsets,
  CRC32, relative source map, try-table meta); recompute address-bound shims
  (entry preambles, builtin trampolines) at load. ALL runtime pointers reached
  via context-register + fixed offset — zero absolutes in code. Versioned dir
  `wazero-<ver>-<arch>-<os>` + in-file version + CPU bits in key; silent miss
  on any mismatch; no eviction; temp+rename, no locks.
- **WAMR**: the contrast — relocatable object linked at load (symbol map,
  in-place patching). zwasm's current direct-call-fixup format is closest to
  this; wazero/wasmtime's "no relocation" is the cleaner target for the
  helper problem.

## Decisions seeded for the Phase III ADR

1. **Kill the 13 helper-address bakes via `JitRuntime`-field indirection**
   (wazero pattern; `memory_grow_fn` precedent in-tree) — NOT via a new
   abs64 reloc kind. Removes the 32-file bake sprawl, makes code bytes fully
   PIC, and fixes D-516 for fresh JIT and AOT alike.
2. **Deserialize into `CompiledWasm`; reuse `setupRuntimeLinked`**; the
   `aot/run.zig` mini-runtime is retired for `zwasm run` use (kept only if a
   freestanding use-case needs it). memory.grow/guarded memory/WASI/EH/GC
   come for free from the shared setup path.
3. **Format v0.5+**: add EH tables + tag params, global valtypes, import
   sigs, raw typeidxs, start-func idx, per-func oob_stub_off + elision bit
   (D-515), passive segments; wasmtime-style two-tier gate = loadability
   metadata (version/arch/bounds/feature flags — hard error) separate from
   the cache content key.
4. **D-508 cache on top**: key = SHA-256(wasm bytes) under dir
   `zwasm-<ver>-<arch>-<bounds>/`; temp+rename atomic writes; silent miss on
   any mismatch; eviction v1 = none + `--cache-clear` (wazero parity),
   size-cap LRU later.
5. **Correctness net BEFORE redesign (Phase II)**: the in-process D-510
   fuzz lane CANNOT see ASLR staleness (same process = same addresses) — the
   AOT lane must cross a process boundary (compile in one process, run
   `.cwasm` in another), extending the realworld diff_runner --aot lane +
   a crafted corpus incl. GC/call_indirect/EH/grow shapes.

## Phase status

- [x] I Investigation (this doc)
- [ ] II Correctness net: cross-process AOT differential lane + characterization
- [ ] III Design ADR
- [ ] IV Staged implementation
- [ ] V Retrospective
