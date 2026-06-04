# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 = Completion finalization (完成形) IN-PROGRESS — NOT a release march (ADR-0156).** Phases 0–15
  DONE. **The loop never tags/publishes/cuts over; release is manual user-only; no release gate exists.**
  Goal = clean design + lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces
  (C/Zig/CLI), to あるべき論 + industry standards, **breaking v1 allowed, v1 full-parity NOT a goal**.
- **🔨 §16.5 dogfooding IN-PROGRESS — full facade now proven externally consumable (c1-c3).** Stood up a real
  external `build.zig.zon` path-dep consumer (`examples/zig_dep/`). **c1 (`3bfa460a`)** found + fixed a genuine
  bug: `build.zig` created `core` via `b.createModule` (private) with **no `b.addModule` anywhere**, so
  `dep.module("zwasm")` panicked — `zig_host` only worked by sharing the in-repo private module, so ADR-0109's
  external-consumability claim was never actually exercised. Now `b.addModule("zwasm", …)` (public). **c2
  (`713fe524`)** proved the host-import path (Linker/Caller/`defineFunc` — survey wrongly read it as J.5-pending;
  it shipped at `b10922d2`). **c3 (`804a7133`)** proved the Memory facade. Consumer runs clean
  (add=42 / host go=11 / mem=1234); `scripts/check_zig_consumer.sh` guards it (manual — pulls repo+zlinter,
  **D-274**: consuming zwasm transitively fetches the zlinter lint tool — make lazy).
- **✅ §16.4 CLI surface review DONE (ADR-0159).** Surface locked at **`run` + `compile`** + `--version`/`--help`/
  `help` + unknown-subcommand error (testable `cli/dispatch.zig`); 5 dead stubs removed; §10.1/§10.2/§10.3
  reconciled to code-as-truth (`--engine` per ADR-0136). Flag-parity gap debt-tracked **D-273**.
- **✅ §16.2 C-API** (`e9367bb2`): `include/wasm.h` byte-identical to upstream; implemented all 129 missing extern
  fns → **gap 0 (293/293)** (`scripts/capi_surface_gap.sh`). Residual semantic limits honest+debt-noted: val
  `of.ref`=raw (D-269), standalone `_copy`→null (D-253-D), serialize=source-bytes (D-271). **✅ §16.1** migration
  guide (`58a483e8`). **✅ §16.3** Zig-API facade confirmed minimal/clean (no code change); D-267 reconciled
  (ADR-0025→ADR-0109); Zig Global/Table accessors = optional gap D-272.

## NEXT (autonomous — §16.5 dogfood continues → memory-safety → docs; ADR-0156)

- **§16.5 chunk 4 — D-272 Zig Global/Table accessors — NEXT.** The facade is externally proven, but dogfooding
  confirms a real GAP: the Zig facade exposes `Instance.memory()` + `typedFunc`/`invoke` but NO exported-Global /
  exported-Table accessors (the C-API HAS `wasm_global_*`/`wasm_table_*`). A consumer wanting to read/write a
  guest's exported global or table must drop to the C ABI. For a 完成形 full-featured Zig surface, add
  `Instance.global(name)` / `Instance.table(name)` (read/get/set; grow for table) wrapping the existing C-API
  accessors. **Step 0**: survey the C-API global/table accessor surface (`src/api/{instance,extern_new}.zig`) +
  the facade shape (`src/zwasm/instance.zig`); decide the idiomatic Zig shape (likely small ADR — facade API
  addition). TDD a facade test + exercise it from `examples/zig_dep/`. Then **D-269** of.ref if it surfaces.
  (cw-v1 dogfooding stays deferred — D-264.)
- Minor: `examples/` is not fmt-gated by `gate_commit.sh` (only `src/`); fmt slips. Low-priority tooling tweak.
- After §16.5: **§16.6** memory-safety (D-258 wire JIT-trampoline GC collect → D-261 GC-on-JIT adversarial test;
  highest stakes) → **§16.7** docs LAST (README/reference/tutorial/CHANGELOG, match the settled surface).

## Step 0.7 (next resume)

**No ubuntu kick needed this cycle.** Repo testable code is unchanged since `28dacfde` (ubuntu-verified green
last cycle: §16.5 c1 build-wiring + module export). c2/c3 (`713fe524`/`804a7133`) touch ONLY
`examples/zig_dep/src/main.zig` — a separate package NOT built by the repo's `zig build test`/`test-all`, so a
kick would re-run identical repo bytes. (External-consumer verification on Linux is unautomated — the facade is
platform-agnostic Zig; a future enhancement could run `check_zig_consumer.sh` on ubuntu.) **D-262 rule** holds
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
