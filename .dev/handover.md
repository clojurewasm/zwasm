# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 = Completion finalization (完成形) IN-PROGRESS — NOT a release march (ADR-0156).** Phases 0–15
  DONE. **The loop never tags/publishes/cuts over; release is manual user-only; no release gate exists.**
  Goal = clean design + lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces
  (C/Zig/CLI), to あるべき論 + industry standards, **breaking v1 allowed, v1 full-parity NOT a goal**.
- **✅ §16.5 dogfooding DONE — full facade proven externally (c1-c6); D-272 CLOSED.** External
  `build.zig.zon` path-dep consumer (`examples/zig_dep/`). **c1 (`3bfa460a`)** found+fixed a real bug: `build.zig`
  made `core` via `b.createModule` (private) with **no `b.addModule`**, so `dep.module("zwasm")` panicked —
  `zig_host` only shared the in-repo private module, so ADR-0109's external-consumability was never exercised. Now
  `b.addModule("zwasm", …)`. **c2 (`713fe524`)** host imports (Linker/Caller/`defineFunc`; shipped `b10922d2`,
  survey wrongly read pending). **c3 (`804a7133`)** Memory. **c4 (`27b3274a`)** + **c5 (`c992899f`)** closed
  **D-272**: `Instance.global(name)`/`table(name)` facades (get/set/!Immutable; size/get/set/grow) + shared
  `value_conv.zig`. T1.14/T1.15 tests. Consumer runs clean: add=42/go=11/mem=1234/counter=42/table[1]=0xcafe sz=4.
  c6 sweep: multi-result ✓ (T1.6), Engine config honestly-empty, no CLI-only-vs-API gap. Open notes: **D-274**
  (consuming pulls the zlinter lint tool — make lazy), **D-275** (`Module.instantiate` coarse error — minor).
- **✅ §16.4 CLI surface review DONE (ADR-0159).** Surface locked at **`run` + `compile`** + `--version`/`--help`/
  `help` + unknown-subcommand error (testable `cli/dispatch.zig`); 5 dead stubs removed; §10.1/§10.2/§10.3
  reconciled to code-as-truth (`--engine` per ADR-0136). Flag-parity gap debt-tracked **D-273**.
- **✅ §16.2 C-API** (`e9367bb2`): `include/wasm.h` byte-identical to upstream; implemented all 129 missing extern
  fns → **gap 0 (293/293)** (`scripts/capi_surface_gap.sh`). Residual semantic limits honest+debt-noted: val
  `of.ref`=raw (D-269), standalone `_copy`→null (D-253-D), serialize=source-bytes (D-271). **✅ §16.1** migration
  guide (`58a483e8`). **✅ §16.3** Zig-API facade confirmed minimal/clean (no code change); D-267 reconciled
  (ADR-0025→ADR-0109); Zig Global/Table accessors = optional gap D-272.

## NEXT (autonomous — §16.6 memory-safety → docs; ADR-0156)

- **§16.6 memory-safety completion — NEXT (highest stakes).** Close the latent-UAF gap on the GC-on-JIT path
  before calling it 完成形. Two linked debts, **correctness-first ordering** (REWORK.md gate II logic — pin
  behaviour with an adversarial test, don't ship an unverified collector trigger): **D-258** = wire the
  JIT-trampoline GC collection trigger (the GC has reclamation + heap-pressure trigger per Phase 15.1 / ADR-0128
  §2 / ADR-0146, but the JIT-trampoline path doesn't fire a collect); **D-261** = the GC-on-JIT conservative
  native-stack-scan rooting has NO adversarial test → a collect mid-JIT-call could free a live object (UAF). Order:
  D-258 wires the trigger, which UNBLOCKS D-261's adversarial test (force a collect while a JIT frame holds the
  only reference to a heap object across the trampoline; assert it survives + is not freed). **Step 0 (subagent)**:
  survey the GC collect path (`src/runtime/` gc + `src/engine/codegen/shared/` trampoline + ADR-0128/0146/0147/0148
  + D-258/D-261 bodies + `runner_gc_test.zig`) — where the interp triggers collect vs where the JIT trampoline
  should. This is multi-cycle; consider **bundle mode**. Mac-local (GC is not per-arch-emit, but the JIT trampoline
  is — `run_remote_ubuntu test-all` per D-262 before discharge if emit touched).
- After §16.6: **§16.7** docs LAST (README/reference/tutorial/CHANGELOG, match the settled surface).
- Backlog notes (not blockers): **D-269** funcref opaque `?u64` (not callable from a table slot — deeper
  enhancement); **D-273** CLI flag parity; **D-274** zlinter eager fetch; **D-275** `Module.instantiate` coarse
  error; `examples/` not fmt-gated by `gate_commit.sh` (caught manually).

## Step 0.7 (next resume)

**No ubuntu kick this cycle** — c5 (`c992899f`) was verified green last cycle (`OK (HEAD=c992899f)`), and c6 (the
§16.5 close) is **doc-only** (debt D-275 + ROADMAP [x] + handover; no code). Next code-bearing chunk = §16.6.
**D-262 rule**: §16.6 touches the JIT trampoline (per-arch emit) → `run_remote_ubuntu test-all` before discharge
(cross-compile ≠ cross-run). **Gate**: Step-5 Mac = `bash scripts/mac_gate.sh`. windowsmini = phase boundary.

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
