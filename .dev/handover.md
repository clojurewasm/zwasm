# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase-17 完成形 steady-state; branch GREEN, Mac+ubuntu-verified (`dc463af5`)

**Diag-quality audit batch — cheap wins DONE**: F1 CLI `--max-table-elements` (`240f97de`), F3 full
`ZWASM_TRAP_*` C #defines (`240f97de`), F5b validate-diag `(func #N @ 0xXX)` (`240f97de`), F6 parser
`.parse`-phase diagnostics w/ byte offset (`098d2036`, top-level 8 sites), **F5a validator type-mismatch
diagnostics — central `popExpect` site DONE (`dc463af5`)**: "type mismatch: expected i32, found f64 at op
0x{x}" via a `Validator.mismatch` scratch slot read by the dispatch cold path + new `ValType.name()`
(zir.zig, Wasm 3.0 text keywords). dc463af5 = Mac `test` 2770/0 + lint clean (ubuntu/windows TBV at next
Step 0.7). Audit: `private/notes/d-diag-audit-2026-06-15.md`.

**NEXT**: diag cheap wins now exhausted (F5a central + F6 top-level shipped). Remaining diag tails are
LOW-value, per-site, deferred in D-334: F5a remainder (non-popExpect StackTypeMismatch sites — isRef/label/GC,
each a different "expected" shape), F6 remainder (~80 per-section parse decoders), F4 (CLI trap @tagName
underscore leak — user-visible format change, left for a deliberate call). Highest-value next = **a fresh
完成形 surface audit** of a not-yet-covered dimension (memory-safety/dogfooding were CLEAN per D-297/295/296)
to surface new cheap wins — OR pick a D-334 tail only if a real diagnostic-quality need surfaces. TDD + gate
on `zig build test`; codegen/regalloc changes ALSO need `test-spec-wasm-2.0-assert` + Rosetta per lesson
`spill-stage-reg-clobber-and-spec-gate-gap`. **Do NOT re-attempt parked items** (D-330 conflicting-constraint
hard-park; D-331 go infra-blocked) — they thrash. Verify any prior remote kick at Step 0.7.

c_sha256 `\n`-drop (D-330) deep-investigated this session (5 trace rounds + 3 fix attempts) → **bundle
d330-blockmerge-liveness CLOSED, demoted to a hard-parked debt note**. Root IS understood (a br/br_if
block-result merge vreg not extended to the block `.end`), BUT the fix has **CONFLICTING constraints**:
c_sha256 needs the extension; `labels $switch` (multi-br/br_table) is correct WITHOUT it and breaks WITH it
(even when liveness perfectly mirrors emit — verified). So a blanket fix is wrong; the real fix is a
narrower/deeper emit-or-regalloc change — a multi-cycle research problem, disproportionate for a cosmetic
symptom (one `\n`; values + interp correct; 55/56 byte-exact). Full findings + design + conflicting-constraint
note preserved in **D-330 debt** (Round 5) + `private/notes/{c_sha256_trace_2026-06-15.md, d330-emit-align-design.md}`
for a FUTURE fresh-context attempt. **Do NOT immediately re-attempt the blanket fix — it thrashes.**

**Branch verified GREEN**: `test` 2766/0, `test-spec-wasm-2.0-assert` 25437/0 (Mac arm64), ubuntu x86_64
`OK (HEAD=f80df3e4)`. windows batched/deferred. Reverts `a71906fa`+`547d5ce1` (naive fix `960a27b4` undone).

**Other long-tail (parked/blocked)**: go corruption D-331(A) (infra-blocked), D-289/D-331(B) go_regex
emit-side (parked), D-294-R2 (conformance-neutral CLI), D-333 (br_table merge — folds into D-330's future fix).
**D-293 array_oob** COMPLETE. Scaffolding audit (this session): **0 block, healthy**.

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
  D-330 = hard-parked debt note (bundle closed; conflicting-constraint fix, see Round 5); D-331 (go) parked.
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
