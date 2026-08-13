# zwasm product evaluation — measured conformance + binary size (2026-08-14)

> **Doc-state**: ACTIVE
>
> Independent measurement, not a re-reading of existing claims. Every number
> below was produced on the host described in §0 by the scripts in
> `scripts/eval/` (committed alongside this report). Where a claim in
> `README.md` / `.dev/handover.md` is contradicted or narrowed by a
> measurement, the delta is called out explicitly.

## 0. Scope and method

| | |
|---|---|
| Host | `x86_64-linux` (Pop!_OS, kernel 7.0.11, 16 cores, 62 GB RAM) |
| zwasm | `2.5.0`, branch `develop/product-evaluation-2026-08` off `2e40d4314` |
| Zig | 0.16.0 |
| wasmtime | **47.0.3** (`5554cc1a6`) — official release binaries + a source build at the same tag |
| WAMR | **2.4.3** (`a45c42d`), built from source with cmake 4.4.2 / ninja 1.13.2 / gcc |
| wasi-testsuite | `prod/testsuite-base` |

**Single-host caveat.** Everything here is `x86_64-linux`. The project's
3-OS claims (macOS aarch64 / Windows x86_64) are **not** re-verified here;
binary sizes in particular are architecture- and linker-specific and do not
transfer. Where a measurement is expected to be host-independent (spec
directive pass/fail) it is still only evidence for one host.

**wasmtime version choice.** v43 predates the WASI 0.3.0 GA line; comparing
zwasm's full WASI 0.3 surface against it would be meaningless. v47.0.3 is the
line that carries p3, and it is the exact build the host already had
installed — so the source build doubles as a control on the build recipe.

**Why the official wasmtime binaries are used for the size table.**
`ci/build-release-artifacts.sh` builds releases with `panic=abort`,
`strip=debuginfo`, and — for `wasmtime-min` — nightly Rust with
`-Zbuild-std`, `opt-level=s`, `lto=true`, `codegen-units=1`,
`-Zlocation-detail=none`, `--no-default-features`. That is wasmtime's own
best-effort minimum. Reproducing a worse build locally would understate the
competition, so the shipped artifacts are used as the wasmtime rows and the
recipe is disclosed instead.

---

## 1. Conformance

### 1.1 Wasm core spec — interpreter lane

Run at the **CI-equivalent optimize level** (`zig build <step>` with no
`-Doptimize`, i.e. what `scripts/ci_gate.sh` actually runs).

| Corpus | pass | fail | skip | manifests |
|---|---:|---:|---:|---:|
| Wasm 1.0 | 212 | **0** | 20 | 11 |
| Wasm 2.0 (non-SIMD) | 25,539 | **0** | 535 | 86 |
| SIMD + relaxed-SIMD | 25,075 | **0** | 512 | 66 |
| threads / atomics | 294 | **0** | 0 | 1 |
| Wasm 3.0 (6 proposals) | 15,175 directives | **0** | 36 | 86 |

**Zero failures across every core corpus on the interpreter.** That part of
the README holds up.

### 1.2 What the skip counts actually are

The skip numbers look alarming until they are decomposed. Every `skip-adr`
entry in the 1.0 / 2.0 / SIMD corpora resolves to **one** class:

```
skip-adr-skip_text_format_parser   directive-assert_malformed-text
```

— `assert_malformed` directives whose module is supplied as **WAT text**.
zwasm has no text-format parser by design (`README.md`: conversion is
`wasm-tools` / `wabt`'s job), so these are **out of scope, not a conformance
gap**. 509 of SIMD's 512 and all 20 of 1.0's are this class.

That leaves the genuinely interesting residue:

| Corpus | real skips | class |
|---|---:|---|
| Wasm 2.0 | 20 | runtime-skip |
| SIMD | 3 | 1 skip-impl + 2 runtime (`SKIP-JIT-MULTI-MEMORY`, `SKIP-CROSS-MODULE-IMPORTS`) |
| Wasm 3.0 | 36 | per-proposal, see below |

**Recommendation**: report the text-format skips in a separate column
everywhere. Folding them into a single "512 skipped" number makes a clean
result look like a dirty one.

### 1.3 Wasm 3.0, per proposal — interpreter

| Proposal | manifests | modules | `assert_return` | `assert_trap` | `assert_invalid` | skip |
|---|---:|---:|---:|---:|---:|---:|
| memory64 | 21 | 304 | 10,299 / 0 | 2,176 / 0 | 629 / 0 | 4 |
| multi-memory | 37 | 69 | 407 / 0 | 258 / 0 | 2 / 0 | 14 |
| gc | 18 | 91 | 365 / 0 | 126 / 0 | 68 / 0 | 15 |
| function-references | 7 | 15 | 38 / 0 | 4 / 0 | 18 / 0 | 2 |
| tail-call | 2 | 6 | 73 / 0 | 7 / 0 | 27 / 0 | 0 |
| exception-handling | 1 | 4 | 34 / 0 | 2 / 0 | 7 / 0 | 1 |

(`assert_unlinkable` 30, `assert_malformed` 3, `assert_exception` 4 — all
pass, all zero-fail.)

**Measurement-integrity caveat — the runner's arithmetic does not close.**
For `assert_return`, the enumerated directive count exceeds `pass + fail`:

| Proposal | `return=` enumerated | `pass` | unaccounted | printed `skip` |
|---|---:|---:|---:|---:|
| gc | 419 | 365 | **54** | 15 |
| memory64 | 10,315 | 10,299 | **16** | 4 |
| tail-call | 75 | 73 | **2** | 0 |
| function-references | 39 | 38 | **1** | 2 |
| exception-handling | 34 | 34 | 0 | 1 |
| multi-memory | 407 | 407 | 0 | 14 |
| **total** | 11,289 | 11,216 | **73** | 36 |

The per-proposal `skip` column does not fully absorb the difference (73
unaccounted vs 36 skips). Consequently **"0 fail" on Wasm 3.0 does not by
itself establish that every enumerated directive ran** — up to 73
`assert_return` directives are neither passed, failed, nor reported as
skipped. This is a reporting defect in
`test/spec/spec_assert_runner_wasm_3_0.zig`, not evidence of a runtime bug,
but it weakens the headline claim until the counters reconcile.

### 1.4 Wasm 3.0, per proposal — **JIT lane** ← the real gap

The JIT execution lane over the same corpus is reached with
`ZWASM_SPEC_ENGINE=jit`. It is **opt-in and not wired into `test-all`**, so
CI never runs it. Measured per-proposal:

| Proposal | JIT `assert_return` pass | fail | skip | verdict |
|---|---:|---:|---:|---|
| memory64 | — | — | — | **process aborts: exit 70, internal fatal signal** |
| gc | 413 | **1** | 5 | fails `gc/type-subtyping` (returns `Trap`, expected a value) |
| multi-memory | 0 | 0 | **407** | 100 % skipped — JIT multi-memory deferred (ROADMAP §14) |
| tail-call | 71 | 0 | 4 | clean |
| exception-handling | 34 | 0 | 0 | clean |
| function-references | 36 | 0 | 3 | clean |

**memory64 characterisation.** Reproducible (`exit=70`) on the full
proposal corpus; **not** reproducible when each of the 21 manifests runs in
its own process; the interpreter lane over the identical corpus is clean
(10,299 / 2,176 / 629, zero fail). `vm.max_map_count` is not the limit
(2,147,483,642 on this host). So it is a cumulative, cross-manifest effect
inside one process — a focused investigation, not a guess, is what this
needs.

**Consequence for the product claim.** README states Wasm 3.0 "✅ 100 %, all
9 proposals". That is true *of the interpreter*. For the JIT there is one
executing miscompile (gc), one crash (memory64), and one wholly-unimplemented
proposal (multi-memory) — and no gate that would catch a regression in any of
them.

### 1.5 The ReleaseFast blind spot

`scripts/ci_gate.sh` runs `zig build test-all` with **no `-Doptimize`**, so
the spec corpora are only ever validated at Debug/ReleaseSafe. Releases ship
`ReleaseFast`. Measured at `-Doptimize=ReleaseFast`:

- The Wasm 2.0 spec-assert runner **SEGVs deterministically** (3/3 runs,
  exit 142, always at `func/func.0.wasm`).
- The **production path is fine**: the ReleaseFast CLI executes the same
  module's exports correctly on both `--engine interp` and `--engine jit`
  (exit 0, correct values).

So this is a **test-harness limitation, not a runtime miscompile** — the
harness calls raw `module.entry` fn-ptrs, which `build.zig:174` already
documents as violating the JIT host-boundary callee-saved contract under an
optimized host. The consequence survives that distinction, though:

> **There is no spec-level evidence for the build configuration users
> actually download.** `.dev/releasesafe_jit_failures.md` bases its
> "runners already pass in ReleaseSafe" decision on `spec 212` — that is the
> *Wasm 1.0* corpus. The 2.0 corpus (25,539 asserts) was not part of that
> verification, and it is the one that breaks.

### 1.6 Component Model

`zig build test-component-spec` — **170 passed, 0 failed, 0 skipped.** Clean.

### 1.7 WASI 0.1 — the largest gap

Measured with the **official** `WebAssembly/wasi-testsuite` runner and a
zwasm adapter (`scripts/eval/wasi_adapter_zwasm.py`), against the same
corpus, on the same host, in the same session as a wasmtime control:

| Runtime | rust | c | assemblyscript | **total** |
|---|---:|---:|---:|---:|
| **zwasm 2.5.0** | 33 / 46 | 13 / 14 | 8 / 12 | **54 / 72** |
| wasmtime 47.0.3 (control) | 46 / 46 | 14 / 14 | 12 / 12 | **72 / 72** |

The control passing 72/72 through the identical harness establishes that the
18 zwasm failures are real gaps, not adapter artifacts.

Failing tests — **this list is the roadmap**:

- **filesystem / fd semantics (13, rust)**: `fd_flags_set`,
  `interesting_paths`, `dir_fd_op_failures`, `renumber`,
  `truncation_rights`, `dangling_symlink`, `nofollow_errors`,
  `path_open_read_write`, `fd_readdir`, `directory_seek`,
  `fd_fdstat_set_rights`, `path_open_preopen`, `poll_oneoff_stdio`
- **write semantics (1, c)**: `pwrite-with-append`
- **argv / env / random / stdout (4, assemblyscript)**:
  `args_get-multiple-arguments`, `environ_get-multiple-variables`,
  `random_get-zero-length`, `fd_write-to-stdout` — all four abort inside the
  AssemblyScript allocator (`~lib/rt/tlsf.ts`), which smells like one shared
  root cause rather than four.

README currently rates WASI 0.1 "✅ functional". Against the official suite
it is **75 %**. `test/wasi/` holds 3 hand-written fixtures; that is the whole
of the in-repo evidence. **Wiring this suite into CI is the single
highest-value test-infrastructure change available.**

### 1.8 WASI 0.2

**There is no upstream conformance suite for WASI 0.2** — `wasi-testsuite`
ships `wasm32-wasip1` and `wasm32-wasip3` only. There is also no
`test-wasi-p2` build step. What exists as evidence:

- Component Model spec corpus: 170 / 0 / 0 (§1.6)
- 85 real `wasm32-wasip2` component fixtures under `test/component/`,
  exercised from `zig build test`

That is a reasonable substitute, but it should be described as such rather
than as conformance. The honest public phrasing is "no official suite
exists; here is what we do test".

### 1.9 WASI 0.3 — and the differentiation sentence

The upstream `wasm32-wasip3` corpus has **52** tests. zwasm vendors **45** of
them (`scripts/vendor_wasip3_official.sh`); the 7 omissions are all
`http-client-*` variants (`headers`, `method`, `path`, `path-none`,
`send-errors`, `sent`, `status`).

| Runtime | denominator | result |
|---|---|---|
| zwasm 2.5.0 | its vendored 45 | **45 / 45** (48/48 incl. adjacent tests, verified this session) |
| wasmtime 47.0.3 | full upstream 52 | 48 / 52 — fails `http-service-uri`, `http-client-path-none`, `filesystem-read-directory`, `http-client-sent` |
| **on the common 45** | | **zwasm 45 / 45 · wasmtime 43 / 45** |

wasmtime's two failures inside the common set are `http-service-uri` and
`filesystem-read-directory`, both of which zwasm passes.

> **Differentiation sentence (defensible as measured):**
> *On the 45 official `wasm32-wasip3` conformance tests both runtimes carry,
> zwasm 2.5.0 passes 45/45 where wasmtime 47.0.3 passes 43/45 — measured on
> x86_64-linux, 2026-08-14.*

Two honesty constraints on using it: the denominator is zwasm's vendored
subset (87 % of upstream), and zwasm's 45/45 is measured through the
**in-process embedder harness**, not the CLI (§1.10).

### 1.10 WASI 0.3 is verified through the embedder API, not the CLI

The 45 official p3 tests are Zig unit tests in
`src/api/component_wasi_p3.zig` driving the corpus in-process. Driving the
same component through the `-Dwasi=p3` **CLI** does not reproduce it — e.g.
`cli-stdout-flush.wasm` fails its own guest assertion
(`left: Complete(0), right: Complete(1)`) under `zwasm run`, while the
in-process test for the same binary passes.

Worse, driving the full upstream p3 corpus through the CLI with the official
runner **hangs**: `cli-stdout-flush.wasm` was still running after 364 s (the
run had to be bounded by `timeout`), where the in-process test for the same
binary completes in milliseconds.

So "WASI 0.3 full coverage" is a statement about the **embedding API
surface**. The CLI's p3 conformance is not merely unmeasured — it does not
survive the first stdio test of the official suite.

---

## 2. Binary size (x86_64-linux)

### 2.1 What is and is not separable

There is **no CLI-only artifact**. `build.zig` roots the runtime at the
`core` module (`src/zwasm.zig`), which is *itself* the `root_module` of
`libzwasm.a`; the CLI is a thin `exe_mod` (`src/cli/main.zig`) that imports
`core` and links statically. So "the CLI layer's size" can only be a derived
difference, never a measured artifact.

Also: `libzwasm.a` has **2 members** (`libzwasm_zcu.o` + `compiler_rt.o`)
where WAMR's `libiwasm.a` has 49. Archive size is therefore a poor proxy for
embedder cost — only the **linked** image is meaningful. All cross-engine
comparisons below use the same minimal C host
(`docs/examples/c_host/hello.c`) linked against each runtime's static
library.

### 2.2 zwasm matrix — ReleaseFast, as-built vs `strip -s`

| engine | wasi | CLI as-built | CLI stripped | embedder host stripped | `libzwasm.a` |
|---|---|---:|---:|---:|---:|
| interp | none | 16,910,912 | 2,703,896 | 2,847,920 | 28,431,740 |
| interp | p1 | 16,911,000 | 2,703,896 | 2,847,920 | 28,431,740 |
| interp | p2 | 19,548,832 | 3,076,488 | 2,847,920 | 28,431,740 |
| interp | p3 | 24,389,504 | 3,790,360 | 2,847,920 | 28,431,740 |
| jit | none | 16,911,000 | 2,703,896 | 2,847,920 | 28,431,676 |
| jit | p1 | 16,911,096 | 2,703,896 | 2,847,920 | 28,431,740 |
| jit | p2 | 19,548,920 | 3,076,488 | 2,847,920 | 28,431,676 |
| jit | p3 | 24,389,592 | 3,790,360 | 2,847,920 | 28,431,676 |
| both | none | 16,910,960 | 2,703,912 | 2,847,920 | 28,431,676 |
| both | p1 | 16,911,048 | 2,703,912 | 2,847,920 | 28,431,740 |
| both | p2 | 19,548,864 | 3,076,488 | 2,847,920 | 28,431,676 |
| both | p3 | 24,389,536 | 3,790,360 | 2,847,920 | 28,431,740 |

All twelve `(engine, wasi)` combinations were measured. The `interp` / `jit`
/ `both` rows differ by 16–96 bytes at every tier — the length of the
version string, nothing else (§2.4). The stripped CLI takes exactly three
distinct values across the whole matrix, one per WASI tier
(2.70 MB / 3.08 MB / 3.79 MB), and the stripped embedder host takes exactly
one (2,847,920) across all twelve.

`.text` only, same builds:

| build | CLI `.text` | embedder `.text` |
|---|---:|---:|
| interp/none | 2,143,821 | 2,141,722 |
| interp/p1 | 2,143,821 | 2,141,722 |
| interp/p2 | 2,458,365 | 2,141,722 |

**Two findings fall out of this table.**

1. **`-Dwasi` works for the CLI, and is a no-op for embedders.** p1→p2 costs
   the CLI +314,544 bytes of `.text` (+14.7 %), matching the documented
   "~-8 %" lean-build claim in spirit. The linked C host is
   `.text`-identical at `none` / `p1` / `p2` / `p3` — `--gc-sections`
   already drops whatever the host does not call. This is not a defect, but
   it does mean **the WASI tier knob is effectively CLI-only**, and the
   README's "lean build" framing should say so.

2. **Debug info dominates the shipped artifact.** The default ReleaseFast
   CLI is 19.5 MB as-built and 3.08 MB stripped — **84 % is debug info**.
   `bench/results/size_history.yaml` records ReleaseFast `base` as 3,563,960
   at `698eeff5d`; that series measures the macOS-shaped binary and does not
   describe what a Linux user downloads.

### 2.3 ReleaseSmall — the configuration that should be advertised

`-Doptimize=ReleaseSmall -Dstrip=true`:

| engine | wasi | CLI | embedder `.text` |
|---|---|---:|---:|
| interp | p1 | **1,516,800** | 1,038,993 |
| jit | p1 | **1,516,800** | 1,038,993 |
| both | p2 | **1,789,720** | 1,038,985 |

### 2.4 ⚠ `-Dengine` does not change the binary

Three CLIs differing **only** in `-Dengine`, ReleaseFast, `-Dwasi=p1`,
unstripped:

| `-Dengine` | file size | `.text` | `engine.codegen` symbols | backend `emit` symbols |
|---|---:|---:|---:|---:|
| `interp` | 16,911,000 | **2,143,821** | **621** | 1 |
| `jit` | 16,911,096 | **2,143,821** | **621** | 1 |
| `both` | 16,911,048 | **2,143,821** | **621** | 1 |

`.text` is byte-identical and the JIT codegen symbol count is unchanged, so
**`-Dengine=interp` does not remove the JIT**. The same holds at
ReleaseSmall/p1, where `interp` and `jit` produce identical 1,516,800-byte
binaries with identical 1,038,993-byte `.text`.

The option is documented as "Engine selection compiled in"
(`docs/development.md`). On this host it selects a *default engine at
runtime*, not a compile-time subset — which is precisely the axis an
embedder shopping on size would reach for first.

`scripts/check_build_dce.sh` enforces symbol-absence and `.text`
monotonicity across the `-Dwasm` and `-Dwasi` axes but **not across
`-Dengine`**, so the existing gate cannot see this.

### 2.6 ⚠ `-Dstrip=true` cannot build the default step

`zig build -Dstrip=true` fails at **both** ReleaseFast and ReleaseSafe, 3/3
runs each, with three **Zig 0.16.0 compiler SEGVs** (`error: process
terminated with signal SEGV` out of `zig build-exe`). The crashing artifacts
are not the product:

```
compile exe zwasm-spec-wasm-2-0-assert  ReleaseFast native failure
compile exe zwasm-spec-wasm-3-0-assert  ReleaseFast native failure
compile exe zwasm-wast-runtime-runner   ReleaseFast native failure
```

Two separable problems:

1. **Packaging** — a plain `zig build` installs three *test runners* into
   `zig-out/bin/` next to `zwasm`. They are `b.installArtifact`'d, so every
   product build pays for them and any compiler bug they trigger becomes a
   product build failure.
2. **A documented option is unusable** — `-Dstrip` is listed in
   `docs/development.md` as a supported knob. `zig build static-lib
   -Dstrip=true -Doptimize=ReleaseFast` *does* succeed (`libzwasm.a`
   3,412,468 vs 28,431,740 unstripped — the archive is 88 % debug info), so
   the failure is confined to the default install step.

Workaround for the product binary is external `strip -s`, which is what
every measurement in §2.2/§2.3 uses.

### 2.5 Cross-engine comparison

Same host, same `strip -s`, all stripped unless noted.

| Runtime | configuration | binary | stripped | `.text` |
|---|---|---:|---:|---:|
| **WAMR 2.4.3** | classic-interp, MinSizeRel+LTO, no SIMD | 307,208 | **264,216** | 151,573 |
| **WAMR 2.4.3** | fast-interp, MinSizeRel+LTO | 364,752 | **319,512** | 200,752 |
| WAMR 2.4.3 | classic-interp, Release, no SIMD | 425,552 | 374,728 | — |
| WAMR 2.4.3 | fast-interp, Release | 502,696 | 450,504 | — |
| WAMR 2.4.3 | Fast-JIT, Release, no SIMD | 801,072 | 712,152 | — |
| **zwasm 2.5.0** | interp, p1, ReleaseSmall+strip | 1,516,800 | **1,516,792** | 1,038,993 |
| **zwasm 2.5.0** | both, p2, ReleaseSmall+strip | 1,789,720 | **1,789,712** | — |
| **wasmtime 47.0.3** | `wasmtime-min`, official | 3,191,432 | **2,220,336** | — |
| zwasm 2.5.0 | interp, p1, ReleaseFast | 16,911,000 | 2,703,896 | 2,143,821 |
| zwasm 2.5.0 | both, p2, ReleaseFast (default) | 19,548,832 | 3,076,488 | 2,458,365 |
| wasmtime 47.0.3 | full CLI, official | 60,742,448 | 47,958,568 | — |

Static libraries (archives — not comparable to linked images, see §2.1):

| Runtime | archive | bytes | members |
|---|---|---:|---:|
| WAMR | `libiwasm.a` (classic) | 1,122,402 | 49 |
| WAMR | `libiwasm.a` (Fast-JIT) | 1,945,350 | — |
| zwasm | `libzwasm.a` | 28,431,740 | 2 |
| wasmtime | `libwasmtime.a` | 68,705,400 | — |

**Reading of the size result.**

- Against **wasmtime**, zwasm wins: 1.52 MB vs 2.22 MB for the two projects'
  respective minimum builds — and zwasm gets there with a stable toolchain
  where `wasmtime-min` needs nightly Rust and `-Zbuild-std`.
- Against **WAMR**, zwasm loses by **5.7×** (1.52 MB vs 264 KB). WAMR is the
  reference point for the deeply-embedded segment, and no zwasm build option
  closes that gap.
- The honest positioning is therefore **"substantially smaller than
  wasmtime, not competitive with WAMR"** — the "lightweight" half of the
  ADR-0153 完成形 bar holds only against the JIT-class competition.
- One capability caveat in WAMR's favour is worth recording accurately:
  upstream WAMR **rejects SIMD + classic-interp and SIMD + Fast-JIT at
  configure time**, so the 264 KB row has no SIMD. zwasm's interpreter does
  SIMD (25,075 asserts, zero fail). Part of the size difference is bought
  capability, not waste.

---

## 3. Findings, ordered by product impact

| # | Finding | Evidence | Suggested disposition |
|---|---|---|---|
| F1 | WASI 0.1 is 54/72 on the official suite; README says "functional" | §1.7, control 72/72 | Wire the official suite into CI; work the 18-item list. Re-word README. |
| F2 | JIT lane on Wasm 3.0: memory64 crashes (exit 70), gc miscompiles 1 (`type-subtyping`), multi-memory 407/407 skipped — and CI never runs the lane | §1.4 | Gate the lane; fix or document each. Qualify the "Wasm 3.0 100 %" claim as interpreter-scoped. |
| F3 | `-Dengine=interp` does not remove the JIT | §2.4 | Either make the option real or drop it; extend `check_build_dce.sh` to the engine axis either way. |
| F4 | ReleaseFast — the shipped configuration — has no spec coverage | §1.5 | Add a ReleaseFast (or ReleaseSafe) spec leg; fix the 3 raw-entry harness call sites the 2.0 corpus trips. |
| F5 | Not competitive with WAMR on size (5.7×) | §2.5 | Product decision, not a bug. Stop claiming "lightweight" without naming the comparison class. |
| F6 | WASI 0.3 45/45 is 45 **of 52** upstream, and is embedder-API-only | §1.9, §1.10 | Disclose the denominator; measure the CLI path. |
| F7 | Default ReleaseFast artifact is 84 % debug info; ReleaseSmall is 5× smaller and unadvertised | §2.2, §2.3 | Ship/document `ReleaseSmall -Dstrip=true` as the distribution config. |
| F8 | Skip reporting conflates out-of-scope text-format directives with real gaps | §1.2 | Split the column. 509 of 512 SIMD "skips" are by-design. |
| F9 | `-Dwasi` is a no-op for C embedders | §2.2 | Documentation fix. |
| F10 | No official WASI 0.2 suite exists anywhere | §1.8 | Describe the substitute honestly rather than as conformance. |
| F11 | `-Dstrip=true` cannot build the default step (Zig 0.16.0 SEGV on 3 installed test-runner exes) | §2.6 | Stop `installArtifact`-ing test runners into the product install step; report the compiler crash upstream. |
| F12 | zwasm CLI hangs on the first official WASI 0.3 stdio test | §1.10 | Decide whether the CLI is a supported p3 surface; if yes, gate it. |
| F13 | Wasm 3.0 runner's counters do not reconcile — 73 `assert_return` directives are neither pass, fail, nor skip | §1.3 | Fix the accounting before quoting "0 fail" as coverage. |

### What held up

Worth stating plainly, because most of this report is deltas: the
interpreter is **zero-fail across every core corpus measured** — 1.0, 2.0,
SIMD + relaxed-SIMD, atomics, and all six Wasm 3.0 proposals, 66,000+
directives. Component Model is 170/0/0. WASI 0.3 is 45/45 and beats
wasmtime on the common subset. Those are strong results and none of them
needed qualification.

## 4. Reproduction

```bash
bash scripts/eval/conformance_sweep.sh                      # §1.1 – §1.6
WASI_TESTSUITE=<clone> bash scripts/eval/wasi_official.sh   # §1.7, §1.9, §1.10
bash scripts/eval/size_matrix.sh                            # §2.2 – §2.6
```

`scripts/eval/wasi_adapter_zwasm.py` is the wasi-testsuite runtime adapter
(`wasi_official.sh` copies it into the clone). The wasmtime control run is
part of the same script — a failure list without it is not evidence.

WASI 0.3's own 45/45 comes from
`zig build test-wasi-p3 -Dtest-filter=wasip3-official` (in-process), not
from the CLI; see §1.10 for why those are different measurements.
