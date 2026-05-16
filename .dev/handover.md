# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).

## Active state — **Phase 9 close-readiness day (2026-05-17): debug infra + scaffolding + Windows reconcile in flight**

### One-line state

Spec_assert / simd_assert on Mac aarch64 + OrbStack:
**24001/0/2069 + 13301/0/440 bit-identical** (unchanged since
d-85). Today's work focused on Phase 9 close readiness (NOT
chunk-N+1):

- **Debug infra** committed `d3f2a1a7` + `24388587`: lesson
  template + `<backfill>` lint + invariant-comment lint +
  heisenbug streak tracker + spike skeleton/audit + JIT crash
  Recipe 7; 4 rules' frontmatter; orphan-script wiring into
  gate_commit + audit_scaffolding CHECKS §F.3a / §G.3 / §G.4 +
  continue/LOOP.md heisenbug-tracking subsection.
- **Pre-commit gate re-activated** (`66c699e7`): ADR-0063
  (uniform-pattern catalog file-size exemption — entry.zig
  exempt marker) + ADR-0064 (runner.zig 2178 → 1968 LOC via
  `runner_validate.zig` split) + check_skip_adrs.sh `set -e`
  bug fix (skip_host_state_diverged auto-discharged) +
  flake.nix shellHook auto-sets `core.hooksPath .githooks`.
  All commits from this point flow through `.githooks/
  pre-commit → gate_commit.sh`.
- **Debt sweep** (`83e80150`, `e9e04ac9`): D-095 closed
  (call-crossing regalloc fully discharged); D-052 flipped to
  `now` (barrier dissolved: x86_64/emit.zig 1893 LOC > 1000
  trigger); D-135 filed (ADR-0063 Alternative B follow-up —
  comptime-generate entry.zig).
- **Lesson Citing backfill** (`23b4d20d`): 2 lessons resolved
  (e4e74931 + a58a2ba5/87783496); `check_lesson_citing.sh`
  now OK.
- **windowsmini D-084 reconcile** (in flight 2026-05-17):
  surfaced 2 Windows-compat bugs already fixed —
  `installSigsegvHandler` Win64 gate (`14147194`) +
  `sigsetjmp`/`siglongjmp` Windows stubs (`2edfdef1`). Retry
  #3 running; pre-error tallies showed 9 runners green
  (simd_assert 13301/0/440 **bit-identical with Mac+OrbStack
  + Windows!**, wast_runner 1158+72, wast_runtime_runner
  266+5, realworld 55, wasi 2, edge-case 40, spec_runner
  9+3+212).

**Cumulative d-74 → d-85 (13 chunks)**: **+217 PASS**
(23784 → 24001). spec_assert PASS counter unchanged today
(no chunk progression).

### Skip-impl drainage roadmap (post-d-85)

**Remaining skip-impl 1573 is now PURELY structural**. All
solvable VALIDATOR-GAP / PARSER-GAP entries drained. What's
left blocks on Phase 10+/11+ scope decisions:

- **SKIP-CROSS-MODULE-IMPORTS** 136 — Phase 10+ instance-aware
  runtime + cross-module registry.
- **multi-result family** ~1400 directives covered by manifest
  `skip-impl multi-result` lines (br/block/call/exports/func/
  if/loop) — Phase 11+ multi-value entry helpers + runner
  dispatch ladder extension. JIT-side multi-result return
  marshal already supports it per D-093 (ARM64 emit.zig
  marshalFunctionReturn); the bottleneck is runner-side
  entry.zig helpers + distiller's `supported` set.
- **SKIP-NO-LINK-TYPECHECK** 4 / **SKIP-START-TRAP** 2 /
  **SKIP-HOST-IMPORT** 2 — Phase 10+ cross-module host-import
  binding.

### Next loop candidates

Genuinely productive next-chunk options when /continue resumes:

- **Multi-result entry helpers** (Phase 11 scope per handover
  but technically Wasm 2.0 → §9.9 scope per ADR-0056):
  bundle ~6 new entry helpers `callI32I32_void`,
  `callI32I32_i32`, `callI64I32_i64i32`, ... + runner dispatch
  arms + distiller `supported` set expansion. Single chunk
  could drain ~50-100 directives.
- **D-052** (x86_64 prologue.zig extract) — barrier dissolved
  (emit.zig at 1991 LOC > 1000 soft cap), discharge path
  spelled out in D-055 (~50 test-site migration alongside
  prologue extract + 5-line emit.zig sentinel wire-up). Sets
  up D-081 rename + Linux/Windows x86_64 differential signal.
- **D-095** regalloc call-crossing — ~150 LOC + ADR for the
  policy decision (callee-saved bias for call-crossing
  vregs).
- **D-133 mechanical sweep** — non-trivial since several sites
  use >2 simultaneous scratch regs; needs ABI extension to
  add another non-allocatable emit-scratch slot (X16/X17 are
  reserved for intra-proc-call). Risk: latent issue, no
  current trigger.
- **D-134 OrbStack heisenbug** — TWO consecutive D-134-silent
  runs (d-84 + d-85) suggest the d-72 instrumentation + d-68
  Zig-handler disable may have actually fixed the root cause
  via cumulative layout-related rate reduction. Discharge
  candidate after a few more clean runs (criterion: 5+
  consecutive zwasm-spec-wasm-2-0-assert exit-0 on OrbStack).

§9.9 row text "skip-impl == 0" exit criterion is now blocked
strictly by Phase 10+/11+ scope per ADR-0056. The substrate-
audit hard gate at row 9.12 (ADR-0062) is the natural
collaborative re-engagement point for §9.9 exit interpretation
— that conversation is the right next user dialogue.

PARSER-GAP (19): binary 8, binary-leb128 7, custom 4 —
needs LEB128 over-long encoding rejection. Tractable but
spec-text-sensitive.

## Outstanding (now-resumed) `now` debts

- **D-134** OrbStack flake — instrumented at d-72;
  awaits next failure to surface (iii-b) signal-mask
  evidence. Continued proactive probing is wheel-
  spinning until then.
- **D-095** partial / **D-126** Phase 10+ / **D-133**
  substrate audit Q5 — gated.

### Phase 9 / §9.9 status

- spec_assert non-simd: 23784/0/2286 Mac aarch64
  (1790 skip-impl + 496 skip-adr).
- simd_assert: 13301/0/440 Mac + OrbStack
  (bit-identical).
- §9.9 row text exit criterion **not literally met**
  (skip-impl ≠ 0); needs ADR (above).

### Active `now` debts (28)

- **D-095** partial — substrate audit Q5 scope.
- **D-126** — Phase 10+ instance-aware refactor scope.
- **D-133** — substrate audit Q5 scope.
- **D-134** — instrumented heisenbug; awaits next
  failure with d-72 diagnostic in place.

### Phase 9 / §9.9 status

- spec_assert non-simd: 23784/0/2286 Mac aarch64
  (1790 skip-impl + 496 skip-adr).
- simd_assert: 13301/0/440 Mac + OrbStack (bit-identical).
- §9.9 closing path: still gated by D-134 (OrbStack
  flake; d-68 reduced rate via Zig-handler-disable but
  d-69 re-triggered via layout perturbation).
- Substrate audit hard gate at row 9.12 fires once 9.9
  flips `[x]`.

### Active `now` debts

- **D-095** (partial; substrate audit Q5 scope).
- **D-126** (bulk corpus residual — Phase 10+ scope).
- **D-133** (remaining ≥3-scratch op_table/op_memory
  sites — substrate audit Q5 scope).
- **D-134** (OrbStack `zwasm-spec-wasm-2-0-assert` flake;
  layout-sensitive + handler-install-race-sensitive;
  d-68 disabled Zig's startup SEGV handler but the
  heisenbug still reproduces at low rate).

### Closing path (post-d-74 user redirect)

User has redirected the loop to drain solvable
skip-impl. The next chunks (d-75+) target the remaining
SKIP-VALIDATOR-GAP / SKIP-PARSER-GAP families per the
roadmap above. Once skip-impl reaches its structural
floor (multi-result Phase 11+ scope + SKIP-CROSS-MODULE-
IMPORTS Phase 10+ scope), the §9.9 exit-criterion
interpretation question can be revisited collaboratively.

## Sandbox quirks + hook scope

- `~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- OrbStack daemon log-rotation panic — restart via
  `pkill -9 -f OrbStack && open -a OrbStack`.
- Per-chunk 2-host (Mac+OrbStack) per ADR-0049;
  windowsmini reconcile at §9.9 close (D-084 per
  ADR-0055).

## Reference chain

- `.dev/decisions/0057_spec_assert_runner_factoring.md`.
- `.dev/decisions/0058_table_ops_jit_design.md`.
- `.dev/decisions/0059_jit_memory_grow_callout.md`.
- `.dev/decisions/0060_regalloc_call_crossing_force_spill.md`.
- `.dev/decisions/0061_wasm_3_0_deferral_policy.md`.
- `.dev/decisions/0062_phase9_substrate_audit_gate.md`.
- `.dev/phase9_completion_substrate_audit.md` (hard gate
  9.12 document).
- `.dev/lessons/2026-05-16-narrative-claim-vs-landed-state.md`
  (d-68 / d-69 retrospective on overoptimistic
  "DISCHARGED" claims).
- `.dev/phase_log/phase9.md` (per-sub-chunk records).
