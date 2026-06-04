# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 = Completion finalization (完成形) IN-PROGRESS — NOT a release march (ADR-0156).** Phases 0–15
  DONE. **The loop never tags/publishes/cuts over; release is manual user-only; no release gate exists.**
  Goal = clean design + lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces
  (C/Zig/CLI), to あるべき論 + industry standards, **breaking v1 allowed, v1 full-parity NOT a goal**.
- **🔨 §16.5 dogfooding IN-PROGRESS — facade proven externally (c1-c3) + Global accessor added (c4).** External
  `build.zig.zon` path-dep consumer (`examples/zig_dep/`). **c1 (`3bfa460a`)** found+fixed a real bug: `build.zig`
  made `core` via `b.createModule` (private) with **no `b.addModule`**, so `dep.module("zwasm")` panicked —
  `zig_host` only shared the in-repo private module, so ADR-0109's external-consumability was never exercised. Now
  `b.addModule("zwasm", …)`. **c2 (`713fe524`)** proved host imports (Linker/Caller/`defineFunc`; shipped at
  `b10922d2`, survey wrongly read pending). **c3 (`804a7133`)** Memory. **c4 (`27b3274a`)** closed the GLOBAL half
  of **D-272**: `Instance.global(name) → Global{get/set, !Immutable}` (Wasm §4.5.5/6) + extracted shared
  `value_conv.zig`; T1.14 + consumer (counter 7→42). Consumer runs clean: add=42/go=11/mem=1234/counter=42.
  `scripts/check_zig_consumer.sh` guards it (manual; **D-274** consuming pulls the zlinter lint tool — make lazy).
- **✅ §16.4 CLI surface review DONE (ADR-0159).** Surface locked at **`run` + `compile`** + `--version`/`--help`/
  `help` + unknown-subcommand error (testable `cli/dispatch.zig`); 5 dead stubs removed; §10.1/§10.2/§10.3
  reconciled to code-as-truth (`--engine` per ADR-0136). Flag-parity gap debt-tracked **D-273**.
- **✅ §16.2 C-API** (`e9367bb2`): `include/wasm.h` byte-identical to upstream; implemented all 129 missing extern
  fns → **gap 0 (293/293)** (`scripts/capi_surface_gap.sh`). Residual semantic limits honest+debt-noted: val
  `of.ref`=raw (D-269), standalone `_copy`→null (D-253-D), serialize=source-bytes (D-271). **✅ §16.1** migration
  guide (`58a483e8`). **✅ §16.3** Zig-API facade confirmed minimal/clean (no code change); D-267 reconciled
  (ADR-0025→ADR-0109); Zig Global/Table accessors = optional gap D-272.

## NEXT (autonomous — §16.5 dogfood continues → memory-safety → docs; ADR-0156)

- **§16.5 chunk 5 — D-272 Table accessor (Global half done c4) — NEXT.** Add `Instance.table(name) → Table`
  mirroring the Global facade: `size()`, `get(idx) !Value`, `set(idx, Value) !void`, `grow(delta, init) !void`.
  Design (per c4 survey): hold `rt` + `table_idx` + `elem_type`; `get`/`set` marshal via `value_conv` against
  `elem_type` (funcref slots → opaque `?u64` in `.funcref` Value — D-269 limit, not callable yet, OK for now);
  **reuse the runtime table-grow path, NOT a hand-rolled realloc** (mirror C-API `wasm_table_grow`,
  `src/api/instance.zig:1269-1338`). `rt.tables` is `[]TableInstance` (value array) — take `&rt.tables[idx]` to
  mutate. TDD a T1.15 test (a `(table (export "t") 2 funcref)` or externref fixture: size/get/set/grow) + exercise
  from `examples/zig_dep/`. Closes D-272. Then **D-269** of.ref if it surfaces. (cw-v1 deferred — D-264.)
- Minor: `examples/` is not fmt-gated by `gate_commit.sh` (only `src/`); fmt slips (caught manually). Low-pri tweak.
- After §16.5: **§16.6** memory-safety (D-258 wire JIT-trampoline GC collect → D-261 GC-on-JIT adversarial test;
  highest stakes) → **§16.7** docs LAST (README/reference/tutorial/CHANGELOG, match the settled surface).

## Step 0.7 (next resume)

**Verify ubuntu** — this turn pushed c4 (`27b3274a`), which touches `src/zwasm/instance.zig` (the invoke path —
`value_conv` extraction) + adds `global.zig`/`value_conv.zig`. Kicked `run_remote_ubuntu test`; tail
`/tmp/ubuntu.log` for `OK (HEAD=…)`. Portable Zig (no per-arch emit) so `test` scope suffices. (External-consumer
Linux verification stays unautomated — facade is platform-agnostic Zig; future: run `check_zig_consumer.sh` on
ubuntu.) **D-262 rule** holds
for any future per-arch-emit chunk. **Gate**: Step-5 Mac = `bash scripts/mac_gate.sh`. windowsmini = phase boundary.

## Deferred / open debt

- **Memory-safety (highest stakes; §16.6)** — **D-261** GC-on-JIT conservative rooting has NO adversarial test
  → latent UAF, **blocked on D-258** (JIT-trampoline GC collect trigger). Close D-258 → D-261 before 完成形.
- **Surface residuals** — **D-274** consuming zwasm transitively fetches zlinter (make lazy; §16.5). **D-273**
  CLI flag gap vs wasmtime (`--invoke` args/result-print, `--env`/`--fuel`/`--timeout`) — §16.5. **D-272** Zig
  Global/Table accessors (§16.5). **D-269** val `of.ref`=raw. **D-253** ref machinery (incl. D-253-D
  standalone-copy). **D-271** serialize=source-bytes (no AOT cache). **D-255** C-API WASI io. **D-251** WASI in AOT.
- **D-210** cohort root fix (D-142/206/210/245). **D-211** GcRootMap. **D-257** 10 lesson `Citing` backfill.
  **D-254** rust 3-OS. **D-249** win bench. **D-238** x86_64 EH thunk. **D-266/D-259** notes.

## Key refs

- ROADMAP §16 (16.1–16.4 ✅ → 16.5 dogfooding → 16.6 memory-safety → 16.7 docs; NO release gate). §1.2 (完成形
  industry-standard surfaces). ADR-0156 (endgame); **ADR-0159 (§16.4 CLI = run+compile)**; ADR-0157/0158 (C-API
  split + ref model); ADR-0109 (Zig facade); ADR-0136 (`run --engine`). `scripts/capi_surface_gap.sh` (gap=0).
