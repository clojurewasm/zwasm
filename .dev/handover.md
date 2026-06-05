# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 (完成形) — §16.1–16.7 task-list COMPLETE; the loop CONTINUES, no release (ADR-0156).** Phases 0–15
  + the entire §16 surface/safety/docs task-list are DONE. The v2 redesign has hit the 完成形 bar: clean design +
  lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces (C/Zig/CLI). **The loop never
  tags/publishes/cuts over** (manual user-only); it now keeps refining + paying backlog debt **indefinitely**.
  Phase Status widget stays Phase-16 IN-PROGRESS (completion-finalization is open-ended, not a closeable phase).
- **§16 outcomes** (detail in the ROADMAP §16 rows + ADRs + CHANGELOG): **§16.1** migration guide (`58a483e8`);
  **§16.2** C-API **gap 0 (293/293)** (`e9367bb2`, `scripts/capi_surface_gap.sh`); **§16.3** Zig-API facade
  confirmed minimal/clean (ADR-0025→0109); **§16.4** CLI = **run+compile** + --version/--help (ADR-0159);
  **§16.5** dogfooding — external consumability fixed + Global/Table accessors (D-272 closed), full facade proven
  via `examples/zig_dep/`; **§16.6** GC-on-JIT memory-safe — collect trigger + adversarial UAF test green
  Mac+x86_64 (ADR-0160); **§16.7** docs — README/CHANGELOG/`docs/reference/`/`docs/tutorial.md` to the settled
  surface (`12390815`, `3a5e8ba0`).

## NEXT — USER-DIRECTED PROGRAM 2026-06-05 (supersedes the bucket-3 plateau): complete WASI + all-engine + CM

The prior finalization items are DONE (C-API funcref D-269 = owned-handle `of.ref`, `01c1d0cb`, bundle D-269B
closed; verified x86_64 `OK HEAD=2ea7c187`). A new **user-directed program** (chat 2026-06-05) is now the active
work — **ADR-0161** (WASI completion) + **ADR-0162** (toolchain carve-out). Ordered:

- **A — 整備 DONE this session**: rust on test hosts (win rustc / ubuntu flake `.#rust-host`); ADR-0161 (WASI)
  +0162 (toolchain) +**0076 D7** (windows cadence gate, below); §11.1 overclaim corrected (**WASI=21/46**); D-278
  scheduled. **A5 CM survey DONE** (`component_model_survey.md`: pivot risk **LOW-MED**, CM = new `src/feature/
  component/` layer ≈v1's 5,600 LOC, no core rewrite). **A1-wire DONE — 3-OS rust run COMPLETE**: rust_host green
  on Mac + ubuntu (`.#rust-host`) + **windows (GNU toolchain + `.exe` fix)**; D-254 resolved (a). 3-host test-all
  re-checked: Mac+ubuntu GREEN; windows flaked once → **D-279 Win64 SIMD heisenbug** (re-run `simd_assert_runner:
  13351 passed/0 failed` — intermittent, not a miscompile; now monitored by D7).
- **1. D-273(1) `--invoke` args + typed result** (the only `now` row) — type-driven parse → stdout. Ref v1 CLI. FIRST.
- **2. D-278 WASI preview1 21→46** (interp) — sockets ×9 / fd_readdir / path_* ×7 / pread/pwrite/sync/... TDD each.
- **3. All-engine WASI** (D-251 AOT + D-244 d-3 JIT). **4. Precise GC root + AOT-GC** (D-211; verify load-bearing first).
- **Post-v0.1.0**: Component Model / WASI P2 (A5 survey informs). WASI 0.3/async (ClojureWasmFromScratch agent ref).

**ADR-0076 D7 (windows cadence gate)**: the loop now HONORS `should_gate_windows.sh` (run windows たまに — ABI-risk
diff OR ≥4 commits, NOT per-turn/too-slow, NOT phase-boundary/too-rare). Win64 red = heisenbug-classify (re-run),
no auto-revert. Step 6+7: `should_gate_windows.sh` exit 0 → kick `run_remote_windows.sh test-all` + `--record`.

## Step 0.7 (next resume) — verify per-cadence remote logs

Mac+ubuntu test-all GREEN this session; ubuntu rust_host GREEN. Origin = `72c4aaf8` (after push). Next code chunk
(D-273(1)) kicks ubuntu (always) + windows (if `should_gate_windows.sh` exit 0 — likely, build.zig touched). Step
0.7: `tail /tmp/ubuntu.log` (auto-revert on FAIL) + `tail /tmp/win.log` if windows fired (D7 heisenbug-classify).
**Gate**: Mac = `bash scripts/mac_gate.sh`; ubuntu = always test-all (D6); windows = cadence (D7).

## Deferred / open debt (D-274/275/276/257 discharged this session — removed)

- **Memory-safety (§16.6 DONE, verified 2-host; D-276 proven by ADR-0060)** — only residual is **D-211** precise
  GcRootMap (deferred; conservative scan proven sufficient meanwhile). **D-210** cohort root fix (D-142/206/210/245).
- **Surface residuals** — (**D-269** promoted to NEXT chunk above.) **D-273** CLI flag gap vs wasmtime (validated
  defer). **D-253** ref machinery (incl. D-253-D standalone-copy; owned-handle `of.ref` model). **D-271**
  serialize=source-bytes (no AOT cache). **D-255** C-API WASI io. **D-251** WASI in AOT.
- **D-254** rust 3-OS. **D-249** win bench. **D-238** x86_64 EH thunk. **D-266/D-259** notes.

## Key refs

- ROADMAP §16 (16.1–16.4 ✅ → 16.5 dogfooding → 16.6 memory-safety → 16.7 docs; NO release gate). §1.2 (完成形
  industry-standard surfaces). ADR-0156 (endgame); **ADR-0159 (§16.4 CLI = run+compile)**; ADR-0157/0158 (C-API
  split + ref model); ADR-0109 (Zig facade); ADR-0136 (`run --engine`). `scripts/capi_surface_gap.sh` (gap=0).
