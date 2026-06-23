# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 plateau; v2.0.0-alpha.3 TAGGED @fc7ff0b3b; plateau GENUINELY CLEAN

**Mode: overnight autonomous niche-debt discharge** (user 2026-06-23: "逐次修正、取り組めるところを；枯渇しても判断して進める").
`.auto`→JIT flip DONE + 3-host green; tag `v2.0.0-alpha.3` @fc7ff0b3b (tag-only, Latest stays v1.11.0); cljw pins it.
No active campaign/bundle.

**This session closed ALL named niche JIT gaps** (latest @aa00e0efd):
- **D-498 @ab996afc0** — JIT C-API funcref param+result marshalling (`invokeRefIdx` 1/2-param ref-result arms). Deleted.
- **D-497 @11d70d69f, 3-host GREEN** — JIT funcref-table grow (ADR-0201): setup pre-allocs funcptr/typeidx mirrors to
  growCapacity; jitTableGrowGuest (resolve *FuncEntity) vs jitTableGrowHost (fail-safe clear); arm64 X25 reload after
  table-0 grow; `wasm_table_grow` C-API JIT arm. Deleted.
- **D-499 @cd0a75e96 RATIFIED interp-only** (note) — targeted fix intractable (always-R15 regresses Win64 buffer-write;
  trap stub structurally needs R15); runaway-safety intact both arches; 3 facade tests `.interp`-pinned.
- **D-500 RESOLVED** (note) — component CM-API `.interp` is RATIFIED ARCHITECTURE (ADR-0172: cross-instance aliasing is
  Zone-2, component-on-JIT precluded), NOT a workaround; residual general Win64 `wrapper_thunk` ≥2-arg/3-result gap → D-477 sliver(4).
- **D-477 sliver(3) @083affd47 RESOLVED+tested** — mixed (i32,f64)→f64 JIT export works via the 2-arg buffer-thunk
  fall-through (regression guard added). **SIMD-spill dedup @df3fa42d7** (xmmDefSpilledV128→delegates).

**NEXT**: no `now`-class debt (0); high/medium-value named work is exhausted. Remaining = build-on-demand / parked
(below). Per ROADMAP §16: correctness-sweep / surface refinement / debt repayment as real signals surface (a consumer
need, a new spec item, a discovered bug). Do NOT speculatively grind no-consumer niche slivers (debt's own guidance).
**IN-FLIGHT (Step 0.7 check `/tmp/fuzz.log`)**: §14.3 nightly fuzz campaign kicked @4e0da7aa2 (gen 2000-module campaign
corpus via `nix develop .#gen` + `zig build fuzz-campaign` loader, reject-not-crash sweep). A crash/abort in the log =
REAL robustness bug → debt row + fix (the genuine next work). Clean = robustness reconfirmed, no action.

## Operational invariants (keep using)

- **Win64 fast-repro** (~2min): cross-build `zig build test -Dtarget=x86_64-windows-gnu` on Mac (run-step "fails" but
  test.exe builds) → `scp` to windowsmini → ssh-run from the repo dir (cwd matters for file-fixture tests).
- **Mac `zig build test` is INSUFFICIENT for flip/ABI-class changes** — ubuntu-gate mandatory; arm64 masks x86_64 bugs.
  Rosetta `-Dtarget=x86_64-macos` REPRODUCES x86_64-linux JIT bugs. JIT-codegen fix → verify arm64 AND x86_64-macos.
- **Step-0.7 NOTE**: `failed command: …--listen=-` / host-example exe lines are COSMETIC (exit 0); trust
  `[run_remote_*] OK/FAIL` + `N passed, 0 failed`.

## Parked / gated — do NOT speculatively grind (see debt.yaml)

- **D-477 slivers** (partial, build-on-demand, no consumer): (1) v128 args/results invoke (Win64-by-ref gotcha);
  (2) Win64 ≥4-param stack-spill; (4) Win64 ≥2-arg/3-result MEMORY-class thunk (folded from D-500; needs windowsmini
  blind-iteration). Recipe in debt D-477 + investigation agent a9ef96a8. Build when a real consumer needs the shape.
- **validator.zig at 3449/3450 cap** — NEXT validator edit MUST extract per the file's marker plan first.
- D-305 long-tail (niche CM shapes; `component_graph.zig` 1895/2000 split first); D-464 async adversarial; D-475
  table64-JIT (perf, Win64-risk); D-462 feature-separation (user-gated). 22 `blocked-by` = future-bucket/parked.

## State (release = USER-ONLY, ADR-0156 — the loop NEVER tags/publishes)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM** default-ON; **0.3 core** done. Sandbox triad.
- **Surfaces**: C-API · Zig-API (full WASI parity) · lean CLI · memory-safety sound · dogfooded into cw. Runners ReleaseSafe.
- **EH**: cross-instance JIT EH both arches. Interp+JIT EH corpus green. Realworld 56 fixtures interp 56/0; JIT diff-gated.
- **Debt**: 67 entries — **ZERO `now`-class** (22 blocked-by, 42 note, 3 partial). 完成形 plateau (all dims confirmed,
  surface audits clean 2026-06-18, interp+JIT fuzz 0-crash, v1-JIT parity D-265 closed).

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3`. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0201** (funcref-table grow) · **0172** (components=interp) ·
  **0099** (file-size caps) · **0126** (iso-recursive equality). lessons INDEX: `.dev/lessons/INDEX.md` (Step 0.4 keyword index).
