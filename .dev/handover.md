# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit = official Wasm 3.0 testsuite at pass=fail=skip=0 on **both
  backends** (interp + JIT).
- **HEAD** (`3b668110`): **JIT tag index space now includes imported tags** (10.E). The JIT
  compile path built `tags_slice`/`tag_param_counts` from the DEFINED tag section only; the
  wasm tag index space is imports ++ defined (§3.4), so a catch/throw `tag_idx` mis-resolved by
  the imported-tag count → `StackTypeMismatch` at validate (try_table.1 imports 2 tags) + wrong
  throw pop-count. Fixed both compile paths (main + empty-fn), imports-first, mirroring interp
  (instantiate.zig cyc114/cyc116). +1 unit test. **No corpus change yet** (762/2/531) — the EH
  module advances past validate to the NEXT blocker (per-module blocker stack).
- **Prior**: D-235 (`2b48dfdc`/`74d155b7`) JIT call_indirect subtype DONE — type-subtyping correct
  both backends. interp wasm-3.0 corpus FULLY GREEN. Spec corpus = interp default; JIT opt-in
  `ZWASM_SPEC_ENGINE=jit` (default test-all unchanged); JIT entry = `runner.zig` `JitInstance`.
- **EH-on-JIT reality** (lesson `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`): the handler
  landing-pad DISPATCH is fully implemented (`throw_trampoline.zig` trampolineCore + zwasmThrowTrampoline,
  all 3 ABIs). Its docstring (lines 9-35, "3c-ii/handler also traps/deferred") is STALE comment-rot —
  fix when next touching it. The gap is the per-module compile-reject stack, NOT dispatch.
- **Watch**: `runner_gc_test.zig` 1476 / `compile.zig` 1223 / `jit_abi.zig` 1350 (all WARN, under hard 2000).

## Active task — Phase 10 → 100% (ADR-0128)  **NEXT**

Continue the **`10.E-eh-on-jit` bundle** (below): clear try_table.1.wasm's NEXT blocker —
**func[24] `try_table` emit `UnsupportedOp`** (`eh_landing_pads`/`eh_catch_entries` null →
`arm64/ops/wasm_3_0/try_table.zig:53/54/66 orelse UnsupportedOp`; the lowerer `lower.zig:202` sets
them only when `landing_pads.items.len > 0` → a catchless/zero-catch try_table produces none). Smallest
red test: a void fn with a catchless `(try_table)` JIT-compiles. Then re-measure JIT EH dir.

Other non-gated tracks (after EH): **D-234** (51 memory64 assert_trap = harness artifact, codegen proven
correct — runner-side fix), **D-198** (rec-group subtype), **D-209** (stale u32), **D-210** (cross-module
proper-tail-call). Realworld GC/EH/TC producers (§5, flake.nix `#gen`).

**USER-GATED (non-stop — only surface):** **§10-scope question** → `.dev/phase10_scope_reassessment.md`
— §10 exit vs Phase-14 deferral (multi-memory's 407 JIT skips ⇒ JIT skip=0 unreachable as written).
ADR-0128-amendment / user-flip. Plenty of non-gated forward work exists → do NOT stop on this.

## Active bundle

- **Bundle-ID**: `10.E-eh-on-jit` (opened `3b668110`; supersedes the now-met `10.G-typesubtyping-RTT`).
- **Cycles-remaining**: ~3-4.
- **Continuity-memo**: try_table.1.wasm per-module blocker STACK (rejects at FIRST failing func; corpus
  flips only when the WHOLE module compiles+runs). ✅ func[6] validate StackTypeMismatch (tag index space —
  FIXED `3b668110`) → ❌ func[24] try_table emit UnsupportedOp (eh_landing_pads null, catchless) → ❌ func[36]
  return_call_indirect UnsupportedOp (TC-in-try) → ❌ try_table.2 `imported-mismatch` returns 0 (cross-module
  imported tag, maybe same index class). The handler dispatch is already done. Find each via stderr
  `compileWasm: func[K]→err` / `arm64/emit: failing op X`.
- **Exit-condition**: `exception-handling/try_table.1.wasm` JIT-compiles + its 33 asserts run (skip→pass)
  AND `imported-mismatch` returns 3 → JIT EH dir return-fail = 0 (currently pass=0 fail=1 skip=33).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 stale u32; D-234 (51 OOB assert_trap = harness artifact).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198 + br_on_null/cast modrej.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + return_call_indirect-in-try + `wasm_of_ocaml`.
- **10.E** EH — dispatch done; blocker = the `10.E-eh-on-jit` stack above + eh_frequency runner (I20),
  c_api tag accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit COMPLETE both arches; §1 + PHASE C + D-235 DONE; remaining = D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

THIS turn = the JIT tag-index-space fix (`3b668110`). Empirically: try_table.1 modrej reason moved
StackTypeMismatch (func[6]) → UnsupportedOp (func[24] try_table emit); global JIT corpus byte-identical
762/2/531 (no regression), interp 1233/0; gate green. ubuntu kick fired for `3b668110` (verifies x86_64
build of the shared compile.zig change — arch-independent logic, low risk). Next resume Step 0.7:
`tail -3 /tmp/ubuntu.log` — expect `OK (HEAD=3b668110)`; on FAIL it's a build/decode issue in the
imports-first tags loop, investigate. Mac aarch64; ubuntu = x86_64.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh` (writes `/tmp/mac_gate.log`); never
`zig build test-all > log; grep -c …` (trailing `grep -c` exits 1 on zero → false fail). JIT corpus:
`zig build test-spec-wasm-3.0-assert` (NO bogus `-Dno-run` — fails build + reuses STALE exe), then
freshest-exe via `/usr/bin/find .zig-cache/o -name zwasm-spec-wasm-3-0-assert` (shell `ls` alias appends
`*` → exec 127), `ZWASM_SPEC_ENGINE=jit <exe> test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT
stderr — emit diagnostics splice into stdout otherwise). Per-dir `JIT: return pass/fail/skip` + `JITval`/`JITmodrej`.

## Key refs

- ADR-0128 (Phase 10 100% master plan); ADR-0131 / ADR-0126 (subtype + canonical ids; D-235); ADR-0114
  (EH design — try_table/landing pads/trampoline); ADR-0119 (naked trampoline). ROADMAP §10.E.
- Debt: **D-234** (memory64 assert_trap harness artifact), D-198 / D-209 / D-210 / D-211 / D-212.
  Lessons: `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch` (THIS),
  `2026-06-02-jit-corpus-late-phase-is-per-module-blocker-stacks`,
  `2026-06-03-jit-trampoline-mid-op-clobbers-operands` (D-235).
