# ReleaseSafe-floor audit: a per-runner check, not a surface claim

**Date**: 2026-06-14 · **Context**: ADR-0177 (test runners ReleaseSafe) gap audit, prompted by
ClojureWasmFromScratch's own ReleaseSafe campaign (Debug in gate paths = ~100× slower).

## Observation

ADR-0177 floored the *test runners* at ReleaseSafe so a plain `zig build test-all` (Debug
default) still runs the heavy e2e corpus runners fast. The mechanism: a `zwasm_lib_mod = core_rs`
alias (a ReleaseSafe twin of `core`) that "every integration runner imports." The SURFACE looked
unified — but `core_comp` (the Component Model spec runner's separate zwasm module, 158-manifest
corpus in `test-all`) was a DISTINCT module still on `.optimize = optimize` (= Debug). One
integration runner ran its whole corpus in Debug, invisibly. (cljw hit the identical class: bare
`zig build` in gate scripts, `--resume` skipping the ReleaseSafe rebuild, 310 e2e fallbacks
without `-Doptimize` — ADR-0132/0133 there.)

## Rule

"All runners are ReleaseSafe" is a **per-runner property**, not a surface claim. Audit it by
mapping EVERY `addImport("zwasm", X)` in build.zig to X's optimize mode — don't trust that a
shared alias covers all of them. A runner gets a SEPARATE core module (component model, a future
backend variant, a sanitizer build) the moment it needs different build_options — and that twin
silently defaults to `optimize` (Debug) unless explicitly floored.

## Audit recipe (re-runnable)

```sh
# 1. Map every runner → its zwasm module:
grep -nE 'addImport\("zwasm",' build.zig
# 2. ReleaseSafe-floored ⟺ X ∈ {core_rs, core_releasesafe, zwasm_lib_mod(=core_rs)}.
#    Debug ⟺ X ∈ {core, core_comp, …any module on `.optimize = optimize`}.
# 3. For each Debug consumer, confirm it is Debug-BY-DESIGN (allowlist), else it is a gap:
#    OK-Debug: core_tests (leak-detecting DebugAllocator), exe (production CLI honours
#    -Doptimize), light unit-test mods, trivial single-wasm examples (zig_host/c_host).
#    GAP: any HEAVY corpus/realworld/differential RUN-ARTIFACT in `test-all` on Debug.
# 4. Fix a gap: set that module's `.optimize = runner_optimize` (the ADR-0177 floor:
#    `if optimize == .Debug then .ReleaseSafe else optimize`).
```

`runner_optimize` floors at ReleaseSafe but still honours a higher `-Doptimize` (ReleaseFast).
Found gap this pass: `core_comp` → fixed to `runner_optimize` (build.zig ~line 439).

## Tells

- A new `core_*` module created with `.optimize = optimize` (copy-pasted from `core`, not `core_rs`).
- `test-all` wall-clock dominated by one corpus dir that "should be fast."
- A runner whose zwasm import is NOT the `zwasm_lib_mod`/`core_rs` alias.

Anti-regression: `scripts/check_releasesafe_runners.sh` (gate-wired) asserts no runner imports a
Debug `core*` module outside the justified allowlist. Related: cljw embeds the mode in the binary
(`@tagName(@import("builtin").mode)`) + asserts via `--version` (ADR-0132 there).
