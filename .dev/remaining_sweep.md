# Remaining-work sweep index (やり残し一括スイープ)

> **Doc-state**: ACTIVE. **Source of truth** for *what to do when no high-value 完成形 chunk is
> open*. Wired from `.dev/handover.md` (Steady-state) + `.dev/debt.yaml` conventions.
>
> **PURPOSE (user-directed 2026-06-06)**: when the high-value 完成形 surface/memory-safety/debt
> work is done, the loop **MUST NOT idle in minimal turns** ("done, so I wait"). Instead it
> **sweeps the remaining / deferred / low-value tasks systematically** from this index. A fresh
> "clear session" can sweep 一気に by walking the buckets top-down (A → B → C). This is the
> 配線＋参照チェーン so the leftover never rots silently.

## How to use — resume wiring (`/continue` RESUME §0.5)

When Step 0.5 (debt sweep) finds **no `now` row + no high-value 完成形 chunk + no fresh external
signal**, do NOT take a "minimal idle turn." Instead:
1. Open this index. Take the **next un-swept item from Bucket A, then B, then C** (skip D =
   externally blocked; only barrier-dissolution-check those).
2. Work it as a normal TDD commit-pair chunk (Steps 0–7). Chain several per turn (D5-a).
3. On completion: tick it here (`[x]`) + update/delete its `.dev/debt.yaml` row.
4. Idle (minimal turn) ONLY when **A + B are empty AND C is all prioritization/measure-gated
   AND D is all externally-blocked** — and even then, re-run the Bucket-D barrier-dissolution
   sweep + the audit (bottom) before idling.

The buckets are an ordering, not a value claim — low-value-but-doable (A/B) sweeps first because
they are cheap + reduce ledger noise; C is larger/judgement-gated; D needs the world to change.

---

## Bucket A — Ledger hygiene: prune completed-historical `note` rows (actionable NOW, ~0 risk)

These rows record "X was done @SHA" — ledger discipline (`yaml_ssot_yq.md`) says **delete on
discharge; git retains via the original commit**. Sweep = verify each is *not* a deliberately
retained regression-marker (some say "retained as regression marker" — KEEP those), then
`yq -i 'del(...)'` the rest in one `chore(debt): prune N discharged-historical rows` commit.

- [x] **SWEPT 2026-06-07** — all 15 rows (D-058/059/181/182/183/184/187/188/189/190/191/193/194/204/273)
  pruned in one `yq -i del(...)` (debt.yaml 66→51 entries). Each verified `status: note` + discharge-SHA in
  body; D-188's "regression marker" is the TEST (bisect `accepted_count==0`), not the row → safe to prune.
  Bucket A is now empty.
Refs: each row body has its discharge SHA; `.claude/rules/yaml_ssot_yq.md` (delete-on-discharge).

## Bucket B — Actionable low-value (sweep-able now; small, mostly local)

- [ ] **D-231** x86_64-side build-option DCE gate coverage gap — add a `check_build_dce.sh --gate`
      invocation to the **ubuntu leg** of `gate_merge.sh` (Mac build only nm-greps arm64). Refs:
      `scripts/check_build_dce.sh`, `scripts/gate_merge.sh`, `scripts/run_remote_ubuntu.sh`, ADR-0130.
- [ ] **D-259** `spillBytes()` over-allocates the spill stack frame (§15.3 fold). Refs: ADR-0150;
      measure first (perf-measure-first) — may be note-only.
- [ ] **D-282** windowsmini build-env flake (SSH/build stall, NOT code) — mitigation/retry in
      `run_remote_windows.sh`? Refs: `scripts/run_remote_windows.sh`, D-028 lineage.
- [ ] **D-283** realworld WASI corpus not run e2e under JIT (46/55 compile). Refs:
      `test/realworld/`, `src/wasi/jit_dispatch.zig` — would SURFACE failures = creates debt;
      sweep ONLY paired with fixing what it surfaces, else keep as note.

## Bucket C — Deferred features / v0.2 / judgement-gated (larger; sweep when prioritized)

- [ ] **D-209** memory64 `>4GiB` memarg offset = the deferred **10.M-4b (ADR-0111 D4)**: MOVZ/MOVK
      offset lanes 2/3 + i64-idx wrap-check, both arches + fixture. Exotic, no consumer →
      measure-first deferral. Refs: `src/engine/codegen/arm64/op_memory.zig:71-72,188-190`, ADR-0111 D4.
- [ ] **D-286** `memory.fill`/`memory.init` JIT lowering perf (D-285 follow-on) — perf-measure-first.
- [ ] **D-289** arm64 frame-offset imm12 cap residual (ADR-0163 A) — degenerate-only.
- [ ] **D-290** wabt → wasm-tools toolchain migration (3 proposal-laden distillers) — direction-gated
      (wasm-tools↔wabt output divergence; wabt stays). Refs: D-290 body has the proof + recipe.
- [ ] **D-271** `wasm_module_serialize` AOT-artifact cache (QoI vs wasmtime). Refs: `src/api/module_serialize.zig`.
- [ ] **D-281** WASI host socket-preopen (post-v0.1, on-demand). Refs: `src/wasi/`.
- [ ] **D-292 / D-293 / D-294** trap/crash-UX residuals (D-293-class, conformance-neutral, JIT-only;
      "leave unless a GC-on-JIT program needs it"). Refs: ADR-0164/0166.
- [ ] **D-266 / D-268** x86_64 register-homing parity / ROI unmeasured (perf-measure-first).
- [ ] **D-295 / D-296 / D-297** Phase-16 audit *records* (CLI / C+Zig-API / cross-module mem-safety) —
      reference notes, prune when their cross-ref'd residuals are all closed/tracked elsewhere.

## Bucket D — Externally blocked (NOT sweep-able; barrier-dissolution check only)

The 31 `blocked-by` rows. Each `/continue` §0.5 checks whether the named barrier dissolved this
resume; if so the row leaves D and becomes A/B/C. Grouped by barrier:
- **call_ref / §10.R**: D-186, D-206. **iso-recursive GC subtype**: D-198, D-211, D-202.
- **specific-validator-error surfacing**: D-197 (parse-vs-validate axis discharged cyc127; residual = precise
  error kinds).
- **Phase 11 WASI / emcc**: D-007, D-026, D-074, D-082, D-177, D-249. **typed-funcref ADR-0123**: D-195, D-196.
- **Zig upstream**: D-010, D-148. **wabt version**: D-179. **v0.2 host-construct**: D-178.
- **spec-runner harness**: D-234, D-237, D-022, D-021, D-020. **x86_64 EH parity**: D-238.
- **Win64 env / rust-host**: D-028, D-254, D-255, D-253. **misc**: D-210, D-245.
  **NOTE 2026-06-06**: D-264 dogfooding DISCHARGED (cw v1 side succeeded, user-confirmed). **D-075** barrier
  (cw v1 dogfooding wait) now DISSOLVED → ADR-0109 Status can flip `Accepted → Closed (implemented)` + D-075
  retires (move to Bucket A next sweep; verify the ≥1-minor-version intent vs the user's "succeeded" 完了).
Refs: each row's `blocked-by:` predicate (head of its `.dev/debt.yaml` description) = the unblock test.

## Special — D-279 (Win64 SIMD-JIT heisenbug)

Instrumented + awaits an **external** signal (next Win64 crash → `[d-279-veh] STACK-OVERFLOW`
confirms/refutes H3). Mac-side investigation walled. NOT idle-blocking but NOT Mac-sweep-able;
verify at every Step 0.7. Refs: D-279 row, `src/platform/windows_traphandler.zig`.

---

## Audit (run when refreshing this index; `audit_scaffolding`-adjacent)

- Every `.dev/debt.yaml` id appears in ≥1 bucket here (A/B/C/D) or "Special". The index MAY also reference
  discharged/predecessor ids (e.g. D-264 discharged, D-285 predecessor) — that is fine; only the *missing*
  direction is a defect. Check (must print NOTHING):
  `comm -23 <(yq -r '.entries[].id' .dev/debt.yaml|sort -u) <(grep -oE 'D-[0-9]+' remaining_sweep.md|sort -u)`.
- Each Bucket-A/B/C ref-chain path/ADR resolves (file exists / ADR present).
- A row that newly went `now` or had a barrier dissolve → move it up + retarget the next sweep.
