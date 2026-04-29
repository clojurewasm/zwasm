# W54 redesign — what shipped, what archived, what to do next

Captured 2026-04-30 after the deep redesign session, updated after
PR #91's first CI surfaced an x86_64-only regression on the
coalescer.

## TL;DR

- **Shipped** (`develop/w54-loop-info` → main, PR #91): the LoopInfo
  substrate only. `src/loop_info.zig` shared analysis layer with
  branch_targets / loop_headers / loop_end + per-vreg first_def /
  last_use. Both backends consume it instead of duplicating
  `scanBranchTargets`. Behaviour byte-identical to main on every
  benchmark we dump-jit'd.
- **Archived** (`develop/w54-loop-pass-redesign`, tagged
  `archive/w54-magic-hoist-2026-04-30`):
  - Magic-constant loop-invariant hoist with `inst_ptr_cached`
    displacement. digitCount JIT 196 → 192. Held back pending
    W47 + W54-x86.
  - Liveness-driven mov coalescing extension to
    `regalloc.copyPropagate`. digitCount JIT 196 → 189. Reverted
    from the substrate PR after Linux x86_64 CI flagged a
    `go_math_big` BigInt divergence; tracked as W54-coalescer.
- **Dropped**: Phase 4 ("loop-invariant `known_consts` survival
  across loop headers"). The W54 target — digitCount — emits
  CONST32 *inside* the loop body for every divisor site, so the
  optimisation never fires on it. Re-evaluate when a benchmark
  with the defined-outside-loop pattern shows up.

## Session arc

The starting point: PR #90 captured the W54 investigation
(`.dev/w54-investigation.md`) which disproved the original framing
("zwasm doesn't fold i32.div_u K"). zwasm already emits the
Hacker's Delight magic-multiply for constant divisors on both
arches; the 2.4× wasmtime gap on `tgo_strops` lives in two places
— magic constants re-loaded every iter, and TinyGo's mov-heavy
`local.set` chains.

The first attempt at the magic hoist
(`develop/w54-magic-hoist-attempt`, abandoned the same evening)
hit a register collision: x21 was simultaneously the inst_ptr cache
for `reg_count <= 13 && has_self_call` AND the natural callee-saved
candidate for the magic. The investigation captured in
`.dev/w54-investigation.md` concluded that picking a safe boundary
was a design call, not a tail-end commit on a long autonomous run.

The redesign session (this one, 2026-04-29 → 2026-04-30) did the
design work the abandoned attempt avoided:

1. Built the substrate (LoopInfo + opcode helpers + liveness data).
2. Built the magic hoist on top, with `pickHoistPhys` that
   displaces inst_ptr_cached when needed.
3. Built the liveness-driven coalescer.
4. Discovered via Mac bench that the runtime gain of (2)+(3) is
   below the σ ≈ 10% noise floor on tgo_strops (W47).
5. Reduced scope to just the substrate (1) for the PR. Tested.
   Mac green. Pushed.
6. Linux x86_64 CI flagged `go_math_big` regression on the
   coalescer (3). Reproduced on OrbStack `my-ubuntu-amd64`.
7. Reverted (3) from the PR. Re-pushed substrate-only.
8. Mac aarch64 native testing of (3) had passed; the bug is
   x86-specific. Tracked as W54-coalescer for diagnosis.

## Branches and commits

```
main (pre-redesign)
 └── develop/w54-magic-hoist-attempt   abandoned 2026-04-29 evening
 │   reason: x21 register collision, deferred for daylight design
 │
 └── develop/w54-loop-pass-redesign    archived 2026-04-30
 │   tag: archive/w54-magic-hoist-2026-04-30
 │   contents (7 commits):
 │     dd450f5  redesign plan (.dev/w54-redesign-plan.md)
 │     b65477a  Phase 0  scanBranchTargets → LoopInfo
 │     98287ae  Phase 1  vreg liveness on LoopInfo
 │     1600397  Phase 2  hoist_phys / hoist_displaced_inst_ptr scaffold
 │     c4b806e  Phase 3  ARM64 magic-constant hoist
 │     ec8182f  Phase 5  liveness-driven mov coalescing
 │                       (Mac green, x86_64 fails go_math_big)
 │     a56d442  Phase 6  D138 + checklist + memo + bench record
 │
 └── develop/w54-loop-info             shipped 2026-04-30 (PR #91)
     contents (3 commits, cherry-picked from the archive):
       ee10661  Phase 0  scanBranchTargets → LoopInfo
       ac2d446  Phase 1  vreg liveness on LoopInfo
       <docs>   D138 + checklist + memo + this postmortem
```

## Why the coalescer was reverted from PR #91

The Phase 5 commit (`ec8182f`) extended `regalloc.copyPropagate` to
fold a temp-to-local MOV when the temp is killed (redefined) before
any later read — an O(N) bounded scan that stops at the first
redefinition of `old_reg`, with bail-outs for branch targets,
forward branches, and multi-source ops.

On Mac aarch64 this passed:
- 412/412 unit tests
- spec / e2e / FFI / minimal builds
- 50/50 realworld (including `rust_regex` which the first attempt
  broke — the forward-branch bail caught that case)

On Linux x86_64 CI it failed:
- realworld 49/50: `go_math_big` DIFF
- wasmtime: `diff: 864197532086419753208641975320`
- zwasm:    `diff: 864197532160206729503480181784`

Reproduced on OrbStack `my-ubuntu-amd64` (native x86_64, not
Rosetta). This means the coalesced `RegFunc` (which is identical
across both backends — regalloc is arch-agnostic) gets correctly
emitted on ARM64 but mis-emitted on x86_64. The bug is in
`src/x86.zig`'s codegen interaction with the new IR layout (fewer
MOVs, shifted PCs).

This rules out "the coalescer is wrong" — Mac aarch64 passes 50/50
on the same `RegFunc`. It points at an x86-specific assumption
the new layout violates: likely a getOrLoad / SCRATCH contention
or a spill-around-call sequence whose timing depends on a MOV
that the new coalescer eliminates.

Diagnosis path (W54-coalescer):
1. `--dump-regir` for `go_math_big`'s offending function on both
   the coalescer branch and main; identify the first MOV that the
   new fold removed.
2. `--dump-jit=...` for that function on x86_64 main vs branch;
   find the codegen difference.
3. Check that x86's getOrLoad caching, scratch_vreg invalidation
   on UMULL, and call-site reload loops correctly handle the new
   IR shape.
4. Add a regression test (the failing IR pattern, ideally a
   minimal wat).

## Why the hoist was held back from PR #91

The Phase 3 commits (`1600397` + `c4b806e`) implement the magic
hoist. ARM64 dump-jit shows the win: digitCount 196 → 192 with
hoist alone. Stacked with the (now-reverted) coalescer: 192 →
185.

Three reasons it didn't ride along with the substrate:

1. **W47**: the bench σ on `tgo_strops` is ~10%. The hoist's
   wall-clock effect is below the noise floor. Without harness
   improvement the win is unfalsifiable; landing it now would mean
   any later regression is argued as noise rather than measured.

2. **`inst_ptr_cached` displacement**: when no callee-saved slot
   is free (digitCount has reg_count=13 + self_call which
   saturates), the hoist takes x21 from the inst_ptr cache. Every
   `emitLoadInstPtr` site becomes a memory load. ARM64-specific
   behaviour change, no measured benefit today.

3. **W54-x86**: x86_64 has different free-slot mechanics. Land
   ARM64 alone and the next x86 PR has to reconcile two arches.
   Bundling makes one coherent change later.

When W47 + W54-x86 + W54-coalescer are all green, the path is:
checkout `archive/w54-magic-hoist-2026-04-30`, cherry-pick
`1600397` + `c4b806e` (hoist) + `ec8182f` (coalescer, after
diagnosing the go_math_big regression).

## Lessons / signals to remember

- **Linux x86_64 CI is irreplaceable for arch-asymmetric
  regressions.** Mac aarch64 + OrbStack x86_64 (Rosetta) both
  pass; only the GitHub-hosted native x86_64 runner caught
  go_math_big. OrbStack's "amd64" via Rosetta is x86-emulated on
  ARM Mac and somehow doesn't trigger the same codegen path the
  CI runner does. **The Mac-only "Mac green ⇒ ship" heuristic
  is unsafe** — Linux CI is non-redundant.

  Update 2026-04-30: confirmed reproducible on OrbStack with a
  fresh build (`zig build -Doptimize=ReleaseSafe` in the VM, not
  cross-compiled from Mac). The earlier "OrbStack passes" reading
  was a stale Mach-O binary that wasn't actually executed —
  OrbStack Linux can't run aarch64-darwin Mach-O, so the test
  fell through to wasmtime's output.

- **Regalloc-stage IR changes are arch-agnostic, but JIT
  consumption isn't.** A new `RegFunc` shape that's correct by
  construction can still expose existing backend bugs (or
  undocumented backend assumptions). Both backends need to be
  exercised before claiming a regalloc-stage refactor is
  behaviour-neutral.

- **Bench σ ≈ 10% on `tgo_strops`** (W47) is the gating
  constraint for measuring small JIT optimisations. Until W47,
  sub-10% wins are unfalsifiable.

- **Forward branches are the safety boundary for redef-stop
  coalescing.** The `rust_regex` `/h.l+o/ ~ "hallo"` failure was
  exactly the "branch over a redef" pattern — without dominator
  info, every forward branch in the scan window has to be a bail.
  The x86_64 `go_math_big` failure is a different class — same
  RegFunc, but the x86 backend mis-emits.

- **Phase 4 (invariant `known_consts` across loop headers) does
  not fire on the W54 target**. digitCount's CONST32 is reborn
  per iteration. Verify-on-RegIR is cheaper than
  implement-and-bench.

- **`develop/w54-magic-hoist-attempt` was right to defer**. The
  collision class (x21 = inst_ptr_cache vs hoist) was a missing
  layer in the JIT. The substrate added the layer; the
  consequential optimisations stack on top.

## Pointers

- Architecture: D138 (`.dev/decisions.md`).
- Investigation log: `.dev/w54-investigation.md` (in main, PR #90).
- Original plan: `.dev/w54-redesign-plan.md` (on the archive
  branch only — the shipped scope is much narrower than the plan).
- Bench harness work: `W47` in `.dev/checklist.md`.
- Coalescer re-attempt: `W54-coalescer` in `.dev/checklist.md`.
  Diagnose via `--dump-regir` / `--dump-jit` on x86_64 first.
- Hoist re-attempt: `W54-hoist-revisit` + `W54-x86`. Cherry-pick
  `1600397` + `c4b806e` from `archive/w54-magic-hoist-2026-04-30`.
