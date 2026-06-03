# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle

- **Bundle-ID**: D-245-win64-host-jit-trampoline
- **Cycles-remaining**: ~3–5 (Win64 asm + remote-windows verify loop)
- **Continuity-memo**: win64 host→JIT `@call` seam (`src/engine/codegen/shared/entry.zig`
  `invokeAndCheck*`) corrupts callee-saved on win64. Fix = asm trampoline saving/restoring the
  **win64** callee-saved set: RBX/RBP/RDI/RSI/R12–R15 **+ XMM6–XMM15** (the v128/SIMD regs the
  JIT body clobbers — the proximate corruptor) + 32-byte shadow space + 16-byte align. Template =
  x86_64-SysV no-arg trampoline `de576a76` (D-245); extend to win64 callee-saved set + the v128 /
  arg'd `invokeAndCheck*` variants (D-245(b), still `@call`). Cross-check `zig build
  -Dtarget=x86_64-windows-gnu` on Mac before each push.
- **Exit-condition**: windowsmini `test-spec-simd` passes with the KNOWN-BAD seed pinned
  (`zig build test-spec-simd` reproard; the unlucky full-run seed was `0x931361c3`) across ≥3 runs,
  AND a full windowsmini `test-all` lands green → then finalize §13.P close.

## Current state

- **Phase 13 (C API) IN-PROGRESS — deliverables DONE + 3-host-green; §13.P close BLOCKED on D-245.**
- **§13.0–§13.5 all `[x]`.** §13.2 full C-API surface; §13.4 conformance (5 examples, in test-all);
  §13.5 host examples (c_host + zig_host 3-OS; rust_host Mac-only, ADR-0142/D-254); §13.3 wasi.h
  re-scoped honest (inherit_argv/env/preopen_dir deferred, ADR-0143/D-255). D-253 (host_info/as_ref)
  deferred. Last close commits `19c7ccb9`+`528d2af3`.
- **§13.P close attempted this turn**: audit_scaffolding **0 block** (`private/audit-2026-06-04-p13close.md`;
  standing soon = 20 `<backfill>` markers). ubuntu `528d2af3` test-all OK. **windowsmini test-all RED**:
  Build Summary 61/63 OK, the ONLY failure = `zwasm-spec-simd` exit 3 (silent crash exec
  `simd_bit_shift.1.wasm` func0 via v128 host→JIT). **= D-245 win64 remainder** (NOT Phase-13: 0
  src/engine|src/instruction diff since `0810b339`). **Seed-flaky** (Debug "luck"): isolated
  `test-spec-simd` re-run PASSED — so windows passes on lucky seeds (Phase-12 close + the re-run),
  crashes on unlucky (`0x931361c3`). C-API + c_host + zig_host all PASS on win → Phase-13 deliverable
  is sound; the flaky-red is the unrelated Win64 SIMD-JIT ABI bug. Widget NOT flipped (honest).

## Next task (autonomous — bundle)

**Work the D-245-win64 bundle** (above). It is the genuine §13.P 3-host-reconcile blocker and is
solvable (template `de576a76`). Step 0: read `entry.zig` `invokeAndCheck*` + the existing arm64
(`8eca59e3`) / x86_64-SysV (`de576a76`) trampolines; identify the win64 seam + the v128 variant.
Then implement the win64 trampoline (GPR + XMM6–15 + shadow space). Verify: Mac cross-compile
(`-Dtarget=x86_64-windows-gnu`) then windowsmini `test-spec-simd` (pin/repro the bad seed). On
green → finalize §13.P (widget 13→DONE, Phase-14 table expand, §13.P [x], D-254 rust call). **Do
NOT game the seed** (re-rolling until green is dishonest — the flakiness is the real bug to fix).

## Step 0.7 (next resume)

This turn: §13.P close blocked (D-245 win64 surfaced); D-245 updated w/ §13.P repro; debt+handover
committed. ubuntu `528d2af3` test-all **OK** (verified). windowsmini test-all RED (D-245 flaky) —
this is the bundle's target, NOT a revert trigger (no Phase-13 code caused it). **NOTE** (lesson
`gate-tail-vs-exit-code`): `failed command: …test --listen=-` / `…-hello` next to a passing Build
Summary = benign zig test-isolation noise; trust the Build Summary step count + exit code.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile (compile-only) =
`zig build test -Dtarget=x86_64-windows-gnu`. windowsmini exec verify = `run_remote_windows.sh`.

## Deferred / open debt

- **D-245** win64 host→JIT callee-saved (XMM6–15 + GPR) — **ACTIVE BUNDLE** (was the deferred-to-
  windowsmini-boundary item; now at its boundary, blocks §13.P).
- **D-255** C-API WASI inherit_argv/env/preopen_dir (io-infra; ADR-0143). **D-254** rust 3-OS (test-host
  rustc; ADR-0142). **D-253** §13.2 host_info/as_ref (cap-blocked). **§12.5/§11.4** GC stack-map → P15.
- **D-251** WASI/host in AOT (D-244). **D-246** arm64 dot/extmul → P15. **D-238** x86_64 EH thunk. D-249/
  D-210/D-234/D-237/D-229/D-231/D-204/D-209/D-213 (note). Standing: 20 `<backfill>` markers → §14.P sweep.

## Key refs

- ROADMAP §13 (all rows [x] except §13.P); Phase Status widget (13 IN-PROGRESS). ADR-0142/0143
  (§13 scoping). D-245 (the bundle). `entry.zig` + `jit_abi.zig` = the host→JIT seam. ADR-0017 sub-2d-ii.
