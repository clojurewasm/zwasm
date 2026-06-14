# ReleaseSafe-only JIT-ABI failures (D-311) — findings

> **Doc-state**: ACTIVE

## Context

The per-chunk gates (`mac_gate.sh`, `run_remote_ubuntu.sh`,
`run_remote_windows.sh`) run `zig build test-all` with **no `-Doptimize`**
→ Zig's `standardOptimizeOption` default = **Debug**. Debug host execution
is ~5–10× slower than ReleaseSafe, hurting integration-test iteration speed
(user-flagged 2026-06-08). ReleaseSafe keeps all safety checks and is the
intended CI mode (ADR-0015); it also exposes a JIT-ABI bug class Debug
hides (D-245 — `check_jit_releasesafe.sh`), because the optimized host
keeps callee-saved registers + poisons undefined memory with `0xaa`.

## Finding (Mac aarch64, `zig build test-all -Doptimize=ReleaseSafe` @c046f4a7)

**Debug = green; ReleaseSafe = 4 fail + 4 crash** (2690/2710 pass). All in
the JIT multi-result / entry-buffer / wrapper-thunk ABI glue:

| Test | Symptom |
|---|---|
| `linker.test.link: 2-function module fn0 calls fn1 returns 7` | SIGABRT — SEGV at `linker.zig:219 entryAddr` (`func_offsets[idx]`, addr 0x0) |
| `linker.test.link+execute: fn0 return_call fn1 returns 7 (ADR-0112)` | SEGV addr `0xaaaa…fa` (undefined memory) at linker.zig:830 |
| `entry.test.entry: f32 local round-trip (local.get 0 f32 via V0)` | Bus error addr `0xaaaa…` |
| `entry_buffer_write … invokeMultiResultNoArgs 3-i32 (ADR-0106 3b)` | expected 100, found 0 (result not written) |
| `entry_buffer_write … () → (i32,i64) (ADR-0106 3c)` | expected 7, found 0 |
| `entry_buffer_write … () → (i64,i32) (ADR-0106 3c)` | expected 2882400018, found 0 |
| `runner_test … invokeMulti 2-result (i32 i32) via entry_buf (ADR-0106 3)` | panic: access union field `i32` while `f32` active (runner.zig:680) |
| `runner_test … invokeMulti 1-param 2-result (arg,42) (D-229)` | expected 5, found 1862664544 (garbage) |

Common thread: the **multi-result entry-buffer + wrapper-thunk return-value
unpacking** reads uninitialized memory / the wrong `Value` union field under
ReleaseSafe. `0xaaaa…` = ReleaseSafe undefined-poison → an uninitialized
read the Debug build happens to get away with. The `union field i32 while
f32 active` is a real type-confusion in the multi-result Value path.

## Plan (D-311 / ADR-0177 bundle: ReleaseSafe-JIT-hardening)

1. Fix the 8 ReleaseSafe-only failures (correctness + memory-safety —
   undefined reads in JIT ABI glue). Likely 1–2 root causes (entry-buffer
   result write + Value-union tagging in multi-result unpack).
2. THEN switch the per-chunk gates to `-Doptimize=ReleaseSafe` for the
   integration steps (`test-all`); keep unit `test` Debug; `gate_merge.sh`
   keeps Debug test-all (merge-checkpoint undefined-fill coverage) + its
   existing ReleaseSafe JIT smoke. Cache keys on optimize → Debug +
   ReleaseSafe caches coexist (no thrash).

Reproduce: `zig build test-all -Doptimize=ReleaseSafe` (Mac). Full log
captured at investigation time; per-test isolation via the named test.

## Resolution (DONE @02965aa6 — D-311 discharged)

**Root cause #1 (production, FIXED @a0069ce8)**: `invokeBufferWrite`
(entry_buffer_write.zig) called the JIT `fn_ptr` DIRECTLY, bypassing the
D-245 cohort-clobber trampoline the register/void paths use
(`entry.invokeAndCheck` → `jitTrampoline`). The native_emit'd body
MOV-installs the pinned callee-saved cohort (RBX/R12-R15 · X19-X28) from
`rt` without stack-saving the caller's values → ReleaseSafe (live values in
those regs) corrupts. Fix: route through a non-inline `jitTrampolineBuf`
(reuses exported `entry.jit_cohort_clobbers`). **Resolves 5 of 8** (all the
buffer-write / `runner.invokeMulti` multi-result failures).

**Remaining 3 (test-harness, NOT production)**: `entry`/`linker` UNIT tests
that call a raw `module.entry(...)` fn-ptr directly (e.g. `f(&rt, 3.5)`),
violating the host-boundary contract (host with live callee-saved must go
through the trampoline). 119 such raw-entry call-sites exist in
`src/engine/`; only 3 trip on the current seed (seed-dependent). Production
NEVER calls raw entry (always `invokeAndCheck`/`invokeBufferWrite`).

**Decision (avoids a 119-site sweep)**: the integration RUNNERS
(spec_assert/realworld/wast/edge — the slow corpus the user cares about)
invoke ONLY via production trampoline-safe paths and **already pass in
ReleaseSafe** (verified: spec 212, realworld 55, wast 1158 green in the
full ReleaseSafe run). So:
- Build the integration-runner exes **ReleaseSafe** (the iteration-speed win).
- Keep `core_tests` (unit, the raw-entry calls) **Debug** (user: unit-Debug
  fine). The 3 raw-entry failures stay Debug-only — acceptable.
- `gate_merge.sh` unchanged (Debug test-all + ReleaseSafe JIT smoke).
This is a per-exe `optimize` in build.zig — Zig caches per optimize (no thrash).

NEXT chunk: build.zig per-exe optimize split + flip the gate scripts'
runner invocations + verify Mac+ubuntu green, then discharge D-311.

## Re-narrowed 2026-06-14 (flaky `zig build test` — NOT a 5-min fix)

Investigated the residual seed-flaky SEGV in `zig build test` (Debug unit tests).
The doc's "119 raw-entry call-sites" OVER-COUNTED: most are safe fn-ptr
*materializations* (`module.entry(idx, Fn)` passed into `invokeAndCheck` /
`invokeAndCheckVoid` / `invokeBufferWrite` / `invokeMultiResultNoArgs` / the
`jitTrampolineBuf` helper at `entry_buffer_write.zig:107`). The contract-violating
**direct** test calls (bound ptr invoked inline as `f(&rt, …)`, bypassing the
clobber barrier) are FEW:

- `entry.zig:2693-2695` — f32 round-trip test: `const f = module.entry(0,Fn); f(&rt, 3.5)`.
- `linker.zig:597-598` + `828-829` — 2 link tests: `const f = module.entry(0,Fn); f(&rt)`.

**Fix recipe** (route through the existing safe helpers, all in `entry.zig`):
- f32 test → `try invokeAndCheck(&rt, f32, f, .{@as(f32, 3.5)})` (invokeAndCheck is
  the private inline wrapper; the test is in-module so it can call it).
- linker u32/no-arg tests → `try entry.callI32NoArgs(&module, 0, &rt)` (pub helper).

**OPEN (why it's not a clean 5-min fix)**: the x86_64 production multi-result path
`entry.zig:1365` + `:1424` (`const result = f(rt);`) has NO asm-clobber barrier
after the call (the arm64 sibling at :1361 uses `aarch64_blr_clobbers`). ubuntu
x86_64 test-all is green, so it may be safe-by-ABI (FuncRet struct-return) or just
not tripped — but UNVERIFIED. Before declaring the flaky gone, must (a) decide if
:1365/:1424 need the `asm volatile("" ::: entry.jit_cohort_clobbers)` barrier, and
(b) run `zig build test` ×~20 (seed-dependent) + 3-host to confirm zero SEGV.

→ Scoped as a focused chunk (test-site routing + x86_64 production-path decision +
many-run verification), NOT inline make-work. 3-host `test-all` remains authority
(green); this only improves local `zig build test` determinism.
