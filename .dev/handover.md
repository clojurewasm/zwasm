# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Embedder-hardening pass landed (2026-06-08) — PUSHED, 2-host green

User-directed robustness pass on the embedder surface + module decoder. Commits
`14de5430..d6699b00` on `zwasm-from-scratch`, **pushed** (no release tagged —
ADR-0156). Mac green; **ubuntu `test-all` OK @d6699b00**; windows gate OK
@9ee8f297 (later commits ABI-neutral + Win64 cross-compile clean — a windows
re-run + the 800MHz-throttle debug is batched for last, user-directed). Standalone
2669 pass / 0 fail; ~8700-input decoder mutation fuzz = 0 crashes.

**Shipped this pass**:
- **Facade `InstantiateOpts` budgets (ADR-0179 rev)** `14de5430` — `fuel` +
  `max_memory_pages` `Budget` union, FINITE defaults (1e9 / 4096 pg); armed
  before `(start)` + initial mem alloc; over-cap mem → `error.MemoryLimitExceeded`.
- **Facade budget-mutator invariant** `ac3db7c2` — `assert(runtime != null)`
  pins the interp-only facade (D-314 JIT seam tripwire).
- **Decoder robustness** `bd59fe86`/`e41d0c2c`/`9dcf72a2` — `checkVecCount`
  bounds every section vec-count; per-fn locals cap 50000; memory min/max vs spec
  page ceiling validated on the INTERP path too (was JIT-only); subtype-read guard.
- **table-min regression FIXED** `3ab0494f` — a large table `min` is spec-valid
  (table.6); the 10M figure was wasmparser's element-COUNT cap, mis-applied.
- **D-315 plant-time symlink** `e5510784` — `path_symlink` refuses an
  escaping/absolute target (`symlinkTargetEscapes`); guest can't plant an escape.
- **D-316 table cap** `d6699b00` — `Instance.setTableElementsLimit` (mirrors
  setMemoryPagesLimit; interp + facade grow paths).
- **ZE-3** closed by analysis — `_exit(70)` is CLI-only, never the embedder path;
  no raw panic/unreachable in embedder-reachable decode/runtime (no code change).
- **Fuzz** `a1c53484` — rec-group + limit-overrun seeds. **Docs/CI**
  `c902e067`/`0a788775` — §3.8 WasiConfig as-built; 18 Actions SHA-pinned.
- **Debt** `d3f860d0` (+ updates): D-315 follow-time symlink confinement
  (blocked-by); D-316 store-level instance-COUNT limiter (note).

> Audit-feedback bookkeeping for this pass lives in `private/` (gitignored).

**Prior Tier-1 / release-prep (all ubuntu-green, pushed)**: #2 static-lib + extlink hardening
`45438b7a` (D-312, GNU-stack=zig-upstream); **ADR-0179** sandboxing design;
**interp-engine sandboxing TRIAD** via the Zig facade — interrupt/cancel/timeout
`Instance.interrupt()` (#3a-1/2 `1001fa0e`/`460210f1`), memory-limit
`setMemoryPagesLimit` (#3c-1 `7216e7b1`), fuel `setFuel` (#3b `58479dd6`);
**Phase B** honest gap analysis in `docs/migration_v1_to_v2.md`; **Phase D**
README release polish. Earlier: musl (ADR-0178), test-noise cleanup,
`docs/v1_contributor_history.md` + migration-guide rewrite.

**Documented follow-ons (need a user decision / focused effort — NOT v0.1-blocking)**:
- **JIT-engine sandboxing**: extend interrupt/fuel/mem-cap to `--engine jit`.
  Multi-part: host→JIT interrupt DRIVING path (none today) + prologue-poll codegen
  both arches (Win64-risk → `should_gate_windows.sh --resume`, conflicts w/ cw dev)
  + a JIT-run-trap harness (none). Interp (default) carries the guarantee meanwhile.
  Bundle memo (interp/JIT runtimes separate, setInterruptFlag, arm64 poll plan) in
  git: commit `fb18bd82`.
- **#3a-4 CLI/C-API surface** (`--fuel`/`--timeout`/`--max-memory`; `zwasm.h`
  setters + `TrapKind.interrupted`) — small; the Zig facade already has it.
- **#1 C-API WASI preopen — D-251**: pure C-API has no `std.Io` to open dirs;
  needs an io-acquisition ADR. CLI `--dir` + Zig API cover preopen today.
- **Tier-2 #5** ILP32/watchOS (static-lib target + #97 accommodations).
- **D-313**: realworld `c_sha256_hash.wasm` fixture has a wrong baked hash (zwasm
  is correct vs `shasum`; gate-hole = realworld-run doesn't assert guest stdout) —
  fixture regen + runner-assert deferred.

## State at pause

- **Core Wasm 1.0/2.0/3.0**: 100% spec, 0 skip, 3-host green. **v0.2 features**
  (atomics / wide-arith / custom-page-sizes / relaxed-SIMD) complete + official
  corpora. **WASI 0.1** complete.
- **Component Model + WASI Preview 2** (opt-in `-Dcomponent`): a real Rust
  wasm32-wasip2 component runs e2e (ADR-0170/0175); E1 spec-corpus runner
  (`test/spec/component-model-assert/`); **structural validation** rules 1-4
  (type-index/Canon/alias/ExternDesc bounds — ADR-0176, `feature/component/validate.zig`).
- **Surfaces**: C-API 293/293 gap-free · Zig-API complete · CLI (`run`/`compile`,
  intentionally lean) · memory-safety sound · dogfooded into cw v1.
- **Test iteration**: integration runners build ReleaseSafe (ADR-0177); unit
  `zig build test` stays Debug. `zig build test-all` auto-fast, no flag.
- Debt ledger **52 entries** (D-311 discharged @02965aa6/a0069ce8). `now` = D-299
  only (env-constrained x86_64 W^X). Rest `blocked-by`/`note` = long-tail.

**Parked (demand-driven, NOT this campaign)**: CM deeper conformance
([`component_model_plan.md`](component_model_plan.md)); WASI-P2 sockets; Go/tinygo
proof; 32 `blocked-by` debt (call_ref / future proposals).

## Key refs

- [`docs/handoff_cw_v1.md`](../docs/handoff_cw_v1.md) — consumer-side handoff.
- **ADR-0170** (CM campaign) · **ADR-0176** (component validation) ·
  **ADR-0177** (runners ReleaseSafe) · **ADR-0156** (no release) ·
  **ADR-0174** (windows gate suspend) · **ADR-0153** (rework posture).
- [`component_model_plan.md`](component_model_plan.md) ·
  [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) (D-311 resolved).
