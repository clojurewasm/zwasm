# zwasm product evaluation: measured conformance and binary size (2026-08-14)

> **Doc-state**: ACTIVE
>
> Every number below was measured on the host in §0 using the scripts in
> `scripts/eval/`. Claims are separated into three kinds and labelled:
> **Measured** (a number this session produced), **Read from source** (a fact
> established by reading committed code or config), and **Not established**
> (an open question that the measurement did not answer). Statements of the
> third kind are never used to support a conclusion.

## 0. Scope and method

| | |
|---|---|
| Host | `x86_64-linux` (Pop!_OS, kernel 7.0.11, 16 cores, 62 GB RAM) |
| zwasm | `2.5.0`, branch `develop/product-evaluation-2026-08` off `2e40d4314` |
| Zig | 0.16.0 |
| wasmtime | 47.0.3 (`5554cc1a6`), official release binaries |
| WAMR | 2.4.3 (`a45c42d`), built from source (cmake 4.4.2, ninja 1.13.2, gcc) |
| wasi-testsuite | `prod/testsuite-base` |

**Single-host caveat.** Everything here is `x86_64-linux`. The project's
3-OS claims (macOS aarch64, Windows x86_64) are not re-verified. Binary
sizes are architecture- and linker-specific and do not transfer.

**Why wasmtime 47.0.3.** It is the newest release, it carries WASI 0.3
support, and it is the exact build already installed on this host, so the
comparison uses a binary that was not produced for this report.

*Not established*: whether wasmtime 43.0.0 has usable WASI 0.3 support.
43.0.0 accepts the `-Sp3` flag but does not document it in `run --help`.
This report makes no claim about 43.0.0 either way.

**Why the official wasmtime binaries are used for the size table.**
`ci/build-release-artifacts.sh` builds releases with `panic=abort` and
`strip=debuginfo`. For `wasmtime-min` it additionally uses nightly Rust with
`-Zbuild-std`, `opt-level=s`, `lto=true`, `codegen-units=1`,
`-Zlocation-detail=none` and `--no-default-features`. A local
`cargo build --release` of the same tag produced a 75,640,176-byte CLI
against the official 60,742,448-byte artifact, so a locally built row would
have understated wasmtime by 24%. The shipped artifacts are used instead and
the recipe is disclosed here.

---

## 1. Conformance

### 1.1 Wasm core spec, interpreter

**Measured.** Run with no `-Doptimize`, which is what `scripts/ci_gate.sh`
runs.

| Corpus | pass | fail | skip | manifests |
|---|---:|---:|---:|---:|
| Wasm 1.0 | 212 | 0 | 20 | 11 |
| Wasm 2.0 (non-SIMD) | 25,539 | 0 | 535 | 86 |
| SIMD and relaxed-SIMD | 25,075 | 0 | 512 | 66 |
| threads / atomics | 294 | 0 | 0 | 1 |
| Wasm 3.0 (6 proposals) | 15,175 directives | 0 | 36 | 86 |

Zero failures on every core corpus on the interpreter.

**One delta against the README.** The README rates Wasm 2.0 as
"`skip-impl == 0`". The SIMD corpus, which the README lists inside the Wasm
2.0 row, reports **1 skip-impl**. The non-SIMD 2.0 corpus is 0.

### 1.2 What the skip counts contain

**Measured.** Every `skip-adr` entry in the 1.0, 2.0 and SIMD corpora is one
class:

```
skip-adr-skip_text_format_parser   directive-assert_malformed-text
```

These are `assert_malformed` directives whose module is given as WAT text.
**Read from source**: zwasm has no text-format parser, and the README
assigns text conversion to `wasm-tools` and `wabt`. So these directives are
outside the implemented surface. 509 of the SIMD corpus's 512 skips and all
20 of the 1.0 corpus's are this class.

The remainder:

| Corpus | remaining skips | class |
|---|---:|---|
| Wasm 2.0 | 20 | runtime-skip |
| SIMD | 3 | 1 skip-impl, 2 runtime (`SKIP-JIT-MULTI-MEMORY`, `SKIP-CROSS-MODULE-IMPORTS`) |
| Wasm 3.0 | 36 | per proposal, see §1.3 |

**Recommendation.** Report text-format skips in a separate column. A single
"512 skipped" figure overstates the gap by about 170x.

### 1.3 Wasm 3.0 per proposal, interpreter

**Measured.**

| Proposal | manifests | modules | `assert_return` | `assert_trap` | `assert_invalid` | skip |
|---|---:|---:|---:|---:|---:|---:|
| memory64 | 21 | 304 | 10,299 / 0 | 2,176 / 0 | 629 / 0 | 4 |
| multi-memory | 37 | 69 | 407 / 0 | 258 / 0 | 2 / 0 | 14 |
| gc | 18 | 91 | 365 / 0 | 126 / 0 | 68 / 0 | 15 |
| function-references | 7 | 15 | 38 / 0 | 4 / 0 | 18 / 0 | 2 |
| tail-call | 2 | 6 | 73 / 0 | 7 / 0 | 27 / 0 | 0 |
| exception-handling | 1 | 4 | 34 / 0 | 2 / 0 | 7 / 0 | 1 |

`assert_unlinkable` 30, `assert_malformed` 3 and `assert_exception` 4 also
pass with zero failures.

**Coverage limit of this table.** The README names **9** Wasm 3.0 proposals:
GC, EH, tail-call, memory64, multi-memory, typed func refs, extended-const,
relaxed-simd, custom annotations. This table covers 6. relaxed-simd is
covered separately in the SIMD corpus (7 sub-corpora, §1.1), giving **7 of
9** with a per-proposal number.

**Read from source**: extended-const and custom annotations have no
dedicated sub-corpus. Both are implemented
(`src/instruction/wasm_3_0/extended_const.zig`) and both appear inside other
proposals' raw `.wast` files (for example
`memory64/raw/annotations.wast`), so they are exercised incidentally.

*Not established*: a per-proposal conformance figure for extended-const and
custom annotations. This report cannot confirm or refute the README's "all 9
proposals" for those two.

### 1.4 Wasm 3.0 per proposal, JIT

**Read from source**: the JIT lane is selected by `ZWASM_SPEC_ENGINE=jit`.
It is not set in `.github/workflows/` or `scripts/ci_gate.sh`, so CI does
not run it.

**Measured**, per proposal:

| Proposal | JIT `assert_return` pass | fail | skip | result |
|---|---:|---:|---:|---|
| memory64 | n/a | n/a | n/a | process exits 70, internal fatal signal |
| gc | 413 | 1 | 5 | fails `gc/type-subtyping`, returns `Trap` where a value was expected |
| multi-memory | 0 | 0 | 407 | every directive skipped |
| tail-call | 71 | 0 | 4 | no failures |
| exception-handling | 34 | 0 | 0 | no failures |
| function-references | 36 | 0 | 3 | no failures |

**memory64.** Reproducible at `exit=70` on the full proposal corpus. Not
reproducible when each of the 21 manifests runs in its own process. The
interpreter over the identical corpus is clean (10,299 / 2,176 / 629, zero
fail). `vm.max_map_count` is 2,147,483,642 on this host, so map-count
exhaustion is excluded.

*Not established*: the mechanism. The evidence shows only that the abort
requires more than one manifest in a single process. Whether that is
accumulated state, address-space pressure, or a codegen fault is open.

**multi-memory.** *Not established*: the cause of the 407 skips. The
`SKIP-JIT-MULTI-MEMORY` token carrying the text "multi-memory on JIT
deferred to Phase 14 (ROADMAP §14)" was observed in the **SIMD** runner's
output, not in this run. The 407 figure is measured; attributing it to the
documented deferral is an inference.

**Effect on the product claim.** The README's Wasm 3.0 row describes the
runtime without distinguishing engines. On the JIT there is one executing
wrong result (gc), one abort (memory64), and one proposal at 0 executed
directives (multi-memory). No gate covers any of them.

### 1.5 ReleaseFast has no spec coverage

**Read from source**: `scripts/ci_gate.sh` runs `zig build test-all` with no
`-Doptimize`, so the spec corpora are validated at Debug and ReleaseSafe
only. Releases ship ReleaseFast.

**Measured** at `-Doptimize=ReleaseFast`:

- The Wasm 2.0 spec-assert runner aborts on 3 of 3 runs, exit 142, always
  after `func/func.0.wasm`.
- The ReleaseFast CLI executes exports of that same module correctly on both
  `--engine interp` and `--engine jit` (4 exports checked: `type-use-2`,
  `local-first-i32`, `local-mixed`, `empty`; exit 0, expected values).

The production path therefore works on the cases checked, and
`build.zig:174` documents that the harness calls raw `module.entry`
fn-ptrs, which violates the JIT host-boundary callee-saved contract under an
optimized host. That is consistent with a harness limitation.

*Not established*: that no ReleaseFast runtime defect exists. Four exports
of one module is a narrow check. What is established is that the spec
corpora cannot currently be run at ReleaseFast at all.

**The consequence stands regardless of the cause.** There is no spec-level
evidence for the configuration users download.
`.dev/releasesafe_jit_failures.md` justifies its "runners already pass in
ReleaseSafe" decision with `spec 212`, which is the Wasm 1.0 corpus. The 2.0
corpus (25,539 asserts) was not in that verification, and it is the one that
aborts.

### 1.6 Component Model

**Measured**: `zig build test-component-spec` reports 170 passed, 0 failed,
0 skipped.

### 1.7 WASI 0.1

**Measured** with the official `WebAssembly/wasi-testsuite` runner and the
adapter in `scripts/eval/wasi_adapter_zwasm.py`, against the same corpus, on
the same host, with a wasmtime control in the same session.

**The engine matters, so all three lanes are reported.**

| Runtime / engine | rust | c | assemblyscript | total |
|---|---:|---:|---:|---:|
| zwasm `--engine interp` | 34 / 46 | 13 / 14 | 12 / 12 | **59 / 72** |
| zwasm `--engine jit` | 34 / 46 | 13 / 14 | 8 / 12 | **55 / 72** |
| zwasm default (`auto`) | 34 / 46 | 13 / 14 | 8 / 12 | 55 / 72 |
| wasmtime 47.0.3 (control) | 46 / 46 | 14 / 14 | 12 / 12 | **72 / 72** |

The control passing 72/72 through the identical harness establishes that the
zwasm failures are gaps in zwasm, not adapter artifacts.

The README scopes its WASI 0.1 rating to the interpreter, so **59 / 72 is
the figure that corresponds to the README's claim**.

**13 failures are engine-independent.** These are the WASI-layer gaps:

- filesystem and fd semantics (12, rust): `dir_fd_op_failures`,
  `directory_seek`, `fd_fdstat_set_rights`, `fd_flags_set`, `fd_readdir`,
  `interesting_paths`, `nofollow_errors`, `path_open_preopen`,
  `path_open_read_write`, `poll_oneoff_stdio`, `renumber`,
  `truncation_rights`
- write semantics (1, c): `pwrite-with-append`

**4 further failures occur only on the JIT.** All four are AssemblyScript
tests that pass on the interpreter and fail under `--engine jit`:
`args_get-multiple-arguments`, `environ_get-multiple-variables`,
`random_get-zero-length`, `fd_write-to-stdout`. Because the interpreter
passes them, the defect is in the JIT path, not in the WASI host
implementation. This is a second JIT correctness gap alongside §1.4.

**One failure was flaky and is excluded.** `dangling_symlink` failed once in
the first combined run and then passed on 6 of 6 re-runs (3 `auto`, 3
`interp`). It is not counted above and should not be treated as a gap
without a repeat.

The README rates WASI 0.1 "✅ functional". Against the official suite the
interpreter is at **82%** (59/72). `test/wasi/` holds 3 hand-written
fixtures, which is the whole of the in-repo evidence. Wiring the official
suite into CI would convert 13 unknown gaps into a tracked list.

### 1.8 WASI 0.2

**Read from source**: `wasi-testsuite` ships `wasm32-wasip1` and
`wasm32-wasip3` only, so no upstream conformance suite for WASI 0.2 exists.
`build.zig` declares no `test-wasi-p2` step.

What exists as evidence instead:

- Component Model spec corpus: 170 / 0 / 0 (§1.6)
- 85 `wasm32-wasip2` component fixtures under `test/component/`, run from
  `zig build test`

That is a reasonable substitute. It should be described as a substitute
rather than as conformance, because no conformance figure is obtainable.

### 1.9 WASI 0.3

**Measured.** The upstream `wasm32-wasip3` corpus has 52 tests. zwasm
vendors 45 of them (`scripts/vendor_wasip3_official.sh`). The 7 not vendored
are all `http-client-*` variants: `headers`, `method`, `path`, `path-none`,
`send-errors`, `sent`, `status`.

| Runtime | denominator | result |
|---|---|---|
| zwasm 2.5.0 | its vendored 45 | 45 / 45 |
| wasmtime 47.0.3 | full upstream 52 | 48 / 52; fails `http-service-uri`, `http-client-path-none`, `filesystem-read-directory`, `http-client-sent` |
| both, on the common 45 | | **zwasm 45 / 45, wasmtime 43 / 45** |

wasmtime's two failures inside the common 45 are `http-service-uri` and
`filesystem-read-directory`. zwasm passes both.

> **Differentiation sentence, as measured:**
> *On the 45 official `wasm32-wasip3` conformance tests both runtimes carry,
> zwasm 2.5.0 passes 45/45 and wasmtime 47.0.3 passes 43/45. Measured on
> x86_64-linux, 2026-08-14.*

Two constraints on using that sentence: the denominator is zwasm's vendored
subset, which is 87% of upstream; and zwasm's 45/45 comes from the
in-process embedder harness, not the CLI (§1.10).

### 1.10 WASI 0.3 is verified through the embedder API, not the CLI

**Read from source**: the 45 official p3 tests are Zig unit tests in
`src/api/component_wasi_p3.zig` that drive the corpus in-process. The
build step `test-wasi-p3` reports 48/48 passing, which is the 45 official
tests plus 3 others matching the same filter.

**Measured** on the CLI path with a `-Dwasi=p3` build:

- A direct `zwasm run` of `cli-stdout-flush.wasm` returns a guest assertion
  failure (`left: Complete(0), right: Complete(1)`).
- Under the official runner, the same test held the harness for its full
  900-second bound (`exit 143`) without reaching a second test and without
  writing a results file.

So the official p3 suite cannot currently be scored through the CLI. "WASI
0.3 full coverage" is a statement about the embedding API surface.

---

## 2. Binary size (x86_64-linux)

### 2.1 What is and is not separable

**Read from source**: there is no CLI-only artifact. `build.zig` roots the
runtime at the `core` module (`src/zwasm.zig`), and that same module is the
`root_module` of `libzwasm.a`. The CLI is a thin `exe_mod`
(`src/cli/main.zig`) that imports `core` and links it statically. A "CLI
layer size" can only be a derived difference.

**Measured**: `libzwasm.a` has 2 members (`libzwasm_zcu.o` and
`compiler_rt.o`); WAMR's `libiwasm.a` has 49. Archive size is therefore a
poor proxy for embedder cost. All cross-engine comparisons below use the
linked image of one minimal C host (`docs/examples/c_host/hello.c`) against
each runtime's static library.

### 2.2 zwasm matrix, ReleaseFast, as-built and after `strip -s`

**Measured**, all 12 `(engine, wasi)` combinations.

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

The `interp`, `jit` and `both` rows differ by 16 to 96 bytes at every tier.
The stripped CLI takes 3 distinct values across the whole matrix, one per
WASI tier. The stripped embedder host takes 1 value across all 12.

`.text` sizes for the same builds:

| build | CLI `.text` | embedder `.text` |
|---|---:|---:|
| interp/none | 2,143,821 | 2,141,722 |
| interp/p1 | 2,143,821 | 2,141,722 |
| interp/p2 | 2,458,365 | 2,141,722 |

**Finding 1: `-Dwasi` changes the CLI but not the embedder image.** Going
from p1 to p2 adds 314,544 bytes of CLI `.text`. Stated as a reduction, p1
is **12.8% smaller** than p2. The README advertises "~-8%", so the
documented figure understates the measured one by about 1.6x. The linked C
host is `.text`-identical at all four tiers.

*Not established*: the mechanism for the embedder image being tier-invariant.
Linker section garbage collection is the likely explanation but no link map
was captured. The measured fact is the invariance.

**Finding 2: most of the shipped artifact is not code.** The default
ReleaseFast CLI is 19,548,864 bytes as built and 3,076,488 after `strip -s`,
so **84% is debug info and symbol table**. `bench/results/size_history.yaml`
records ReleaseFast `base` as 3,563,960 at `698eeff5d`, which is close to
the stripped figure and far from the as-built one. *Not established*: which
host produced that series.

### 2.3 ReleaseSmall

**Measured** with `-Doptimize=ReleaseSmall -Dstrip=true`:

| engine | wasi | CLI | embedder `.text` |
|---|---|---:|---:|
| interp | p1 | 1,516,800 | 1,038,993 |
| jit | p1 | 1,516,800 | 1,038,993 |
| both | p2 | 1,789,720 | 1,038,985 |

ReleaseSmall is 44% smaller than ReleaseFast-plus-`strip` for the same
`(interp, p1)` configuration (1,516,800 against 2,703,896).

*Not established*: whether ReleaseSmall passes the test suite. No test layer
was run at this optimize level, so this report does not recommend it as a
distribution configuration. Running `test-all` at ReleaseSmall is the
missing step.

### 2.4 `-Dengine` does not change the binary

**Measured.** Three CLIs differing only in `-Dengine`, ReleaseFast,
`-Dwasi=p1`, unstripped:

| `-Dengine` | file size | `.text` | `engine.codegen` symbols | backend `emit` symbols |
|---|---:|---:|---:|---:|
| `interp` | 16,911,000 | 2,143,821 | 621 | 1 |
| `jit` | 16,911,096 | 2,143,821 | 621 | 1 |
| `both` | 16,911,048 | 2,143,821 | 621 | 1 |

`.text` is identical and the JIT codegen symbol count is unchanged, so
`-Dengine=interp` does not remove the JIT. The same holds at ReleaseSmall/p1,
where `interp` and `jit` produce identical 1,516,800-byte binaries.

**Read from source**: `build_options.engine_mode` is consumed at 3 sites in
`src/`, all in `src/cli/main.zig`. Two build the `--version` string
(`:100`, `:434`). The third is `_ = build_options.engine_mode;` inside
`test "build options are wired"` (`:490`). No comptime gate reads it. The
runtime engine selector is the separate `--engine` CLI flag.

**This is an unfinished axis, not a regression.** ADR-0073 records the same
shape for `wasm_level` as of 2026-05-19: "only consulted at 2 diagnostic
sites in `cli/main.zig` + `diagnostic/trace.zig`. None of validator / lower
/ emit / runtime / c_api / CLI / WASI applies a build-option feature gate".
The substrate was then built for the `-Dwasm` and `-Dwasi` axes, and
`scripts/check_build_dce.sh` gates exactly those two. `-Dengine` appears in
the same ADR's option list and never received the substrate.

The user-facing problem stands: `docs/development.md` describes `-Dengine`
as "Engine selection compiled in", and it does not select anything.

### 2.5 `-Dstrip=true` cannot build the default step

**Measured**: `zig build -Dstrip=true` fails at both ReleaseFast and
ReleaseSafe, 3 of 3 runs each, with three Zig 0.16.0 compiler aborts
(`error: process terminated with signal SEGV` from `zig build-exe`). The
crashing artifacts are:

```
compile exe zwasm-spec-wasm-2-0-assert  ReleaseFast native failure
compile exe zwasm-spec-wasm-3-0-assert  ReleaseFast native failure
compile exe zwasm-wast-runtime-runner   ReleaseFast native failure
```

**Read from source**: those three are `b.installArtifact`'d, so a plain
`zig build` installs three test runners into `zig-out/bin/` next to `zwasm`.

**Measured**: `zig build static-lib -Dstrip=true -Doptimize=ReleaseFast`
succeeds and produces a 3,412,468-byte `libzwasm.a` against 28,431,740
unstripped. So the failure is confined to the default install step.

Every stripped figure in §2.2 and §2.3 uses external `strip -s`, which is
the available workaround.

### 2.6 Cross-engine comparison

**Measured** on one host with `strip -s` applied uniformly.

| Runtime | configuration | binary | stripped | `.text` |
|---|---|---:|---:|---:|
| WAMR 2.4.3 | classic-interp, MinSizeRel+LTO, no SIMD | 307,208 | 264,216 | 151,573 |
| WAMR 2.4.3 | fast-interp, MinSizeRel+LTO | 364,752 | 319,512 | 200,752 |
| WAMR 2.4.3 | classic-interp, Release, no SIMD | 425,552 | 374,728 | n/a |
| WAMR 2.4.3 | fast-interp, Release | 502,696 | 450,504 | n/a |
| WAMR 2.4.3 | Fast-JIT, Release, no SIMD | 801,072 | 712,152 | n/a |
| zwasm 2.5.0 | interp/p1, ReleaseSmall+strip | 1,516,800 | 1,516,792 | 1,038,993 |
| zwasm 2.5.0 | both/p2, ReleaseSmall+strip | 1,789,720 | 1,789,712 | n/a |
| wasmtime 47.0.3 | `wasmtime-min`, official | 3,191,432 | 2,220,336 | n/a |
| zwasm 2.5.0 | interp/p1, ReleaseFast | 16,911,000 | 2,703,896 | 2,143,821 |
| zwasm 2.5.0 | both/p2, ReleaseFast (default) | 19,548,832 | 3,076,488 | 2,458,365 |
| wasmtime 47.0.3 | full CLI, official | 60,742,448 | 47,958,568 | n/a |

Static archives, which are not comparable to linked images (§2.1):

| Runtime | archive | bytes | members |
|---|---|---:|---:|
| WAMR | `libiwasm.a` (classic) | 1,122,402 | 49 |
| WAMR | `libiwasm.a` (Fast-JIT) | 1,945,350 | n/a |
| zwasm | `libzwasm.a` | 28,431,740 | 2 |
| wasmtime | `libwasmtime.a` | 68,705,400 | n/a |

**Reading of the result.**

- Against wasmtime, zwasm's minimum build is 32% smaller (1,516,792 against
  2,220,336), and it reaches that with a stable Zig toolchain where
  `wasmtime-min` requires nightly Rust and `-Zbuild-std`.
- Against WAMR, zwasm's minimum build is **5.7x larger** (1,516,792 against
  264,216).
- One capability difference is worth recording. **Measured**: upstream WAMR
  rejects `SIMD + CLASSIC_INTERP` and `SIMD + FAST_JIT` at cmake configure
  time, so the 264,216-byte row has no SIMD. zwasm's interpreter passes
  25,075 SIMD assertions. Part of the size difference is capability.
- *Not established*: how much of the 5.7x is capability and how much is
  implementation overhead. Separating those requires a feature-matched
  WAMR build that upstream does not currently allow.

---

## 3. Findings

| # | Finding | Evidence | Suggested disposition |
|---|---|---|---|
| F1 | WASI 0.1 interpreter is 59/72 on the official suite; 13 failures are engine-independent | §1.7, control 72/72 | Wire the official suite into CI; work the 13-item list. Re-word the README rating. |
| F2 | Wasm 3.0 JIT: memory64 aborts (exit 70), gc returns a wrong result on `type-subtyping`, multi-memory executes 0 of 407. CI does not run the lane. | §1.4 | Gate the lane. Qualify the Wasm 3.0 claim by engine. |
| F3 | 4 further WASI 0.1 tests fail on the JIT and pass on the interpreter | §1.7 | Second JIT correctness gap; pairs with F2. |
| F4 | `-Dengine` is wired to nothing but the `--version` string. Unfinished ADR-0073 axis, not a regression. | §2.4 | Extend the DCE substrate to the engine axis and gate it, or remove the option and fix `docs/development.md`. |
| F5 | `-Dstrip=true` cannot build the default step (Zig 0.16.0 aborts on 3 installed test-runner exes) | §2.5 | Stop `installArtifact`-ing test runners into the product install step. Report the compiler abort upstream. |
| F6 | ReleaseFast, the shipped configuration, has no spec coverage | §1.5 | Add a ReleaseFast or ReleaseSafe spec leg. |
| F7 | zwasm is 5.7x larger than WAMR and 32% smaller than `wasmtime-min` | §2.6 | Product positioning decision. Name the comparison class when claiming "lightweight". |
| F8 | WASI 0.3 45/45 is 45 of 52 upstream, and is embedder-API-only; the CLI cannot be scored | §1.9, §1.10 | Disclose the denominator. Decide whether the CLI is a supported p3 surface. |
| F9 | 84% of the default ReleaseFast artifact is debug info and symbols; ReleaseSmall is 44% smaller again but untested | §2.2, §2.3 | Run `test-all` at ReleaseSmall, then decide the distribution configuration. |
| F10 | Skip reporting mixes out-of-scope text-format directives with real gaps | §1.2 | Split the column. |
| F11 | The Wasm 3.0 runner's counters do not reconcile | §3.1 | Fix the accounting before quoting "0 fail" as coverage. |
| F12 | `-Dwasi` does not change the embedder image | §2.2 | Documentation fix. |
| F13 | No official WASI 0.2 suite exists; the README's Wasm 2.0 `skip-impl == 0` is contradicted by 1 skip-impl in SIMD | §1.8, §1.1 | Describe the p2 substitute as a substitute. Correct or re-scope the skip-impl claim. |

### 3.1 An open question that limits F2 and §1.1

**Measured.** In the Wasm 3.0 runner, the enumerated `assert_return`
directive count exceeds `pass + fail`:

| Proposal | `return=` enumerated | `pass` | unaccounted | printed `skip` |
|---|---:|---:|---:|---:|
| gc | 419 | 365 | 54 | 15 |
| memory64 | 10,315 | 10,299 | 16 | 4 |
| tail-call | 75 | 73 | 2 | 0 |
| function-references | 39 | 38 | 1 | 2 |
| exception-handling | 34 | 34 | 0 | 1 |
| multi-memory | 407 | 407 | 0 | 14 |
| **total** | 11,289 | 11,216 | **73** | 36 |

*Not established*: whether those 73 directives ran. Two explanations fit the
data equally well. Either the runner executes them and fails to count them,
which is a reporting defect, or it does not execute them, which would mean
the interpreter's coverage is 73 directives smaller than reported. This
report cannot distinguish the two, and that is the reason it matters:
**"0 fail" does not by itself establish that every enumerated directive
ran.**

### 3.2 Which findings need 3-host confirmation

The project's operating rule is that one host is insufficient for
platform-branch claims (`.dev/handover.md`), and the JIT has separate
aarch64 and x86_64 backends.

| Confidence | Findings | Reason |
|---|---|---|
| Host-independent, read from source | F4, F8, F10, F12, F13 | Established from `build.zig`, `src/`, corpora and manifests without execution. |
| Very likely universal | F1, F7, F9 | WASI gaps are host-logic-level. Sizes differ per architecture but the ordering against WAMR and wasmtime will not invert. |
| **x86_64-linux only, confirm before acting** | **F2, F3, F5, F6** | F2 and F3 are defects in JIT-emitted code and may be x86_64-backend-specific; the primary dev host is aarch64-macos. F5 is a Zig compiler abort and may be toolchain-bound. |

Re-running `scripts/eval/conformance_sweep.sh` on the Mac and Windows hosts
closes the last row.

### 3.3 What held up

The interpreter has zero failures across every core corpus measured: 1.0,
2.0, SIMD and relaxed-SIMD, atomics, and all six Wasm 3.0 proposals that
have a sub-corpus, over 66,000 directives. Component Model is 170/0/0. WASI
0.3 is 45/45 and beats wasmtime on the 45 tests both runtimes carry. None of
those results needed qualification.

## 4. Reproduction

```bash
bash scripts/eval/conformance_sweep.sh                      # §1.1 to §1.6
WASI_TESTSUITE=<clone> bash scripts/eval/wasi_official.sh   # §1.7, §1.9, §1.10
bash scripts/eval/size_matrix.sh                            # §2.2 to §2.6
```

`scripts/eval/wasi_adapter_zwasm.py` is the wasi-testsuite runtime adapter;
`wasi_official.sh` copies it into the clone and runs the wasmtime control
alongside. Set `ZWASM_ENGINE=interp` or `jit` to pin the engine, which
§1.7 shows changes the result by 4 tests.

WASI 0.3's 45/45 comes from
`zig build test-wasi-p3 -Dtest-filter=wasip3-official` in-process, not from
the CLI. See §1.10.
