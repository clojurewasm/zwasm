# clang → wasm realworld fixture recipe + harness gaps (cyc196)

**Date**: 2026-05-30 · **Citing**: `086c2991` · Phase 10 realworld/p10

## The clang → wasm recipe (nix-wrapped toolchain)

The nix-wrapped `clang` (in PATH) needs two workarounds to emit wasm:

```sh
# wasm-ld lives in the lld package, NOT the clang-wrapper's PATH:
export PATH=/nix/store/<hash>-lld-20.1.8/bin:$PATH   # provides wasm-ld
# nix injects -fzero-call-used-regs (unsupported on wasm32) via hardening:
NIX_HARDENING_ENABLE="" clang --target=wasm32 -nostdlib \
    -Wl,--no-entry -Wl,--export-all -O2 -o out.wasm in.c
# tail-call:  add  -mtail-call   → emits `return_call` (musttail attr)
# wasm64:     --target=wasm64
```

- Without `NIX_HARDENING_ENABLE=""` → `error: unsupported option
  '-fzero-call-used-regs=used-gpr' for target 'wasm32'`.
- Without lld's `wasm-ld` on PATH → `posix_spawn failed` at link.
- Find wasm-ld: `ls /nix/store/*lld*/bin/wasm-ld`.

## Harness gaps surfaced (why realworld-clang is multi-cycle)

The edge-case runner (`runI32Export`, JIT) is the only RESULT-checking
fixture harness, but it has two limits for clang output:

1. **No full instantiation** — it compiles + invokes one no-arg func in
   isolation. **UPDATE cyc224**: it now DOES evaluate const global
   init-exprs (`setupRuntime`, fix prompted by the `rust_data` fixture),
   so `__stack_pointer` is correct and **shadow-stack modules now run**
   (real `-O` rust/clang code that spills the stack). Previously they
   trapped (`SP - n` wrapped to OOB because globals were left 0). Still
   no WASI / args / data-active-segment-beyond-globals support.
2. **No args** → a no-arg pure func constant-folds (clang -O2 folded
   `sum 1..10` to `i32.const 55`), so only trivial clang fixtures are
   JIT-verifiable this way.

The `test-realworld-run` harness DOES fully instantiate (`cli_run.runWasm`)
but only checks instantiate+invoke (no result-check, zero-arg) and globs
`test/realworld/wasm/` (not `p10/`). So a NON-trivial clang fixture with
a checked result needs harness work (full-instantiation + invoke-with-
result, like the wasm-3.0 spec runner does via interp).

**JIT cannot run `return_call`** (UnsupportedOp) — tail-call is interp-
only; see D-205. So `clang_musttail` can't be result-checked until JIT
tail-call lands OR an interp result-check harness exists.

**Update (cyc200, `04476dce`)**: JIT tail-call codegen now LANDS — direct +
indirect + recursion-with-args all JIT-execute (root fix = the liveness
terminator-class, not the emit). The `return_call`-can't-run gap above is
resolved. `clang_musttail` result-check is now blocked ONLY by gaps #1+#2
(no full-instantiation + no-arg-only result-check) — a realworld-harness
task, not a tail-call-impl task. See D-205.

## Landed

`test/edge_cases/p10/clang_smoke/loop_sum.{wasm,c,expect}` — first real
clang-emitted module in the suite (proves parse + JIT-run of clang's
module shape). Modest (constant-folded) but a pipeline regression guard.

## Related

- D-205 (JIT tail-call gap) · `test/realworld/p10/` README (skip-list)
- `.claude/rules/extended_challenge.md` (toolchain self-provision)
