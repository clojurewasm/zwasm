# Phase 9 close — master plan (authoritative)

> **Doc-state**: ARCHIVED-IN-PLACE 2026-05-25 — Phase 9 close work
> 完了; outbound refs from ROADMAP §9 / handover / debt / ADRs cite
> this path so the file stays here (per `doc_state_marker.md` 4-state
> vocabulary). 10.C9 step 4 で flip;
> `scripts/check_phase9_close_invariants.sh` I7 amended to accept
> both `ACTIVE | ARCHIVED-IN-PLACE`;
> `.claude/rules/phase9_close_invariants.md` annotated as
> retirement-eligible per Phase Status widget = `9 | DONE`. Don't
> edit body; cite-only.
>
> **Superseded-portion-by ADR-0109 (Accepted 2026-05-25)**: §1
> deliverable table row 40 reads "c_api / Zig facade full surface
> (TypedFunc / WasiStdio / etc) | YES — deferred to v0.1.0 RC
> (Phase 16)" — that **deferral is OBSOLETE**. ADR-0109 (Accepted
> at Phase 10 open) re-classifies the native Zig facade
> implementation as Phase 10 / ROADMAP §10 / 10.J scope. Body
> text stays as a snapshot of the Phase 9 close decision; for
> current truth see `docs/zig_api_design.md`, ADR-0109, D-075
> (re-scoped to impl tracker), and ROADMAP §10 / 10.J.
>
> **Phase 9 = DONE 2026-05-24** (§9.13 hard gate cleared; widget 9→DONE; commit `36c494a3`). I1-I7 invariants pass mechanically via `scripts/check_phase9_close_invariants.sh --gate` (regression check retained post-DONE). Phase 10 design plan: `phase10_design_plan_ja.md` (r3, amended 2026-05-25 with §3.6 ADR-0109 sub-section + §7 J.* chunk entries)。
>
> **Supersedes**: `phase9_close_plan.md` + `phase9_completion_master_plan.md` +
> `phase9_13_0_close_plan.md` + `phase9_structural_debt_close_plan.md` +
> `phase9_completion_substrate_audit.md` (all archived to
> `.dev/archive/phase9/` 2026-05-22).
>
> **Genesis**: 2026-05-22 user-directed audit (4 subagents) found that
> §9.13-0 + §9.12-F + §9.12-I were prematurely `[x]`-flipped while
> outstanding Wasm-1.0-core MUST-PASS SKIPs existed on Win64, ROADMAP
> exit texts contradicted ADR-0078 / ADR-0102 reality, and the c_api /
> Zig API Wasm-2.0 utilisation tests were absent. User direction: do
> **all** Tier 0/1/2 work IN THIS session before Phase 9 closes; wire
> the remaining work so a fresh session cannot bypass it.

## §1 — Phase 9 honesty principles

Phase 9 is *"Wasm 2.0 (incl. SIMD) literal 100% on 3 hosts (Mac
aarch64 + ubuntunote x86_64 + windowsmini Win64) + scaffolding
sufficient for Phase 10+"* — not a subset, not 2-host-with-skips.

**SKIP legitimacy lens** (per the 2026-05-22 audit):

| Class | Phase-9-legitimate? |
|---|---|
| Wasm 3.0+ proposals (GC / EH / tail-call / typed-func-refs / memory64) | YES — deferred to Phase 10+ |
| WASI 0.1+ envv / preopens / threading | YES — deferred to Phase 11+ |
| c_api / Zig facade full surface (TypedFunc / WasiStdio / etc) | YES — deferred to v0.1.0 RC (Phase 16) |
| **c_api / Zig API Wasm-2.0 utilisation tests** | **NO — must land in Phase 9** |
| Wasm 1.0/2.0 core spec testsuite fixtures (`call_indirect.wast`, `call.wast`, `assert_exhaustion`, `assert_unlinkable`, `assert_trap`, multi-value `type-all-*`) | **NO — must PASS on 3 hosts** |
| "Mechanical implementation with existing precedent in our own code" | **NO — that is workaround-masquerade** |

## §2 — Audit findings (2026-05-22, 4 subagents)

### §2.1 — SKIP-WIN64-* are Wasm-1.0-core MUST-PASS workarounds (Agent 1 + Agent 4)

| SKIP | Count | v1 / wasmtime precedent | Verdict |
|---|---|---|---|
| `SKIP-WIN64-EXHAUSTION` (D-162) | 15 | v1 + wasmtime use **JIT-prologue stack-probe**; hardware EXCEPTION_STACK_OVERFLOW path is bypassed by design (v1 `x86.zig:2708-2722`, wasmtime `func_environ.rs:204-211`) | **WORKAROUND** |
| `SKIP-WIN64-CALL-INDIRECT-TRAP` (D-163) | 10 | Wasm 1.0 core `assert_trap as-call_indirect-last`; wasmtime VEH-AV uniform | **WORKAROUND** (narrow codegen bug, spike-investigate) |
| `SKIP-WIN64-MULTI-RESULT` (D-164) | 3171 | v1 uses `[*]u64 regs` buffer-write entry ABI; wasmtime/cranelift uniform implicit-SRet (`abi.rs:118-135`). Per-shape inline-asm thunks is band-aid not adopted by anyone | **WORKAROUND** |
| `SKIP-NO-LINK-TYPECHECK` (D-157) | 56 | Cross-platform (not Win64-specific); v1 has full check; v2's `instantiate.zig` gap | **GENUINE deferral to Track-D / Phase 10** (ADR-0102 §(c) legitimate) |

**wasmtime test-util** (`crates/test-util/src/wast.rs:59-69, 380-425`)
has **ZERO Windows-conditional skips** for core Wasm 1.0/2.0
fixtures. Industry standard is 3-host equivalent.

### §2.2 — c_api / Zig API Wasm-2.0 coverage gaps (Agent 2)

| Gap | Severity |
|---|---|
| `wast_runtime_runner` is NOT in `test-all` (`build.zig:454`) — c_api Instance path essentially untested | HIGH |
| Wasm-2.0 reftype c_api round-trip (funcref/externref args+results) | ZERO coverage |
| Mixed-export iteration (`wasm_extern_kind` walk over memory/table/global/func) | ZERO coverage |
| Bulk-trap via c_api (`memory.copy` / `table.init` OOB → `wasm_trap_message`) | ZERO coverage |
| Cross-module funcref via `wasm_instance_new` with imports[] | ZERO coverage |
| Zig facade (`zwasm.Runtime` / `Module` / `Instance` / `Value`) per ADR-0025 | NONE implemented |

Phase-9-eligible Zig facade subset = ~100 LOC of thin wrappers.

### §2.3 — Doc/debt/ADR claim-drift (Agent 3)

| Drift | Authority | Drifted side | Sev |
|---|---|---|---|
| B4 | ROADMAP §9.13-0 row 1316 "bit-identical with Mac+ubuntunote" + Phase Status widget "skip-impl == 0 across 3 hosts" | ADR-0078 SKIP-WIN64-* taxonomy reality (3196 skips on Win) | HIGH |
| B14 | ADR-0102 amended §9.12-F exit to per-row predicate (a)(b)(c)(d) | ROADMAP row 1312 still says literal "< 15" | MEDIUM |
| B6 | ADR-0067 ubuntunote pivot | `phase10_transition_gate.md:52` "OrbStack" | MEDIUM |
| B8 | `phase9_completion_substrate_audit.md` gate closed 2026-05-19 | `continue/SKILL.md:960` still registers as hard-gate | MEDIUM |
| B10-12 | git log SHAs | `phase_log/phase9.md:250/252/253` `<this-commit>` placeholders | LOW |
| B13 | Filed ADR Revision rows | 8 `<backfill>` SHA placeholders | LOW |
| B15 | `.dev/archive/phase_gates/` | `continue/SKILL.md` ×3 stale `phase8_transition_gate.md` refs | LOW |

### §2.4 — Workaround-masquerade debt rows (Agent 3 §E)

| Row | Stated barrier | Actual nature |
|---|---|---|
| D-094 | "x86_64 multi-result MEMORY-class ABI unimpl" | mechanical, precedent in D-084 v128 hidden-ptr; "trigger-not-fired" priority deferral |
| D-062 | "arm64 v128 9th+ stack arg" | mechanical, precedent in §9.9 / 9.9-i-1 x86_64 sibling discharge |
| D-164 | "per-shape Win64 inline-asm thunks" | band-aid; v1/wasmtime bypass via buffer-write / uniform implicit-SRet |

## §3 — User's Tier 0 decision (2026-05-22)

> "JIT prologue stack-probe + buffer-write ABI 決心 — v1/wasmtime
> 証拠に基づき D-162/D-164 の設計 ADR を起案して honest に実装"
> "結局全部やるべき。Tier 0+1+2 を完全に綺麗にしてから Phase 9 を閉じる。
> 既存の整理 ⇒ 2 回セルフレビュー ⇒ 新 Phase 9 指示の調査と書き出しと配線
> ⇒ 2 回セルフレビュー。次回クリアセッションから取り組めるように配線"

Concretely:
- D-162: adopt JIT-prologue stack-probe (ADR-0105; v1/wasmtime
  precedent). Supersedes ADR-0103 path-(a) `_resetstkoflw` quick
  fix.
- D-164: adopt **either** (a) buffer-write entry ABI **or**
  (b) uniform implicit-SRet — both Phase-9-scope. ADR-0106 will
  pick one with a rejection rationale for the other and for
  "per-shape inline-asm thunks" (band-aid).
- §9.13-0 / §9.12-F / §9.12-I [x] flips are reverted; Phase 9
  task table reflects actual outstanding work until Tier 1
  fully lands.

## §4 — The 4-phase workflow (this session's plan)

**Phase A: Existing-organization cleanup** (P1-P7 in TaskList)

1. Master plan doc (this file).
2. Archive 4+1 stale close-plan docs → `.dev/archive/phase9/`.
   Add `Doc-state:` 4-state vocabulary (`.claude/rules/`).
3. Fix stale refs (SKILL.md `phase8_gate` ×3, OrbStack, yaml
   sync, phase_log placeholders, ADR SHA backfills).
4. Revert §9.13-0 / §9.12-F / §9.12-I [x] flips per user
   direction "do everything before close".
5. Reframe workaround-masquerade debts (D-094 / D-062 / D-164).
6. Close stale skip-ADRs (`skip_cross_module_action`,
   `skip_embenchen_emcc_env_imports`) per §9.9-III + §9.12-E.
7. Spike cleanup (q3 spikes Status, `win64-recovery-pc-sp/`
   directory delete).

**Phase B: Self-review × 2** (P8)

- Subagent A: walk every audit finding, verify cleanup
  addressed each OR explicitly deferred to Phase D.
- Subagent B: fresh-session dry-run from clean state, confirm
  authoritative source resolution lands on this master plan.

**Phase C: Wire + write new Phase 9 work** (P9-P10)

- ADR-0105: D-162 JIT-prologue stack-probe (Proposed; user flips
  Accepted at §9.13 gate).
- ADR-0106: D-164 multi-result ABI redesign (Proposed; user
  picks (a) buffer-write or (b) uniform implicit-SRet).
- `.claude/rules/phase9_close_invariants.md` (auto-loaded; lists
  the audit invariants).
- `scripts/check_phase9_close_invariants.sh` (FAILs if any
  Phase-9-illegitimate SKIP token still emits; runs at every
  `/continue` Resume Step 0.5b).
- ROADMAP §9.13 row body cites this master plan + the check
  script.
- /continue SKILL.md hard-gate registration reinforced for
  §9.13.

**Phase D: Self-review × 2** (P11)

- Subagent C: fresh-session walkability — a clean /continue
  cannot mark §9.13-0 [x] without satisfying all invariants.
- Subagent D: contradiction sweep — no new claim drift, no
  missing citation, no ADR-vs-rule layering error.

**Phase E: Final handover refresh** (P12)

- handover.md is the canonical fresh-session entry point;
  points at this master plan + the check script.

## §5 — Tier 1 outstanding work (after Phase A cleanup)

Tracked in this section because the rule + check script (Phase C)
auto-load this list. Do not edit elsewhere.

### §5.1 — Win64 codegen redesign per ADR-0105 / ADR-0106

- [x] D-165 close — Win64 internal JIT-to-JIT MEMORY-class
  return ABI + Win64 capture cap=1→2 mirror. Two fixes landed
  together (cycle 9, 2026-05-23):
  - `75f96dee` — caller-side MEMORY-class hidden-RCX / rt-RDX
    shift in `op_call.zig` + `emit_setup.zig`; `op_call.zig:169`
    no longer gates on `abi.current_cc == .sysv`.
  - `99a047f6` — `captureCallResult` gpr_cap/xmm_cap 1→2 on
    Win64 (mirror of R2 `marshalReturnRegs` body-write fix).
    The actual D-165 trigger: `pick0` (2-i64-result register-
    class) had its second result silently truncated, fac-ssa's
    loop logic corrupted, infinite loop in JIT body.
  Verified on windowsmini: full upstream `fac/manifest.txt` (6
  assert_returns + assert_exhaustion fac-rec i64:1073741824) →
  7 passed, 0 failed with `[d-165] kind=4 count=1` (probe fired
  cleanly on exhaustion).


- [x] D-162 close — JIT-prologue stack-probe per ADR-0105
  (`7c1ec732` impl; `2ce381e6` debt close + `b160206b` row
  flip). SKIP-WIN64-EXHAUSTION arm removed. windowsmini
  reconciliation at Phase 9 close boundary.
- [x] D-164 close — multi-result ABI per ADR-0106 path (a)
  buffer-write. Implementation chain cycles 1 → 3e Phase
  2'l (`f8b9eff7` → `17953c9e`). SKIP-WIN64-MULTI-RESULT
  arm removed (`17953c9e`). windowsmini reconciliation
  at Phase 9 close boundary verifies `assert_return
  type-all-*` PASS on Win64.
- [x] D-163 close — Win64 call_indirect trap path. **Closed
  cycle 20** via D-166 fix (`e5042b3e`); root cause shared
  with D-166 (ubuntu memory_grow off-by-one). Both symptoms
  caused by spec_assert_runner_non_simd's `scratch_typeidxs`
  NOT being reset to `maxInt(u32)` sentinel between modules
  → stale typeidx happens to match expected → sig-check
  passes → stale funcptr (= dangling JIT body from freed
  prior module) wild-jump → Mac OK / ubuntu off-by-one /
  Win64 silent process death. Fix at
  `spec_assert_runner_non_simd.zig:251` (`@memset
  scratch_typeidxs[..]=maxInt(u32)` before applyTableInitCtx).
  SKIP arm retired (commit `<this commit>`). Phase 9 close
  invariants 17/18 → **18/18** post-fix. See lesson
  `2026-05-23-d163-d166-shared-root-cause.md`.

### §5.2 — c_api / Zig API Wasm-2.0 utilisation tests

**Idiom note (2026-05-22 idiom-correction)**: c_api tests live as
in-source `test "..."` blocks in `src/api/instance.zig`
(matches existing pattern at lines 1000+). Zig facade tests live
as in-source `test "..."` block in `src/zwasm.zig`. `test/api/`
directory is NOT created; `zig build test` discovers all via
core runner.

- [x] `src/api/instance.zig`: 4 Wasm-2.0 c_api utilisation
  test blocks landed (`a35e0f21`) — reftype round-trip /
  bulk-traps / mixed-exports walk / cross-module funcref.
  I2 invariant green.
- [x] `src/zwasm.zig` facade subset — `Runtime` / `Module` /
  `Instance` / `Value` types + in-source test block
  (`6c4faeea`). I3 invariant green. Closes D-075's
  Phase-9-eligible subset.
- [x] `wast_runtime_runner` smoke step in `test-all` (verified
  at build.zig:616 — landed pre-Phase-9-close).

### §5.3 — Other Phase-9-scope debt close candidates

- [x] D-094 — x86_64 multi-result MEMORY-class indirect-
  result-buffer ABI landed via ADR-0106 cycle 2c (`d0aa6a85`).
  Closed in debt.yaml alongside D-164 (`17953c9e`).
- [x] D-062 — arm64 v128 9th+ stack-arg overflow path closed
  (`d0b3941b` — §9.9-f-3 sibling landed both sides).

### §5.3a — Phase 9 真スコープ expansion (2026-05-23 user audit)

Per ADR-0104 Revision history row 2026-05-23 + 2026-05-23 cycle 9
amendment, 3 debt rows are promoted to Phase 9 真スコープ under
the "Wasm 2.0 complete + Zig/C API complete at Phase 9 release"
rubric. Originally `blocked-by: Track-D` or `v0.1.0 RC`; the user
audit identified them as structurally Phase 9.

**Two-phase iteration discipline** (cycle 9 amend): Mac aarch64
+ ubuntunote x86_64 SysV gate is the per-chunk green target for
each of (D-157 / D-079 (ii) / D-139). Per-chunk windowsmini
reconcile is **NOT** required — ADR-0049 already defers it. The
Win64-specific Wasm-1.0/2.0 surface is already closed (D-162,
D-163, D-164, D-165 all done cycle 9); these 3 remaining rows
touch `runtime/instance/instantiate.zig` + `src/runtime/` globals
shape + `src/api/instance.zig` — host-side library code with no
new JIT codegen, so the Win64 portion is structurally
"recompile-and-PASS" rather than "redesign-per-platform". Final
windowsmini reconcile runs ONCE after all 3 land Mac+ubuntu green
(= "Phase B reconcile" below).

#### §5.3a / Phase A — Mac aarch64 + ubuntunote x86_64 implementation cohort

Order chosen per autonomous-eligibility + ROI:

- [x] **A1. D-157 close** — `assert_unlinkable` non-func import-
  type checking. `runtime/instance/instantiate.zig::
  checkImportTypeMatches` was already complete (line 714,
  pre-cycle); the spec runner's `hasIncompatibleImportType`
  mirror was func-only. Cycle 15 (`6e48e680`) added the
  spectest non-func arm + cross-module helpers
  (`crossModuleGlobalMismatch` / `crossModuleTableMismatch` /
  `crossModuleMemoryMismatch`). Cycle 16 (`bf4edaca`)
  identified + fixed the root-cause gap: the function's
  entry had `const type_sec = module.find(.type) orelse
  return false;` — modules with only non-func imports
  (no type section) early-returned BEFORE the per-import
  loop ran. Fix: optional `types_opt`, consolidated
  spectest into the generic registered-map path. Exit
  criterion achieved on Mac: `SKIP-NO-LINK-TYPECHECK` 56 → 0
  on wasm-2.0 corpus; session passed 25457 / failed 0 /
  skipped 469 (down from 525). ubuntu reconcile via
  ADR-0076 D3 background kick.
- [ ] **A2. D-139 close** — spec_assert bypasses c_api
  `wasm_instance_new` / `setupRuntime` path. Discharge path:
  audit which c_api Instance behaviours (zombie list, arena
  ownership, cross-module Store binding) lack spec-corpus
  coverage; either (a) route spec_assert through c_api OR
  (b) add per-c_api-feature unit fixtures. The §9.12-G
  "minimal c_api Instance-path test coverage" pulled-forward
  subset is `[x]` (via I4 `wast_runtime_runner` smoke); the
  remaining audit + bridge is what §5.3a closes. Per-chunk
  gate: Mac + ubuntu `zig build test` green with new
  in-source `test "..."` blocks in `src/api/instance.zig`
  covering each audited behaviour.
- [ ] **A3. D-079 (ii) close** — v128 cross-module imports via
  `wasm_instance_new` (c_api Instance path). spec-runner
  side already discharged at §9.12-E (`b11314ff`). Discharge
  path: extend `Runtime.globals: []*Value` (ADR-0052 §3
  scalar-only) to v128-aware via per-entry width carried in
  `globals_offsets/valtypes`, then plumb into
  `instantiate.zig` cross-module import wiring. Per-chunk
  gate: Mac + ubuntu `zig build test` green with new
  in-source test in `src/api/instance.zig` exercising v128-
  typed cross-module global import via `wasm_instance_new`.
  Last in this cohort because the `Runtime.globals` refactor
  is widest in scope (intersects ADR-0052 §3 amendment).

#### §5.3a / Phase B — windowsmini reconcile (single shot after Phase A complete)

- [ ] **B1.** After A1 + A2 + A3 all `[x]` and Mac+ubuntu
  test-all green, run `bash scripts/run_remote_windows.sh
  test-all` ONCE. Expected: identical PASS counts (or +N for
  newly-passing assert_unlinkable fixtures); 0
  `SKIP-NO-LINK-TYPECHECK` emission; new in-source c_api
  tests PASS on Win64. If a Win64-specific issue surfaces, it
  is in scope to fix within the same Phase B reconcile (single
  re-iterate); the "redesign per platform" risk is structurally
  low for host-side library code (no JIT codegen change).
- [ ] **B2.** Once B1 windowsmini green: §9.13-0 [x] flip
  (windowsmini full `test-all` green WITHOUT `SKIP-WIN64-*` OR
  `SKIP-NO-LINK-TYPECHECK` emission); §9.12-F + §9.12-I [x] if
  not yet flipped per master plan §6 condition 6; SHA-backfill
  pass for §9.x rows whose Status column is bare.

### §5.4 — Stale ADR / debt cleanup (concurrent with §5.1-§5.3)

- [x] D-007 / D-010 — explicit Phase target already on rows
  (verified 2026-05-23: D-007 Phase 11 WASI envv/preopens;
  D-010 upstream Zig stdlib OR third-site Phase 11+).
- [x] `skip_cross_module_action.md` Status flip (`fca7fe1c`).
- [x] `skip_embenchen_emcc_env_imports.md` Status flip (`fca7fe1c`).
- [x] D-149 SHA backfill — 5 ADR Revision rows backfilled
  (ADR-0078 / 0103 / 0104 / 0105 / 0106). Remaining `<backfill>`
  tokens in `0000_template.md` + `README.md` are legitimate
  convention placeholders.
- [ ] 17 §9.x rows SHA backfill — batch commit at Phase 9 close.

## §6 — Exit predicate (when can Phase 9 actually flip DONE)

Phase 9 = DONE when **ALL** below hold:

1. `bash scripts/check_phase9_close_invariants.sh --gate` exits 0.
2. windowsmini `test-all` green WITHOUT any `SKIP-WIN64-*` token
   emission (i.e., D-162 / D-163 / D-164 closed, runner arms
   removed).
3. c_api / Zig API Wasm-2.0 tests (§5.2 list) all landed +
   green on 3 hosts.
4. `.dev/debt.yaml` has zero `blocked-by:` rows whose stated
   barrier is "trigger-not-fired" for a Phase-9-scope feature
   (D-094 / D-062 closed).
5. ADR-0105 + ADR-0106 Status: `Accepted` (via collab user
   touchpoint at §9.13 hard gate).
6. §9.13-0 / §9.12-F / §9.12-I [x] re-flip with cited
   commit SHAs.
7. §9.13 🔒 Phase 10 entry gate review cleared.
8. Phase Status widget flips `9 | IN-PROGRESS → DONE`.
9. **D-157 closed (§5.3a Phase A1)** — `SKIP-NO-LINK-TYPECHECK`
   0 on Mac + ubuntu (per-chunk gate); also 0 on windowsmini
   after Phase B1 reconcile.
10. **D-079 (ii) closed (§5.3a Phase A3)** — c_api
    `wasm_instance_new` accepts v128-typed cross-module global
    imports without `UnsupportedImport`; paired in-source test
    in `src/api/instance.zig` PASSes on Mac + ubuntu (per-chunk
    gate); also PASSes on windowsmini after Phase B1 reconcile.
11. **D-139 closed (§5.3a Phase A2)** — c_api Instance lifecycle
    audit document filed AND covered by paired in-source tests
    in `src/api/instance.zig`; OR spec_assert routed through
    c_api (whichever path the discharge chooses). Mac + ubuntu
    per-chunk gate; windowsmini after Phase B1.

**Two-phase discipline** (cycle 9 amend): per-chunk gate for
items 9-11 is Mac + ubuntu only (ADR-0049 windowsmini deferral
applies); a single `bash scripts/run_remote_windows.sh test-all`
runs AFTER 9-11 all complete to verify the Win64 host side. This
keeps the iteration loop fast (10-15 sec/iter on Mac instead of
8-15 min/iter via windowsmini round-trip) while still enforcing
the 3-host invariant at Phase 9 close. Justified because the
remaining surface is host-side library code (instantiate /
Runtime.globals / c_api Instance) — no new JIT codegen
introducing per-arch divergence. If a Win64 issue surfaces in
the final reconcile, it's in scope to fix in the same Phase B
window before §9.13-0 [x] flip.

## §7 — Anti-patterns to NOT repeat

Lessons from this session's audit:

- **No premature [x] flip** when row exit text describes a state
  the code doesn't actually achieve.
- **No "blocked-by: trigger-not-fired"** as a permanent dismissal
  — if mechanical precedent exists in our own code, that's
  workaround-masquerade.
- **No SKIP-token taxonomy expansion** to legitimise Wasm-1.0-core
  fixture failures. Each new SKIP must be paired with: (a) ADR
  classifying it as truly out-of-Phase-9-scope, OR (b) a debt
  row + named-design-ADR path to close.
- **No row-text vs ADR-amendment drift** — if an ADR amends a
  ROADMAP row's exit criterion, the row TEXT must cite the
  ADR (or be updated in-place) at the same commit.

## §8 — Fresh-session entry point

A new session reads:

1. `CLAUDE.md` (auto-printed by `SessionStart` hook)
2. `.dev/handover.md` (auto-printed, points HERE)
3. **This file** — authoritative remaining-work source
4. `.claude/rules/phase9_close_invariants.md` (auto-loaded;
   Wasm-2.0-core SKIP forbidden list)
5. `scripts/check_phase9_close_invariants.sh` (runs at /continue
   Resume Step 0.5b — FAILs surface immediately)

A fresh session cannot mark §9.13-0 [x] without satisfying the
exit predicate in §6.

## §9 — Termination criteria for this file

Archive this file (move to `.dev/archive/phase9/2026-XX-XX-phase9_close_master.md`)
when:

- Phase 9 = DONE (per §6 predicate).
- handover.md no longer references this file.
- §9.13 [x] flipped with user collab approval.

Until then this file is **load-bearing** and must not be
silently edited — any deviation requires §18 ADR procedure.
