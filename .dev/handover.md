# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Just closed — D-330 c_sha256 `\n` FIXED (`960a27b4`); bundle d330-crosscall-merge-temp CLOSED

The 5×-parked c_sha256 dropped-`\n` (106 vs 107) is **FIXED**. ROOT (Round-4 instrumented probe; the
Round-3 cross-call/X22 framing was OVERTURNED): a `br`/`br_if` carrying a `block`-result merge vreg did
NOT extend that vreg's liveness to the block `.end` (the `if`-frame path was wired D-093 d-11/d-12; plain
block+br never was). The merge vreg died at the fall-through `drop` → regalloc freed its slot → the inlined
strlen SWAR loop reused it → `.end` read garbage → strlen off-by-one → fputs wrote len-1 → `\n` dropped.
FIX = liveness-only (arch-indep): capture br/br_if-carried result vregs into the target block/try_table
frame's merge_vregs + fire the `.end` re-injection for block frames; `Frame.is_loop` excludes loop targets.
**Verified**: deterministic liveness unit test RED(4)→GREEN(7); c_sha256 JIT byte-exact w/ interp (107B);
**realworld diff-jit corpus 0 mismatched** (was 1 — dogfooding milestone); zig build test 2767/0, test-spec
9/9, lint clean. **x86_64 confirm = ubuntu remote gate (kicked this turn; arch-indep fix, verify Step 0.7).**
Lesson `2026-06-15-block-result-merge-vreg-liveness`; **D-333** = same-class br_table multi-target follow-up.

## Long-tail (detail in commits/debt)

**D-293 array_oob** COMPLETE (`855ca5ca`+`dafab5ce`, 25437/0 3-host). Scaffolding audit (this resume): **0
block, healthy**. Remaining JIT-debt: **go corruption** D-331(A) (non-deterministic, infra-blocked),
**D-289/D-331(B)** go_regex emit-side `vreg>=slots.len` (parked), **D-294-R2** (conformance-neutral CLI msg).

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
