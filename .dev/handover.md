# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle — c_sha256 `\n` = block-result merge-vreg liveness not extended to block end (D-330)

- **Bundle-ID**: d330-blockmerge-liveness
- **Cycles-remaining**: ~2-3 (proper emit-aligned fix + 2.0-assert gate)
- **Continuity-memo**: ROOT (Round-4, instrumented regalloc probe — HARD DATA; trace
  `private/notes/c_sha256_trace_2026-06-15.md` Round 4): c_sha256 JIT drops the final `\n` (106 vs 107).
  A `br`/`br_if` carrying a `block`-result merge
  vreg is NOT extended to the block `.end` in liveness.zig (the `if`-frame path is wired D-093 d-11/d-12;
  plain block+br never was). In c_sha256's inlined strlen the merge vreg(477) died at the fall-through `drop`
  → regalloc freed its slot → the strlen SWAR loop's vreg(485) reused it → `.end` read garbage → strlen
  off-by-one → fputs wrote len-1. (Rounds 1-3 — wpos / flush-branch / cross-call-X22 — ALL DISPROVEN.)
- **ATTEMPTED FIX — REVERTED `a71906fa`+`547d5ce1`** (orig `960a27b4`+`c9dad2d4`): liveness-only — capture
  br/br_if-carried result vregs into the target block/try_table `merge_vregs` + fire `.end` re-injection for
  block frames + `Frame.is_loop`. PASSED arm64 `test` 2767/0 + `test-spec` 9/9 + c_sha256 byte-exact +
  diff-jit corpus 0-mismatch — **but FAILED `test-spec-wasm-2.0-assert`: `labels` switch ×3 (got 25 exp 50)**,
  both arches. The naive capture is INCONSISTENT with the emit's `captureOrEmitBlockMergeMov` for multi-br /
  `br_table` / nested block-result merges (`br $exit (v)` / `br $ret (v)`); it only matched c_sha256's narrow
  single-br-with-drop shape.
- **NEXT (proper fix)**: mirror `op_control_merge_mov.captureOrEmitBlockMergeMov` EXACTLY — same capture
  conditions (frame kinds .block/.if_then/.else_open; first-br capture vs subsequent-br MOV) + handle
  `br_table` (payload=label COUNT → decode `branch_targets`, per target) + `.end` re-injection must match the
  emit's post-block canonical vreg. **GATE (mandatory, the gap that bit this): `zig build test-spec-wasm-2.0-assert`
  (≠ `test-spec`!) + Rosetta x86_64 BEFORE push** (lesson `spill-stage-reg-clobber-and-spec-gate-gap`).
  Correctness-first: the white-box liveness unit test (last_use 4→7) is necessary but NOT sufficient — add a
  `labels`-shaped multi-br/br_table characterization test that is RED on the naive fix.
- **Exit-condition**: c_sha256 JIT = 107B byte-exact + `test-spec-wasm-2.0-assert` 25437/0 (Mac arm64 +
  Rosetta x86_64) + diff-jit corpus 0-mismatch + full `zig build test`.

## State note (post-revert)

c_sha256 `\n` drop is BACK (fix reverted; branch GREEN again: test 2766/0, test-spec-wasm-2.0-assert 25437/0).
**D-293 array_oob** COMPLETE (`855ca5ca`+`dafab5ce`). Scaffolding audit (this session): **0 block, healthy**.
Long-tail: **go corruption** D-331(A) (infra-blocked), **D-289/D-331(B)** go_regex emit-side (parked),
**D-294-R2** (conformance-neutral CLI). br_table block-result merge-vreg gap folds into this bundle's fix.

## ACTIVE AGENDA (user-directed 2026-06-14) — real-world toolchain/bench reproduction

Project feature-complete + tag-ready (**tag = USER-ONLY, ADR-0156**). Plan:
[`realworld_reproduction_plan.md`](realworld_reproduction_plan.md) (supersedes ROADMAP §9 for these tasks).
Phase A reproduction infra DONE (A1 Zig `5c044967` / A2 embenchen `1aac480f` / A3 `--wasmer` `897b54d7` /
runtime bump wasmtime45+wasmer7.1; A4 rust=D-254, hyperfine=D-249). Phase B deep JIT bug-hunt SUSTAINED:
B1 `--jit` diff-lane `219dbd17` (REPORT-ONLY, 56/56). Tool currency 3-host DONE+VERIFIED (zig PINNED 0.16.0).

**JIT-correctness debt (each its own investigation)**: D-330 c_sha256 = the Active bundle above (was the
last diff-jit mismatch; corpus otherwise byte-exact). D-331(A) go_* runtime-corruption (panicmem teardown
deref; INFRA-BLOCKED — needs per-function interp-fallback bisect that doesn't exist). D-331(B)/D-289 go_regex
emit-side `vreg>=slots.len` (cap raised `682401fd`; remainder parked, recipe in debt). Earlier durable fixes:
D-330 coalescing `6790c204` + x86_64 fp-select `cccb2313`; sandbox triad `bd355258`+`fa4678f4` (D-314(b)/
D-332 closed); D-294 R1 `2a53213f`. Trace tooling: `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh`
(Recipe 18 + lesson `2026-06-15-lldb-value-trace-on-jit-code`).

## State (tag-ready baseline, all 3-host green)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON (ADR-0182/0183; corpus 158/0/0). Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 (+preopen_dir/inherit_env, ADR-0184) · Zig-API
  complete (+`WasiConfig.{envs,preopens,io}` — full WASI parity) · lean CLI ·
  memory-safety sound · dogfooded into cw (consumer-side). Runners ReleaseSafe (ADR-0177,
  Rev 2026-06-14 floored `core_comp` too; `check_releasesafe_runners.sh` guards it).
- **EH**: cross-instance exception-handling on JIT works on BOTH arches (arm64 `4f73d9ee`
  + x86_64 D-238/ADR-0185 `c534afca`). Interp + JIT EH spec corpus green.
- **Debt**: 46 entries, **zero `now`**; all blocked-by are external (upstream
  Zig / hosts) / future-phase (11/12/14) / user-gated, or `note`/`partial` long-tail.
  D-330 = Active bundle; D-331 (go, primary+(A) FIXED, miscompile-next) parked.
- **Realworld corpus**: 50 fixtures (c/cpp/rust/tinygo/go), interp 50/50; JIT run-stage
  opt-in (`ZWASM_JIT_RUN=1`) — the Phase-B signal source. cljw fixtures retired.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`realworld_reproduction_plan.md`](realworld_reproduction_plan.md) — the ACTIVE
  AGENDA's full plan. [`flake.nix`](../flake.nix) `devShells.gen` — fixture toolchains.
- [`docs/zig_api_design.md`](../docs/zig_api_design.md) · **ADR-0185** (x86_64 EH
  frame-walk) · **0177** (ReleaseSafe runners) · **0156** (NO autonomous release) ·
  **0153** (rework) · **0109** (Linker/facade API).
- lessons [`releasesafe-runner-floor-audit`] · [`global-predicate-cannot-replace-local-codemap`].
