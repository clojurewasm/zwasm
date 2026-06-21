# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17, `.auto`→JIT FLIP CAMPAIGN = PRIORITY (release = USER-ONLY, ADR-0156)

**POSTURE (user-directed 2026-06-21, REVISED)**: drive the **`.auto`→JIT flip** as the top priority. The flip's
only true blockers are the two no-fallback runtime bugs **D-489** (x86_64 realworld JIT miscompile, tinygo_json) +
**D-494** (TinyGo defer/recover asyncify deadlock under JIT, both arches) — everything else (imports / unsupported
ops / wide host-sigs) rejects at instantiation and falls back to interp safely (instance.zig:725-731). Fix both →
re-land the flip → green-light = 3-host gate + full x86_64 interp-vs-jit realworld sweep clean. **Tag-cut PENDED**
(release notes already drafted at `.dev/release_notes/v2.0.0-alpha.3.md`; last actual tag = `v2.0.0-alpha.2`).
**cljw dogfooding PAUSED both sides** (cljw mid require-redesign; brief `to_cljw_06.md` sent with current truth).

Project at the **完成形 plateau** (all dims confirmed): clean (C/Zig/CLI audits), full-featured (WASI complete +
now cross-component STRING composition, D-305 milestone), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity, D-265 closed). Robustness: interp+JIT fuzz 0 crashes. Closed-arc detail lives in git/ADRs/lessons.

**Closed arcs (detail in git/ADRs/debt — do NOT re-walk)**: D-305 cross-component linker (string/list/record
marshalling both directions, ADR-0196, comp-assert 170/0); ADR-0195 guest↔guest async FUNCTIONALLY COMPLETE +
D-463 handle isolation (ADR-0197); D-034 SIMD spill-completeness CLOSED @411dd1e14; wasi:random, D-335 typed
marshalling, C-API Windows-export. Residual long-tails (debt-tracked, do NOT grind): D-464 async adversarial,
D-305 niche shapes. Version `2.0.0-alpha.3`. Low-pri follow-up: consolidate duplicated SIMD spill helpers.

## JIT FLIP CAMPAIGN (D-489) — BREAKTHROUGH: NOT a codegen bug; it's the JIT stdout-CAPTURE path (2026-06-21)

**D-489 is NOT a JIT miscompile.** Direct CLI `zwasm run tinygo_json.wasm --engine jit` on ubuntu x86_64-linux is
**CORRECT (90B, genuine JIT — 45 callcounts)**. The 130B failure reproduces ONLY through the stdout-**CAPTURE** path
(`host.stdout_buffer` set) under JIT, x86_64-linux only (arm64 + Rosetta mask it). **Minimal repro committed:
`zig build d489-repro`** (`test/realworld/d489_repro.zig`) — scenario (1) jit-alone (fresh process, nothing before
it) = 130 DIVERGED. **RULED OUT**: in-process ripple (1-alone fails), buffer realloc (scenario 3 pre-sized still
130), argv-len (probe3), limits/preopen/env (all match interp which is correct). **Isolated to** `src/wasi/fd.zig`
`writeSlice` (~157): the ONLY diff between correct/broken is `buffer.appendSlice(...)` vs `std_stream.writeStreamingAll`
— yet the buffer branch corrupts GUEST linear memory (fmt format-string → spaces, roundtrip OK→FAIL) under JIT on
x86_64-linux. Shared interp/JIT code, so the corruption is an interaction (memory layout / io-context / Zig
memory-model — user's hypothesis open). **IMPLICATION: the `.auto`→JIT flip is NOT blocked by a codegen bug** —
direct JIT exec is correct; the diff-jit GATE gives a FALSE failure (it uses the capture path). The capture bug is
real (hits any stdout-capturing embedder) but narrow. **NEXT = dynamic trace on ubuntu** (remote, the only place it
manifests): why does appendSlice-to-buffer vs real-fd-write corrupt guest memory under JIT x86_64-linux? Then fix →
re-run diff-jit (should go green) → flip is clear.
- **D-494** (dfr2 defer/recover): arm64-correct at HEAD; the "both-arch arm64-reproducible" claim was DOUBTFUL —
  likely the same capture-path artifact. Verify via d489-repro-style harness if needed.
- diff-jit lane is OPT-IN (not in `test-all`) → not a test-all regression. SSH iterate on ubuntu (`nix develop
  --command zig build d489-repro`); pull-to-experiment per user.

**WINDOWS GATE — 3-host GREEN @ed9332294** (2026-06-21): earlier host-example file-create failure was an ENV FLAKE,
cleared on re-run (Win64 spec 25539/0, simd 25075/0, wasi 3/0). Recorded via `--record`. Intermittent
host-embedding-example file-create stays debt-tracked (`windows-host-example-filecreate`), NOT a code regression.

## D-489 NEXT-STEP (lldb on ubuntu) + closed arcs

**fmtwatch RULED OUT memory-overwrite (2026-06-22)**: `ZWASM_DEBUG=fmtwatch` (committed in jit_dispatch.fd_write) shows
the "name=%s age=%d city=%s" rodata @guest-off 86586 is INTACT at ALL 9 fd_writes — yet output is 130/`%!(EXTRA)`. So
the format-string BYTES are NOT corrupted; a guest VALUE (the fmt format-slice ptr/len passed to fmt) is wrong. TinyGo
fmt writes incrementally (9 fd_writes) → a value live across a capture-path fd_write gets clobbered. **REFINED
HYPOTHESIS**: NOT a register clobber — the JIT calls one C fn (`jit_dispatch.fd_write`, callconv .c) that preserves
callee-saved in BOTH cases; capture-vs-realfd differs only INSIDE that boundary (invisible to JIT). So it's a
STACK/MEMORY data effect: the JIT reads a wasm value (the fmt format-slice ptr/len) from a STALE native-stack spill
slot AFTER the call — it failed to spill-or-reload it — and the slot's stale contents depend on the host call's stack
usage (appendSlice shallow vs writeStreamingAll deep differ on x86_64-linux). Fits all: linux-only, optimize-indep,
heap-indep (stack), ReleaseSafe-silent (valid addr, stale data). Suspect: op_call.zig spill/reload is incomplete for
some live value across host-import calls. **NEXT = lldb: after the fd_write call, see what addr/value the JIT loads as
the format-slice, vs what it spilled** (ubuntu, by NAME not addr — PIE; outer/inner + `nix develop --command lldb -s`) (ubuntu, by NAME not addr — PIE; outer/inner script pattern + `nix develop --command lldb`, command-file via
`-s`). Diagnostics in tree: `ZWASM_DEBUG=fmtwatch` / `mem.cksum` (mem.cksum CONFOUNDED by random_get). Repro: `zig
build d489-repro` (scenario1 jit-alone=130 on ubuntu only). **Closed arcs** (do NOT re-walk): v128-GC sweep
(D-491/492/493 fixed, D-495 guarded); arm64 JIT-exec ZERO divergences; ADR-0200 JIT embedding API + cljw to_cljw_06.


**`.auto`→JIT flip = blocked on D-489, now an ACTIVE CAMPAIGN** (see `## Active bundle` above — user-directed
2026-06-21, NOT a 妥協/defer). Twice-reverted (last @7dbdb973c; origin green). The flip is a FORCING FUNCTION that
exposed the D-489 x86_64 spill-pressure miscompile Mac-arm64 masks. Ruled out this session: emitMemOp-isolated
(@d856f89ef, 2 bounded fixtures clean), arm64-pressure-repro (@5f1f08db1, ADR-0077 blocks pool-shrink → x86_64-only),
Zig-optimizer-mode (Debug+ReleaseFast both repro → deterministic). NOW localized to printf#2 (see bundle). D-490 was a
SEPARATE bug (FIXED @eddd74941). Other flip prereqs (post-D-489): **(b)** pin interp-conformance runners
(`wast_runtime_runner`) to `.interp`; **(c)** wide-shape `wrapper_thunk.emit` (D-477). **cljw NOT blocked** (explicit
`.jit` works). Adjacent sweep this session: D-491 CLOSED, D-492/D-493 filed (v128-in-GC-type niche gaps).

**D-491 CLOSED @56fcc53cd**: typed `select (result v128)` (0x1c/0x7B) now validates (validator.zig:3046) + lowers
(lower.zig:355) + JIT-executes on both arches (codegen already dispatched v128 via value shape-tag). Interp traps
(SIMD-JIT-only, by design). Fixture `test/edge_cases/p17/select_typed_v128` (=111). test-spec-simd 25075/0 +
wasm-2.0-assert 25539/0 both arm64 + x86_64-macos.

**STANDING DIRECTIVE = CORRECTNESS SWEEP** (user 2026-06-20, memory `feedback_correctness_sweep_phase`): high-value
bar OFF. Sweep toward 0% the 3 gap classes — (1) wasmtime-works-zwasm-doesn't, (2) wasm/wasi spec non-conformance,
(3) instability/crashes — easiest-first, TDD + 3-host, repeat; don't ask "is this high-value." Status: spec
skip-impl=0, realworld JIT 56/56 GATING (`test-realworld-diff-jit`), no UnsupportedOp crash, fuzz 0-crash.
ADR-0200 (JIT embedding API) + D-477 (JIT host-invoke) were the live fronts — both delivered/closed; the
ADR-0200 tail = D-478. Prior sweep closures (D-468/D-469/D-470/D-475/D-476/extended-const/GC trap-kind/
memory64+SIMD/fuzz exec-differential) are in git/lessons — do NOT re-walk.
**VERIFICATION LESSON (operationally live)**: a JIT-codegen fix MUST be checked with `test-spec-wasm-2.0-assert`
on BOTH arm64 AND `-Dtarget=x86_64-macos` — NOT `test-spec`(interp)/`zig build test`(unit).
**D-475 table64 slice 4 (JIT table64 codegen) PARKED** (structural u32→u64 descriptor widening, Win64-risk; bounded
4-cycle bundle in debt row, PERF not correctness). Self-contained table64 interp-conformance DONE.

**Phase 17 完成形 plateau** (validated — do NOT re-walk): async COMPLETE; v128 spill (D-034/D-460/D-461) CLOSED;
surface audits clean 2026-06-18; fuzz 0-crash; realworld JIT run 56/56 byte-match wasmtime (gating). NOT-WORTH: D-294-R2 TrapKind.

**Step-0.7 NOTE**: `failed command: test…--listen=-` is COSMETIC (exits 0); trust `[run_remote_*] OK/FAIL` + `N
passed, 0 failed`, not that line.

**PARKED / gated (do NOT speculatively grind)**: D-305 long-tail (niche, + `component_graph.zig` 1895/2000
file-split first); D-464 async; 21 `blocked-by`. **validator.zig at 3449/3450 cap — NEXT validator edit MUST
extract per the file's marker plan.** Closed-arc detail (D-305/ADR-0192/async/WASI-0.3) is in git/ADRs/debt.

## Long-tail (debt-tracked / parked — NOT active; see debt.yaml)

- **JIT-correctness** (front B): D-331(B) CLOSED · D-330 c_sha256 PROVABLY-BLOCKED · D-331(A) go runtime-corruption
  DRIVABLE · D-333 folds into D-330 (all in debt.yaml; D-489 may share the go/x86_64 spill root). D-454 GC-program
  fixture future-bucket. Trace tooling: `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh` (Recipe 18).

## State (all 3-host green @046d9c67/win @886d0667; release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip (GC 362/0). **WASI 0.1** complete; **0.2/CM** default-ON (corpus 158/0/0);
  **0.3 core** done. Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 · Zig-API complete (full WASI parity) · lean CLI · memory-safety sound · dogfooded into
  cw. Runners ReleaseSafe (ADR-0177; `check_releasesafe_runners.sh`).
- **EH**: cross-instance JIT EH on BOTH arches (arm64 `4f73d9ee` + x86_64 `c534afca`). Interp + JIT EH corpus green.
- **Debt**: 62 entries; **ZERO `now`-class** (D-034 spill arc CLOSED @411dd1e14 → `note`; D-460 v128-GC + D-461 +
  D-293 + D-294 all `note`). Remaining partials: D-305 (consumer-gated CM shapes), D-331(A)/D-330 (go_* JIT; B closed).
  Rest front-tagged (future-bucket/parked); D-462 feature-separation = user-gated. **完成形 plateau.**
- **Realworld corpus**: 56 fixtures (c/cpp/emcc/go/tinygo/rust/zig), interp 56/0; JIT run-stage opt-in.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3` — fixture toolchains. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0187-0191** (CM-async) · **0185** (x86_64 EH) ·
  **0099** (file-size caps) · **0126** (iso-recursive canonical equality).
- lessons INDEX: `.dev/lessons/INDEX.md` (keyword index for Step 0.4).
