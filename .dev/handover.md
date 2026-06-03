# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **13 IN-PROGRESS — C API full (wasm-c-api conformance)**. **Phase 12 (AOT) DONE**.
- **§13.0–§13.2 [x]** (gap audit `.dev/phase13_capi_gap.md`; full C-API surface — type/extern/import-export/
  ref/foreign constructors + host-entity construction). Sub-chunk SHAs in ADR-0142 + §13.2 commits. Remaining
  D-253 (per-entity host_info-bulk, cap-blocked by instance.zig 3299/3300; degenerate instance/extern as_ref,
  not-modeled) = §13.4-driven, deferred.
- **§13.4 [x]** — `test/c_api_conformance/` 5 examples via `zig build test-c-api-conformance` (in test-all),
  fail=0 Mac+ubuntu (windowsmini = §13.P boundary).
- **§13.5 [x]** — host examples. c_host (`test-c-api`) + zig_host (`run-zig-host`) in test-all = 3-OS-verified
  at phase boundary. **rust_host** `2323714a` — `examples/rust_host/hello.rs`, an `extern "C"` wasm.h consumer
  linking `libzwasm.a` (3rd independent ABI consumer), Mac-only `zig build run-rust-host`, NOT in test-all.
  rust-on-3-OS sub-clause deferred to §13.P (**D-254**; test hosts rustc-free by design) per **ADR-0142** (amended).
  Build step probes `SDKROOT` to survive this Mac's broken `xcrun --show-sdk-path` (host config, SDK present).
- **§13.3 [ ]** — `inherit_argv`/`inherit_env` + `preopen_dir` remain **ADR-0070-blocked** (Zig 0.16 capability-
  based I/O: a C-library context has no `Init` token for process argv/env). Partial done `47298cd1` (`set_args`/
  `set_envs`/`inherit_stdio`). Interleaves once ADR-0070 lands; explicit set_args/envs already cover config.

## Next task (autonomous)

**Next: resolve the §13.3 ADR-0070 block — it gates §13.P.** §13.P (Phase-13 close) is NOT a registered
hard-gate (§13's 🔒 is the end-of-phase conformance gate, explicitly "NOT an entry hard-gate"; §13.P references
no `.dev/phase*.md` doc → drive it autonomously, not a user-stop). BUT §13.P cannot close while §13.3 (wasi.h
surface complete) is `[ ]`. So the real next chunk is the §13.3 remainder: **decide, autonomous-with-ADR**,
whether C-API WASI `inherit_argv`/`inherit_env`/`preopen_dir` is (a) implementable now via the libc `environ`
global (→ ADR-0070 amendment per `libc_boundary.md`, since a C-library `Host` has no Zig-0.16 `Init`/`std.process`
token) or (b) genuinely out-of-scope-for-v0.1 → defer with an ADR + re-scope §13.3 exit (explicit `set_args`/
`set_envs` already cover config). Survey ADR-0070 + `api/wasi.zig` first. Once §13.3 resolves → **§13.P close**:
audit_scaffolding (mandatory) + windowsmini 3-host reconcile + make the deferred D-254 rust-3-OS call (option (b):
re-phrase exit to "Mac rust + 2-host conformance") + SHA backfill §13 + widget 13→DONE + Phase 14 inline expand.
**§13.3 is the gate, NOT a skip.** D-253 C-E stay deferred (cap-blocked / not-modeled).

gap: `.dev/phase13_capi_gap.md`.

## Step 0.7 (next resume)

This turn: §13.5 rust_host (`2323714a` src + chore handover/roadmap/ADR/debt commit). Mac gate GREEN
(`/tmp/mac_gate_rusthost.log`, exit 0). An ubuntu `test-all` is kicked → next resume `tail /tmp/ubuntu.log` for
`[run_remote_ubuntu] OK`. **NOTE** (lesson `gate-tail-vs-exit-code`, updated this turn): a stray `failed command:`
in the ubuntu log next to OK is **benign** zig test-isolation noise (abort/panic/trap child procs) — the **exit
code is authoritative**, not the tail. Do NOT re-investigate / revert on that alone. Prior ubuntu `46edb841`
(test-all) verified OK (DIRECT_EXIT=0, TESTALL_EXIT=0); windowsmini `0810b339` GREEN.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. rust_host = Mac-only `zig build run-rust-host`
(needs rustc; not gated, not in test-all). 3-host reconcile = phase boundary.

## Deferred / open debt (none a Phase-13-internal blocker except §13.3 / §13.P)

- **D-254** §13.5 rust-on-3-OS blocked on test-host rustc (by design) → §13.P final call (provision vs re-phrase).
- **D-253** §13.2 host_info-bulk (cap-blocked) + degenerate as_ref (not-modeled) → §13.4-driven, deferred.
- **§12.5 / §11.4** GC stack-map (AOT) + precise rooting → Phase 15 (ADR-0141 / ADR-0135; D-211).
- **D-251** WASI/host imports in AOT — with JIT-WASI d-3 (D-244); ADR-0140. **D-249** Win bench timing (D-137).
- **D-245** host→JIT callee-saved (win64 + arg'd). **D-246** §11.3 arm64 dot/extmul → Phase 15. **D-238** x86_64
  EH thunk. D-210/D-234/D-237/D-229/D-231/D-204/D-209/D-213 (note).

## Key refs

- ROADMAP §13 (task table + Goal/exit); Phase Status widget (Phase 12 DONE / 13 IN-PROGRESS).
- ADR-0142 (§13.2 scope + §13.3/§13.4 seq + §13.5 rust_host Mac-only); ADR-0141 (Phase-12 close); ADR-0070
  (libc/io boundary, blocks §13.3 remainder). `api/wasm.zig` + `include/wasm.h` = §13 surface; `cli/run.zig` drives it.
