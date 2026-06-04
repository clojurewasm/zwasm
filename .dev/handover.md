# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 = Completion finalization (完成形) IN-PROGRESS — NOT a release march (ADR-0156).** Phases 0–15
  DONE. **The loop never tags/publishes/cuts over; release is manual user-only; no release gate exists.**
  Goal = clean design + lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces
  (C/Zig/CLI), to あるべき論 + industry standards, **breaking v1 allowed, v1 full-parity NOT a goal**.
- **✅ §16.4 CLI surface review DONE (ADR-0159).** Live survey (wasmtime: run/compile/explore/serve/…, no
  validate; wazero: run/compile/version) → locked the surface at **`run` + `compile`** + standard
  `--version`/`-V`, `--help`/`-h`/`help`, and an explicit unknown-subcommand error (exit 2). Top-level routing
  extracted to a pure unit-tested `src/cli/dispatch.zig` (classify + usage). Removed 5 dead aspirational stubs
  (`validate`/`inspect`/`features`/`wat`/`wasm` — never @imported/dispatched). Validation stays programmatic
  (C-API `wasm_module_validate` / Zig `Engine.compile`); wat↔wasm + introspection → wasm-tools/wabt. Reconciled
  ROADMAP §10.1/§10.2/§10.3 to code-as-truth (`--engine <interp|jit>` per ADR-0136, not the stale
  `--interpreter`). Flag-parity gap vs wasmtime (`--invoke` args + result-print, `--env`/`--fuel`/`--timeout`)
  debt-tracked **D-273** for §16.5 evaluation.
- **✅ §16.2 C-API** (`e9367bb2`): `include/wasm.h` byte-identical to upstream; implemented all 129 missing extern
  fns → **gap 0 (293/293)** (`scripts/capi_surface_gap.sh`). Residual semantic limits honest+debt-noted: val
  `of.ref`=raw (D-269), standalone `_copy`→null (D-253-D), serialize=source-bytes (D-271). **✅ §16.1** migration
  guide (`58a483e8`). **✅ §16.3** Zig-API facade confirmed minimal/clean (no code change); D-267 reconciled
  (ADR-0025→ADR-0109); Zig Global/Table accessors = optional gap D-272.

## NEXT (autonomous — surfaces done, dogfood → memory-safety → docs; ADR-0156)

- **§16.5 — Minimal-wrapper dogfooding — NEXT.** Stand up a local `build.zig.zon` path-dep consumer that uses
  zwasm v2 as a Zig library (`@import("zwasm")` → Engine/Module/Instance facade, ADR-0109). Verify it builds +
  runs cleanly; hunt ergonomic gaps + "usable from CLI but unreachable from the API" (and vice-versa) mismatches.
  Likely re-surfaces **D-269** (val of.ref), **D-272** (Zig Global/Table accessors), **D-273** (CLI `--invoke`
  args/result). Reuse the existing test corpus where adaptation makes it serve double duty. (cw-v1 dogfooding
  stays deferred — D-264.) Precedent consumer: `examples/zig_host/` (ADR-0109).
- After §16.5: **§16.6** memory-safety (D-258 wire JIT-trampoline GC collect → D-261 GC-on-JIT adversarial test;
  highest stakes) → **§16.7** docs LAST (README/reference/tutorial/CHANGELOG, match the settled surface).

## Step 0.7 (next resume)

**Verify ubuntu** — this turn pushed §16.4 (`07105f95` stub-removal+ADR, `6f51cf48` --version/--help dispatch,
+ doc/debt commit) and kicked `run_remote_ubuntu test`; tail `/tmp/ubuntu.log` for `OK (HEAD=…)`. §16.4 is
portable Zig (CLI dispatch + dead-file removal + docs; no per-arch emit) so `test` scope suffices. **D-262 rule**
still holds: a chunk touching per-arch emit needs `run_remote_ubuntu test-all` before discharge. **Gate**: Step-5
Mac = `bash scripts/mac_gate.sh`. windowsmini exec = phase boundary.

## Deferred / open debt

- **Memory-safety (highest stakes; §16.6)** — **D-261** GC-on-JIT conservative rooting has NO adversarial test
  → latent UAF, **blocked on D-258** (JIT-trampoline GC collect trigger). Close D-258 → D-261 before 完成形.
- **Surface residuals** — **D-273** CLI flag gap vs wasmtime (`--invoke` args/result-print, `--env`/`--fuel`/
  `--timeout`) — §16.5 evaluation. **D-272** Zig Global/Table accessors (optional). **D-269** val `of.ref`=raw.
  **D-253** ref machinery (incl. D-253-D standalone-copy). **D-271** serialize=source-bytes (no AOT cache).
  **D-255** C-API WASI io. **D-251** WASI in AOT.
- **D-210** cohort root fix (D-142/206/210/245). **D-211** GcRootMap. **D-257** 10 lesson `Citing` backfill.
  **D-254** rust 3-OS. **D-249** win bench. **D-238** x86_64 EH thunk. **D-266/D-259** notes.

## Key refs

- ROADMAP §16 (16.1–16.4 ✅ → 16.5 dogfooding → 16.6 memory-safety → 16.7 docs; NO release gate). §1.2 (完成形
  industry-standard surfaces). ADR-0156 (endgame); **ADR-0159 (§16.4 CLI = run+compile)**; ADR-0157/0158 (C-API
  split + ref model); ADR-0109 (Zig facade); ADR-0136 (`run --engine`). `scripts/capi_surface_gap.sh` (gap=0).
