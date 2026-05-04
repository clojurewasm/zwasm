# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0017_jit_runtime_abi.md` — JitRuntime ABI (X0
   = `*const JitRuntime`); D-014 dissolve.
3. `.dev/decisions/0018_regalloc_reserved_set_and_spill.md` —
   pool/reserved separation + first-class spill.
4. `.dev/decisions/0019_x86_64_in_phase7.md` — x86_64 backend
   pulled into Phase 7; Phase 8 redefined as optimisation foundation.
5. `.dev/decisions/0020_edge_case_test_culture.md` — boundary
   fixture culture + rule + audit hooks.
6. `.dev/debt.md` — discharge `Status: now` rows before active task.
7. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — autonomous loop RUNNING

- **Phase**: Phase 7 IN-PROGRESS, scope expanded per ADR-0019
  (ARM64 + x86_64 baseline both in Phase 7; §9.7 = 7.0..7.12).
- **Last commit**: `7b5c4fe` — Step 4 sub-7.5c-iv (liveness
  extension for branches; first branchy Wasm 1.0 fixture
  end-to-end via JIT). Full Wasm 1.0 structured-CFG surface
  now JIT-compileable. 741/741 unit + 16/16 edge-case /
  3-host green. Sub-7.5c-v (wast iteration via existing spec
  corpus) NEXT.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active plan — implementation cycles after ADR acceptance

Sequence agreed during 2026-05-04 redesign dialogue. Each Step
below corresponds to one or more `/continue` cycles.

| # | Step | ADR | Status |
|---|------|-----|--------|
| 1 | regalloc pool: remove X24..X28; add `reserved_invariant_gprs`; `Slot` union with first-class spill | 0018 | **DONE** — sub-1a `1d6d178`, sub-1b `7e880b8`, sub-1c `394e416` |
| 2 | JitRuntime struct + ABI: X0 = `*const JitRuntime`, prologue LDRs invariants, entry-frame collapses to standard fn-ptr call | 0017 | **DONE** — sub-2a `0827b89`, sub-2b+2c `44b94a0`, sub-2d-i `10ab46d`, sub-2d-ii `0010a03`. **D-014 dissolved.** |
| 3 | Edge-case test culture: rule + Step-4 hook + audit §I; bootstrap p7 fixtures | 0020 | **DONE** — sub-3a `52efba4` (rule), sub-3b `b787b19` (audit + hook), sub-3c `36b9ed8` (7 fixtures) |
| 4 | §9.7 / 7.5 spec testsuite via ARM64 JIT (was 7.4d; renumbered per ADR-0019) | — | 7.5a/b/c-i/ii/iii landed; 7.5c-iv `7b5c4fe` (branch liveness; 16/16 fixtures); **7.5c-v (wast iteration via existing spec corpus) NEXT**; 7.5c-vi (broader entry sigs); 7.5c-vii (close to pass=fail=skip=0) |
| 5 | §9.7 / 7.6 + 7.7 + 7.8: x86_64 reg_class/abi + emit + spec gate | 0019 | After Step 4 |
| 6 | §9.7 / 7.9–7.12: realworld ARM64 + x86_64, three-way differential, audit + open §9.8 | — | After Step 5 |
| 7 | emit.zig responsibility split (no ADR; opportunistic) | — | After Phase 7 close |

## Implementation notes for the next cycle (Step 1 = ADR-0018)

- Concrete edits:
  - `src/jit_arm64/abi.zig`: `reserved_invariant_gprs = [_]Xn{24,25,26,27,28}`; `allocatable_gprs = caller_saved_scratch ++ [X19..X23]` (12 slot pool).
  - `src/jit/regalloc.zig`: `Slot = union(enum) { reg: u8, spill: u32 }`; rename `n_slots` → `n_reg_slots`; add `n_spill_bytes`.
  - `src/jit_arm64/emit.zig`: ~70 sites consume `alloc.slots[v]` — match on `Slot` tag; spill emit via STR/LDR through scratch reg (X15 reserved per ADR-0018 recommendation to avoid X16/X17 conflict with sub-g3c).
  - Add a unit test forcing ≥12 vregs to exercise spill paths.
- Pre-cycle Step 0 survey: regalloc2 (`~/Documents/OSS/regalloc2`) + wasmtime/cranelift register-class spill patterns.

## Open structural debt (post-ADR-acceptance state)

- **D-014** Runtime injection — Step 2 dissolves via ADR-0017.
- **D-022** Diagnostic M3 / trace ringbuffer — sub-f trap surfaces
  exist; revisit after Phase 7 close.
- **D-026** env-stub host-func wiring — 4 embenchen + 1
  externref-segment skip-ADR'd; cross-module dispatch.
- regalloc/reserved overlap — Step 1 dissolves via ADR-0018.
- 3-host JIT asymmetry — Steps 5 dissolves via ADR-0019.

## Recently closed (per `git log`)

- §9.7 / 7.3 op coverage CLOSED (111 ops total): width / convert /
  trunc-trap / sat-trunc / reinterpret all landed.
- §9.7 / 7.4a/b/c JIT runtime infra: jit_mem (`1e71b53`) + linker
  (`3e34d1a`, first JIT-to-JIT call) + entry frame (`93e2f2c`,
  i32.load through X28 verified end-to-end).
- ADRs 0017/0018/0019/0020 drafted, self-reviewed, accepted.

## Phase 6 close — archival snapshot

- 14 §9.6 rows all [x] with SHA. 2 active skip-ADRs (5 fixtures).
- 14 active debt rows, all `blocked-by:` named barriers.
- 2 lessons recorded. v1-class hyperfine baseline at Phase 6 close
  (26 fixtures: 9 shootout + 11 TinyGo + nbody + 5 cljw).
