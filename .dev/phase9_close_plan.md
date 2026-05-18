# Phase 9 close plan

> **Status**: Active — work item for the next session(s). Compiled
> at the end of 2026-05-17 close-readiness discovery cycle.
>
> **Read order on session start**: handover.md → THIS DOC → §6
> work sequence → start step (a). Do NOT autonomously pick a
> `§9.<N>` sub-chunk from ROADMAP until step (a) lands the
> amendment cycle — the ROADMAP needs correction before any
> further code chunks are appropriate.
>
> **This doc is not itself load-bearing for code behaviour**
> (per ROADMAP §18: it doesn't change validator / parser / JIT /
> runtime semantics). The amendments it prescribes ARE
> load-bearing and ship per the sequence in §6.

## §1 Discovery summary — 2026-05-17 close-readiness cycle

Today's work focused on Phase 9 close-readiness (no chunk
progression on spec_assert PASS counter, which stayed at
**24001/0/2069 Mac+OrbStack bit-identical** since d-85 close).
Three structural findings surfaced:

1. **Debug-infra gap closure** (commits `d3f2a1a7`, `24388587`):
   debug_jit_auto Recipe 7 + lesson template + 4 lints +
   heisenbug discharge rule + spike skeleton/audit + rules
   frontmatter + script wiring into gate_commit + audit_scaffolding
   CHECKS §F.3a / §G.3 / §G.4 + continue/LOOP.md heisenbug-tracking
   subsection.

2. **Pre-commit gate reactivated** (commit `66c699e7`):
   - ADR-0063 (uniform-pattern catalog file-size exemption) for
     `entry.zig`'s 84 helpers (2111 LOC under the exempt cap)
   - ADR-0064 (`runner.zig` split → `runner_validate.zig`,
     2178 → 1968 LOC)
   - `check_skip_adrs.sh` `set -e` pre-existing bug fix +
     skip_host_state_diverged auto-discharged
   - `flake.nix` shellHook auto-sets `core.hooksPath .githooks`
   - Every commit from this point flows through the now-active
     pre-commit hook

3. **§9.9 exit-criterion principled re-interpretation** (this
   doc): a focused user discussion produced the corrected
   "あるべき論" framing that the next session must execute.

In parallel:

- `windowsmini` D-084 reconcile attempt (3 retries) surfaced
  two Windows-compat bugs — both **fixed** (commits `14147194`
  Sigaction Win64 gate; `2edfdef1` sigsetjmp/siglongjmp stubs;
  `7976dc00` TODO(D-136) markers). Post-fix windowsmini state:
  35/37 test-all steps green; `simd_assert_runner` bit-identical
  with Mac+OrbStack; only `spec_assert_runner_non_simd` crashes
  mid-corpus at exit 253 due to D-136 (Win64 SEH bridge
  missing).

- D-095 closed (regalloc call-crossing discharge confirmed,
  commit `83e80150`).
- D-052 flipped to `now` (barrier dissolved — emit.zig 1893 LOC
  past trigger).
- D-135 filed (comptime-generate entry.zig — ADR-0063
  Alternative B follow-up).
- D-136 filed (Win64 SEH bridge for assert_trap recovery).

## §2 The four-category interpretation of skip-impl

The remaining skip-impl 1573 (Mac+OrbStack) is NOT uniform. It
breaks into four categories with different principled status:

| Cat | Description | Today | Phase 9 owns? |
|---|---|---:|---|
| **I** | Validator / parser spec-rule enforcement | **0** | YES — core |
| **II** | Spec-test harness (multi-result entry helpers) | ~1400 | YES — driver scope |
| **III** | Runtime instance binding (cross-module / host imports / start-trap / link-typecheck) | 144 | **YES** (corrected — see §3) |
| **IV** | Host-platform recovery bridge (Windows SEH for assert_trap) | windowsmini-specific | YES (Phase 9 batch-end sweep) |

The literal `skip-impl == 0` on Mac+OrbStack means **Cat I/II/III
each at 0**, plus windowsmini-side ≤ Cat I/II/III + Cat IV
batch-resolved at Phase 9 end.

## §3 Cat III was a ROADMAP misclassification

ROADMAP §1/§2/§11 + ADR-0056 placed cross-module instance
binding into "Phase 10+ instance-aware runtime" scope on the
basis of **implementation weight**, not specification scope.

**User-confirmed correction (2026-05-17)**:

> Cat III は Wasm 1.0 core 機能。`(register "M" $inst)` +
> cross-instance import は Wasm 1.0 仕様の一部。Phase 10 まで
> 遅延すべきでなかった。気付いたいま、Phase 9 のうちにやる
> べきだし、Wasm 2.0 完備項目にも含めるべき。ロードマップを
> 修正必要。

Concretely:

- Wasm 1.0 core spec §4.5 (Instances, Stores, Imports, Linking)
  is base spec. Wasm 1.0 completeness without this is partial.
- spec testsuite has used `(register ...)` since Wasm 1.0; the
  directive being skipped in our corpus means we don't run those
  Wasm 1.0 assertions.
- Our Phase 1-8 completed validator / JIT-codegen / interp while
  leaving Module / Instance / Store linker work for later. This
  is a layering-order judgment that was OK during build-up but
  is **dishonest as a "Wasm completeness" claim** at Phase 9
  close.

Therefore the ROADMAP needs amendment to pull Wasm 1.0 instance
work into Phase 9 scope, leaving Phase 10 with the Wasm 3.0
proposal work only (GC / EH / tail-call / memory64).

## §4 Architectural tension (honest acknowledgement)

The `-Dwasm=1.0 / -Dwasm=2.0` build-flag separation prescribed
by ROADMAP §4.6 / §A12 is **not populated in code today**:

- `ZirOp` enum is fully declared day-1 (Wasm 1.0 + 2.0 + slots
  for 3.0) per ROADMAP §P13.
- `DispatchTable` shell exists but is empty; per-op handlers go
  directly through `switch (ZirOp)` arms in lower.zig /
  validator.zig / arm64/emit.zig / x86_64/emit.zig.
- No `build_options.feature_X` comptime branching is in effect.

Substrate audit (9.12, ADR-0062) is the gate that decides whether
this stays this way, gets back-filled to DispatchTable, or moves
to a hybrid (per-op file + comptime-generated inline switch).

**Cat III work is largely orthogonal to this decision**:
runtime/instance/store/linker is a runtime *layer* whose
internals are independent of opcode-dispatch architecture. The
work can proceed without waiting on substrate audit; if
substrate audit later picks (B) or (C), the instance layer code
likely doesn't need re-shaping.

**Risk to manage during Cat III work**: do not re-derive the
substrate-audit-Q5 hygiene violations (comment-as-invariant,
single-slot-dual-meaning, copy-from-v1, etc.). Apply
`.claude/rules/*.md` discipline strictly during instance work.

## §5 Final position (the position the next session implements)

`skip-impl == 0` at §9.9 close means **literal 0** across all
four categories on Mac + ubuntunote + windowsmini (Linux x86_64
host pivoted from OrbStack per ADR-0067, 2026-05-17). Cat III is
Phase 9 scope per ROADMAP correction. Cat IV is Phase 9
batch-end sweep (windowsmini reconcile), not a separate Phase.

What stays out of Phase 9 (legitimately):

- WasmGC (struct.new, array.new, ref.cast, sub-typing) — Wasm 3.0
- Exception handling (try_table, throw, catch) — Wasm 3.0
- Tail calls (return_call, return_call_indirect) — Wasm 3.0
- memory64 (i64-addressed memory) — Wasm 3.0
- Multi-memory (≥ 2 memories per module) — Wasm 3.0
- Typed function references — Wasm 3.0
- Build-flag separation populate (`-Dwasm=1.0`) — substrate
  audit decision dependency

## §6 Work sequence — execute in order

### Step (a) — Amendment cycle (do this FIRST)

**Goal**: lock in the principled scope correction in load-bearing
documents.

Sub-steps (chunk-granularity each; can land as multiple commits):

1. **Draft ADR-0065** — `Wasm 1.0 instance work Phase 9 re-scope`
   - Context: enumerate today's Cat III discovery + the §3 above
     reasoning
   - Decision: Phase 9 scope absorbs Wasm 1.0 instance / store /
     linker / cross-module dispatch / host import binding /
     start-trap recovery
   - Alternatives considered:
     - (i) Keep Cat III in Phase 10 + ADR-0056 amend excluding it
       from §9.9 exit — REJECTED: dishonest about Wasm 1.0
       completeness
     - (ii) Open new Phase 9.5 dedicated to instance work —
       REJECTED: distorts Phase Status widget semantics
     - (iii) Defer entire §9.9 close decision until substrate audit
       lands — REJECTED: §9.9 substrate work and Cat III
       implementation work are orthogonal layers
   - Consequences:
     - Phase 9 scope expands by Wasm 1.0 instance layer
     - Phase 10 scope purifies to Wasm 3.0 proposals
     - substrate audit Q5 hygiene rules apply to Cat III work
     - debt rows that cited "Phase 10+ instance-aware runtime" as
       barrier need re-evaluation (D-079 v128 imports, D-126
       bulk.wast, etc.)
   - References: this doc, ADR-0056, ADR-0062 substrate audit

2. **Amend ADR-0056** (Revision history row 2026-05-17)
   - Reinterpret `skip-impl == 0` per the 4-category framing
   - Cite ADR-0065 for Cat III absorption
   - State the windowsmini end-of-Phase-9 batch reconcile
     interpretation explicitly (consistent with ADR-0049 /
     ADR-0055 per-chunk-deferring policy + this doc §3)

3. **ROADMAP edits** (per §18.2 — load-bearing, ADR-0065 cite required):
   - §1 / §2 P/A entries: re-state Phase 9 scope boundary to
     include Wasm 1.0 instance work
   - §9 Phase Status widget: no change (Phase 9 stays
     IN-PROGRESS)
   - §9.9 row text: replace with the new 4-category exit
     predicate (cite ADR-0056 amend + ADR-0065)
   - §9.9 sub-task table: add new rows for Cat II / Cat III /
     Cat IV discharge sub-chunks
   - §11 layers: no change (the layer architecture stays; what
     changes is when the runtime-instance layer is fully
     populated)

4. **Debt ledger re-evaluation**:
   - D-079 (v128 cross-module imports): barrier "Phase 10+
     cross-module import-aware chunk schedule" dissolves — flip
     to `now`
   - D-126 (bulk.wast call_indirect post-mutation): named
     "Phase 10+ structural refactor" — re-evaluate; likely now
     in Phase 9 scope
   - D-082 sub-rows (cross-module fixtures): re-evaluate barriers
   - D-026 (embenchen emcc env imports): re-evaluate
   - D-074 (Phase 11 cohort prep): some items may move into
     Phase 9 close

5. **Substrate audit doc** (`.dev/phase9_completion_substrate_audit.md`):
   - Note Cat III work proceeds without waiting on Q3
     architecture decision
   - Q5 hygiene anchors extended: invariant-comment lint +
     debug discipline applies to new instance-layer code

6. **handover.md refresh** — point at Cat II / Cat III / Cat IV
   chunk progression after amendment cycle closes.

### Step (b) — Cat II: multi-result entry helpers [PARTIAL]

**Status**: chunks b-1..b-5 landed (2-result int + HFA f64+f64
shapes covered). Manifest-level skip-impl multi-result dropped
from 48 → 17 lines. Residual 17 lines all blocked by the
D-094 + D-137 + D-140 ABI cohort:

- 7 lines: pure 3-int-result `(i32,i32,i32)` / `(i32,i32,i64)`
  shapes — D-094 (SysV >2 GPR truncation) + the arm64 sibling
  `extern struct` ≥ 24 B → X8 indirect-result-ptr gap.
- 8+ lines: mixed int+float 2-result — D-137 (callconv(.c)
  packs i32+f64 into GPR pair but JIT writes i32→W0 + f64→D0;
  HFA/mixed-class register layout needed).
- 1 line: `large-sig` 16-result — D-140 (indirect-result-ptr
  ABI for >16-byte struct returns; AAPCS64 X8 / SysV RDI).

§9.9-II row close requires discharging the D-094 + D-137 +
D-140 cohort (multi-commit project: ADR amendment +
caller/callee marshal + entry-helper bridge). Schedule TBD.

**Goal (historical)**: drain ~1400 multi-result directives to 0.

Pre-work survey already done (2026-05-17):
- 48 manifest-level `skip-impl multi-result` lines
- Spread across func (20), if (14), call (6), br (2), block (1),
  loop (1) corpora
- Highest occurrence: `add64_u_with_carry` =
  `(i64, i64, i32) → (i64, i32)` (8 manifests)
- ~6-8 unique result-tuple shapes cover 90%+ of corpus

Per-shape work (~1 chunk each, possibly bundleable):

- Define `extern struct FuncRet_<types>` in `entry.zig`
- Add `callXX_yy() Error!FuncRet_<types>` helper
- Add `dispatchMultiResult<shape>(...)` arm in
  `spec_assert_runner_non_simd.zig`
- Add `(arg_kinds, result_kinds_tuple)` entry to the distiller's
  `supported` set in `scripts/regen_spec_2_0_assert.sh`
- Re-bake manifests via the distiller; verify PASS-count gain

Expected sequence (highest impact first):

1. `(i64, i64, i32) → (i64, i32)` — add64_u_with_carry family
2. `() → (i32, i32)` + `(i32) → (i32, i32)` — multi family
3. `() → (i32, i64)` — type-i32-i64, break-br_if-num-num
4. `() → (i32, f64)` — type-all-i32-f64, value-i32-f64
5. `(i32) → (i32, i32, i64)` — break-multi-value
6. `() → (i32, i32, i32)` — value-i32-i32-i32, return-i32-i32-i32
7. Remaining long tail (f32+i64, f64+i32, etc.)

Per-chunk gates: Mac+ubuntunote file-logged parallel pipeline
(per ADR-0049 + ADR-0067) + verify simd_assert / wast_runner
remain green / spec_assert PASS-count delta as expected.

### Step (c) — Cat III: Wasm 1.0 instance work [DONE 2026-05-18]

**Status**: §9.9-III row `[x]` cycle 5 (commit `2dbd3f15`).
Drain target satisfied: Mac aarch64 25308/0, ubuntunote x86_64
24034/0 (= 0 FAIL across 144 directives) with γ-4 relax
PERMANENT.

Closure chain (commit-order):
- α/β/γ/γ.2/γ.3 (ADR-0068 chunks) — dual-view table storage
  fix; D-126 closure
- γ.4 cycle 4 (commit `b137a44b`) — bridge thunk 56 → 96 B
  (ADR-0066 §A2; full pinned reserved-invariant cohort save);
  D-144 closure
- cycle 5 (commit `2dbd3f15`) — §9.9-III `[x]` flip

**Goal (historical)**: drain 136 + 4 + 2 + 2 = 144 cross-module /
host / start-trap / link-typecheck directives to 0.

Pre-survey BEFORE implementation (Step 0 per /continue
discipline):

- Read `~/Documents/MyProducts/zwasm/` v1 instance / store /
  linker (read-only; **no copy-paste** per `no_copy_from_v1.md`)
- Read `~/Documents/OSS/wasmtime/crates/runtime/` instance
  binding shape
- Read `~/Documents/OSS/zware/src/` Zig-idiomatic store/instance
- Read `~/zwasm/private/v2-investigation/` for prior framing
  notes
- Capture under `private/notes/p9-cat3-instance-survey.md`

Likely sub-chunks:

1. **Store + Instance registry** — `Store` type with a
   `register(name, *Instance)` API mirroring spec semantics
2. **Cross-module import linker** — at instantiation time,
   resolve each `(import "M" "f" ...)` against the registered
   instance map; verify import-type matches export-type
   (`link-typecheck` cases)
3. **Cross-module call dispatch** — make funcref refer to its
   originating instance; `call_indirect` through a table entry
   that was populated from another module's exports works
4. **Host import binding (spectest)** — `print_i32`, `print_f32`,
   etc. — bind to runner-provided host function pointers
5. **Start-trap propagation** — if start function traps,
   instantiation fails with the trap surface'd
6. **spec_assert runner update** — implement `(register ...)`
   directive handler; instance map per test session

Each sub-chunk: 3-host gate, spec_assert PASS delta verification.

### Step (d) — Cat IV: windowsmini batch sweep [RELOCATED to §9.13-0]

**Status (2026-05-18)**: Per user 2026-05-18 confirmation +
ADR-0049 + ADR-0056 + ADR-0065 2026-05-18 amendments, the Cat
IV windowsmini reconcile sweep moves OUT of §9.9 close gate
INTO a dedicated ROADMAP row §9.13-0 (between §9.12 substrate
audit hard-gate and §9.13 Phase-10 entry hard-gate).

Rationale: §9.12 substrate audit may amend Phase 9 scope
retroactively (e.g., reshape D-094 / D-140 cohort decisions or
loosen invariants); running Cat IV reconcile BEFORE the
cleanup risks duplicate work + wasted windowsmini cycles.

**Step (d) is therefore NOT part of §9.9 close.** It executes
at §9.13-0 as a separate sequence in §6 (or as an inline
extension of §6 Step (e) below).

Items + sequence (unchanged content; moved venue):
- D-084 Win64 v128 marshal residual (per ADR-0055)
- D-136 Win64 SEH bridge for assert_trap recovery
- D-028 windowsmini SSH test-runner IPC flake re-eval
- Any Windows-platform-specific issues surfacing from
  Cat III or §9.12 substrate audit cleanup
- Plus: any deferred (b)-d-7 Win64 Class B thunks (per
  ADR-0069 Phase 1.5)

Sequence: inventory → pick implementation → land in batch →
windowsmini full test-all green bit-identical with Mac +
ubuntunote = §9.13-0 [x].

### Step (e) — Phase 9 close

**Goal (revised 2026-05-18)**: §9.9 row flips `[x]` with
Cat I + Cat II + Cat III green on Mac + ubuntunote (Cat IV
moved to §9.13-0 per Step (d) note above). The substrate
audit hard-gate at §9.12 fires (per ADR-0062), and the
autonomous loop **stops** to surface the substrate audit
document for collaborative review.

Tasks:

1. `audit_scaffolding` invocation (Phase 9 boundary mandatory)
2. SHA backfill for §9.9 sub-task rows
3. §9.9 row flip `[x]` (Mac + ubuntunote bit-identical at
   `skip-impl == 0` for Cat I + II + III)
4. ROADMAP Phase Status widget: §9.9 [x] but Phase 9 stays
   IN-PROGRESS until §9.13-0 + §9.12 + §9.13 all clear.
5. Surface to user: "Phase 9 完備 substrate audit ([`.dev/
   phase9_completion_substrate_audit.md`](../phase9_completion_substrate_audit.md))
   needs collaborative review; pausing autonomous mode."

### Step (f) — §9.13-0 windowsmini reconcile (post-§9.12)

After §9.12 substrate audit hard-gate clears (= §9.12 `[x]`),
the loop auto-resumes and executes Step (d)'s items (now
relocated here). On `§9.13-0 [x]`, the §9.13 Phase-10-entry
hard-gate fires and the loop again surfaces to user for
review.

### Step (g) — §9.13 Phase 10 entry gate

User-collaborative review per [`.dev/phase10_transition_gate.md`](../phase10_transition_gate.md).
Phase Status widget flips Phase 9 → DONE; Phase 10 →
IN-PROGRESS on `§9.13 [x]`.

## §7 Discipline notes for the next session

1. **Skip the autonomous "pick next §9.9 sub-chunk from
   ROADMAP" path** until step (a) lands. ROADMAP is currently
   stale w.r.t. the corrected scope; running on it produces
   wrong-direction work.

2. **Follow `extended_challenge.md` Step 4 generously**.
   Cat III work involves multi-module spec surface; cross-
   reference wasmtime / zware extensively. Survey notes under
   `private/notes/` are encouraged.

3. **Apply the new lints actively** — invariant-comment lint,
   spike audit, heisenbug tracker (D-134 already armed with
   streak counter). Cat III work likely creates new debt rows
   for residuals; treat handover.md as the running surface.

4. **Run gate_commit per commit** — the pre-commit hook is now
   active; deviations from gate failures should NOT be `--no-
   verify` (forbidden per ROADMAP §14). Diagnose + fix on the
   spot.

5. **Multi-result work (b) and instance work (c) are independent**.
   They can run interleaved; pick by chunk granularity (each
   chunk should target one OR the other, not both).

6. **windowsmini gating per `/continue/LOOP.md`** stays "Mac +
   ubuntunote per-chunk only" until step (d) — post-ADR-0067
   the Linux x86_64 host is ubuntunote (native), not OrbStack.
   Step (d) is the moment to re-introduce windowsmini.

## §8 References

- **Today's commits** (chronological):
  - `d3f2a1a7` — debug utility scaffold (8 files)
  - `24388587` — frontmatter + wiring
  - `66c699e7` — pre-commit gate reactivation (ADR-0063 +
    ADR-0064 + flake shellHook + check_skip_adrs fix +
    skip_host_state_diverged closed)
  - `83e80150` — D-095 close + D-052 flip
  - `e9e04ac9` — D-135 file
  - `14147194` — Sigaction Win64 gate (D-136 setup)
  - `2edfdef1` — sigsetjmp/siglongjmp Windows stubs
  - `23b4d20d` — 2 lesson Citing backfills
  - `3a63a5bd` — handover sync (close-readiness)
  - `194d8e92` — D-136 file
  - `7976dc00` — TODO(D-136) markers on Windows stubs

- **ADRs** to amend / create:
  - `0056_phase9_scope_extension_to_wasm2_full.md` — amend
  - `0063_uniform_pattern_catalog_file_size_exemption.md` — done
  - `0064_runner_validate_split.md` — done
  - `0065_wasm_1_0_instance_work_phase9_rescope.md` — NEW
    (placeholder; draft in step (a)-1)

- **Debt rows** affected (re-evaluate at step (a)-4):
  - D-052 (now), D-079, D-082 sub-rows, D-126, D-026, D-074,
    D-135, D-136, D-084 (per ADR-0055)

- **Substrate audit** (`.dev/phase9_completion_substrate_audit.md`):
  Q5 hygiene anchors extended in step (a)-5; Q3 architecture
  decision can proceed in parallel or after, doesn't block
  Cat III work

- **Private notes from today** (gitignored, retain for context):
  - `private/notes/adr-0056-amend-draft.md` — early draft;
    superseded by this doc

- **Today's debt seeds** (track via `scripts/track_heisenbug.sh
  d134 --status` etc.):
  - D-134 OrbStack heisenbug — **CLOSED 2026-05-17** per
    ADR-0067 (root cause: Rosetta 2 signal-translation race;
    pivoted Linux x86_64 host to native ubuntunote).
  - D-052 / D-081 — emit.zig source split chain
  - D-135 — entry.zig comptime generation (ADR-0063 Alt B)
  - D-136 — Win64 SEH bridge (Cat IV)

## §9 Revision history

| Date       | Change                                          |
|------------|-------------------------------------------------|
| 2026-05-17 | Initial draft compiled at close-readiness cycle end. Captures user-confirmed Cat III ROADMAP correction. |
