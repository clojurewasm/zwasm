# W54 redesign — single-pass loop optimization layer

Captured 2026-04-29 (deep redesign session). Branch:
`develop/w54-loop-pass-redesign`. Supersedes
`.dev/w54-investigation.md` once the plan lands.

## Goal

Close the wasmtime gap on string/matrix/math benchmarks while staying
single-pass and regressing nothing. Primary success criterion:
`tgo_strops` from 2.40× → ≤1.30× of wasmtime, all other benches within
±5% of pre-redesign baseline.

Secondary: structural cleanup so future hoists are not "ad-hoc with safety
boundary collisions" (the trap that killed `develop/w54-magic-hoist-attempt`).

## What today's pipeline actually looks like (verified)

```
wasm bytes
   └─ src/predecode.zig — IrFunc { code: []PreInstr, pool64: []u64 }
                          fusePass: peephole superinstrs (LOCAL_GET_CONST etc.)
   └─ src/regalloc.zig — RegFunc { code: []RegInstr, reg_count, local_count, pool64 }
                          copyPropagate (adjacent MOV only, regalloc.zig:1464)
                          fuseConstBinop (CONST32 + binop → BINOP_IMM, regalloc.zig:1532)
   └─ src/jit.zig / src/x86.zig — machine code
                          scanBranchTargets — locally computes loop_headers
                          + loop_end_map, NOT shared with regalloc (jit.zig:2436)
                          known_consts[128] — wiped at every loop header
                          emitLoopPreHeader — v128-only, scalar-blind (jit.zig:4604)
                          tryEmitDivByConstU32 — fresh MOVZ+MOVK per call site
```

Two real symptoms:

1. `tgo_strops` `digitCount` emits MOVZ+MOVK+UMULL+LSR (5 instr) per
   iteration × 3 div sites → ~6 hoistable instructions per iter wasted.
2. TinyGo `local.set` chains generate `mov rA = T1; mov rB = rA;
   mov rC = rB` — `copyPropagate`'s "producer immediately before MOV"
   constraint only collapses the first hop.

Three structural causes:

a. **No shared loop information.** Each layer rebuilds its own loop view.
   `regalloc.zig` doesn't even know about loops. `emitLoopPreHeader`
   re-scans the loop body that `scanBranchTargets` already walked.
b. **No liveness.** `written_vregs` tracks first-write only; nothing
   tracks last-use. Coalescing, register pressure, and cross-iteration
   reuse all hit the same wall.
c. **Register layout is a flat switch.** `vregToPhys` (jit.zig:1006-
   1014, x86.zig:1556-1570) hard-codes which physical reg holds which
   vreg. Every new optimization that wants a callee-saved slot
   (`inst_ptr_cached`, magic hoist, ...) collides at a different
   `reg_count` cliff. The aborted W54 attempt died here.

## Design

### Pillar 1 — `LoopInfo` as a first-class artefact between regalloc and JIT

New file: `src/loop_info.zig`.

```zig
pub const Loop = struct {
    header_pc: u32,
    end_pc: u32,           // max back-edge source PC
    parent: ?u16,          // outer loop index, or null
    depth: u8,             // 0 = outermost
    has_call: bool,        // affects register-budget choices
    body_size: u32,        // end_pc - header_pc + 1
};

pub const LoopInfo = struct {
    loops: []Loop,             // outer-first order
    branch_targets: []bool,    // any-target bitmap (replaces local copy)
    loop_headers: []bool,      // header bitmap (replaces local copy)
    loop_end_map: []u32,       // header_pc → end_pc
    pc_to_loop: []?u16,        // innermost containing loop (or null)
    /// vreg_first_def[v] = first PC writing v; UINT32_MAX if never
    vreg_first_def: []u32,
    /// vreg_last_use[v]  = last  PC reading v (rs1/rs2); 0 if never
    vreg_last_use: []u32,
    /// loop_invariant_const[loop_idx] = list of (CONST32 PC, divisor)
    /// where the const vreg is defined exactly once (outside the loop
    /// or as a loop-trip-stable producer) and consumed by a divisor.
    invariant_consts: []HoistedConst,
};

pub const HoistedConst = struct {
    loop_idx: u16,
    const_pc: u32,        // PC of the OP_CONST32 we hoist
    divisor: u32,         // immediate value
    /// 0 = unsigned div magic; 1 = signed div magic; 2 = generic 32-bit const
    class: u8,
    /// Filled by JIT at preheader emit time
    phys_reg: ?u8 = null,
};
```

`analyse(reg_func)` does ONE forward sweep + ONE backward sweep:

- Forward: branch-target bitmap, loop_headers, loop_end_map (existing
  `scanBranchTargets` logic, lifted out).
- Forward (same pass): vreg_first_def via the rd field.
- Backward: vreg_last_use, scanning rs1 + rs2.
- Post-process: classify CONST32 sites whose result vreg is read only
  by `OP_DIV_U` / `OP_REM_U` / `OP_DIV_S` / `OP_REM_S` and whose
  define-PC < their loop's header_pc. Those are the magic-hoist
  candidates.

Cost: O(N) twice where N = RegInstr count. Tiny vs JIT emission.

The JIT consumes `LoopInfo` via `Compiler.loop_info: *const LoopInfo`.
`scanBranchTargets` becomes a thin wrapper that returns the slices
already computed in `LoopInfo`. `emitLoopPreHeader` queries the same
struct.

### Pillar 2 — Register classes (the real cleanup)

Today's `vregToPhys` is a fixed switch with implicit collisions. Replace
with a `RegPool` per-arch (jit.zig + x86.zig) consulted at prologue time.

```zig
pub const RegClass = enum {
    /// Holds a vreg as long as the function is live; saved/restored in prologue
    vreg_callee,
    /// Holds a vreg in caller-saved space; sometimes spilled around calls
    vreg_caller,
    /// Permanent infrastructure (REGS_PTR, MEM_BASE, MEM_SIZE, …)
    infra,
    /// Stash for vm_ptr / inst_ptr when needed by self-calls
    self_call_cache,
    /// Loop-hoisted invariants (NEW)
    hoist,
    /// Inline scratch (x8/x16 on ARM64; RAX/R11 on x86_64)
    scratch,
};

pub const RegPool = struct {
    /// Per-class lists of physical regs in priority order
    classes: [@typeInfo(RegClass).Enum.fields.len][]const u8,
    /// Which physical regs are still available; updated by claim/release
    free: PhysSet,
    pub fn claim(self: *RegPool, class: RegClass) ?u8 { ... }
    pub fn release(self: *RegPool, phys: u8) void { ... }
};
```

The prologue analysis (currently jit.zig:2007-2009) runs in a single
order:

1. Pin infra registers (REGS_PTR, MEM_BASE, MEM_SIZE).
2. If `(!has_memory and has_self_call)` or
   `(reg_count <= 13 and has_self_call)` → claim 2 from `self_call_cache`.
3. Allocate vreg_callee for vregs 0..min(reg_count, callee_capacity).
4. **NEW:** if `loop_info.invariant_consts.len > 0`, claim up to
   `min(invariant_consts.len, hoist_capacity)` from class `hoist`.
5. Allocate vreg_caller for the rest. Anything that doesn't fit spills.

The hoist class is sourced from the **tail of the callee-saved set**
(`x23`-`x26` after vregs are placed; or push-an-extra-pair when the
function isn't already pushing maximum). On x86_64 it carves from
`R13`/`R14` only when `reg_count` is small enough to free them — the
default is to skip the optimisation (graceful degradation, no abort).

Critically: the **collision with `inst_ptr_cached` is gone** because
both consult the same `RegPool` and conflicts surface as "claim
returned null", not as a silent register reuse bug. The aborted W54
branch's failure mode (x21 reused for both inst_ptr cache and magic)
becomes statically impossible.

### Pillar 3 — Scalar `emitLoopPreHeader`

Same call-site (jit.zig:2665) but now does TWO passes per loop:

```zig
fn emitLoopPreHeader(self: *Compiler, ir: []const RegInstr, header_pc: u32) void {
    // Existing v128 input pre-load (unchanged)
    self.emitV128PreLoads(ir, header_pc);

    // NEW: scalar magic-constant hoist
    const loop_idx = self.loop_info.pc_to_loop[header_pc] orelse return;
    for (self.loop_info.invariant_consts) |*hc| {
        if (hc.loop_idx != loop_idx) continue;
        const phys = self.reg_pool.claim(.hoist) orelse {
            // No room — gracefully skip; tryEmitDivByConstU32 falls back
            continue;
        };
        hc.phys_reg = phys;
        switch (hc.class) {
            0 => self.emitLoadMagicU32(phys, hc.divisor),  // MOVZ+MOVK once
            1 => self.emitLoadMagicS32(phys, hc.divisor),
            2 => self.emitLoadImm(phys, hc.divisor),
            else => unreachable,
        }
    }
}
```

`tryEmitDivByConstU32` becomes:

```zig
fn tryEmitDivByConstU32(self, instr, divisor) bool {
    if (divisor & (divisor - 1) == 0) { /* power-of-two LSR — unchanged */ }

    // NEW: check if the magic for this divisor is already hoisted
    if (self.findHoistedMagic(instr.rs2(), divisor)) |phys| {
        self.emitDivWithCachedMagic(instr, phys);
        return true;
    }

    // Existing fallback: emit MOVZ+MOVK+UMULL+LSR per call
    return self.emitDivWithFreshMagic(instr, divisor);
}
```

`findHoistedMagic` is O(invariant_consts.len) — typically 0-3 entries,
so we don't even need a hashmap.

### Pillar 4 — Liveness-driven mov coalescing

`regalloc.zig:copyPropagate` currently scans for "MOV with producer
immediately before". Extend with a second pass that uses
`vreg_last_use[]` (computed by `LoopInfo.analyse` — but we need it at
regalloc time, before `LoopInfo` runs over RegInstr).

Resolution: factor `vreg_last_use` into a tiny standalone pass that
runs at the end of `regalloc.zig`. `LoopInfo.analyse` then receives it
as input rather than recomputing.

The extended coalescer recognises `mov rB = rA; ... ; mov rC = rB`
chains where `rA` is dead at `mov rC = rB` and `rB` is dead after the
MOV. Folds: rewrite producer of rA to write into rC, delete both MOVs.

Constraint: must not cross branch targets (rA might be live on the
join). Branch-target bitmap is shared with `LoopInfo`.

### Pillar 5 — Loop-invariant constant survival

At the loop-header wipe (jit.zig:2659), do NOT clear `known_consts[v]`
when:

- `loop_info.vreg_first_def[v] < loop.header_pc` (defined outside) AND
- no write to `v` exists inside `[loop.header_pc, loop.end_pc]` (cheap
  check: scan once during `LoopInfo` analyse and store as a bitmap per
  loop).

This unlocks more `tryEmitDivByConstU32` calls (the divisor const is
defined in the function prologue but the loop-header wipe lost it).
Cost: one bitmap per loop in `LoopInfo`.

## Cross-bench impact prediction

| Bench         | Wasmtime ratio now | Primary lever                     | Predicted ratio |
|---------------|--------------------|-----------------------------------|-----------------|
| `tgo_strops`  | 2.40×              | Magic hoist (Pillar 3)            | 1.10–1.30×      |
| `tgo_mfr`     | 1.31×              | Mov coalescing (Pillar 4)         | 1.05–1.15×      |
| `tgo_nqueens` | 1.29×              | Mov coalescing (Pillar 4)         | 1.10–1.20×      |
| `rw_c_matrix` | 2.84×              | Loop-invariant const + reg layout | 1.50–2.20×      |
| `rw_c_string` | 4.10×              | Indirect (cleaner addressing)     | 3.00–3.80×      |
| `rw_c_math`   | 5.01×              | None (libm calls — out of scope)  | unchanged       |
| `st_matrix`   | 3.18×              | Loop-invariant const              | 1.80–2.50×      |

`rw_c_math` is deliberately out of scope — it's BLR-heavy libm dispatch
and needs intrinsic recognition (separate W## item). Logged in
checklist.md once this plan lands.

## Phasing and gates

Branch: `develop/w54-loop-pass-redesign` (already cut).

### Phase 0 — Behaviour-neutral lift of `scanBranchTargets`
- Create `src/loop_info.zig` with the basic forward sweep
  (branch_targets, loop_headers, loop_end_map).
- `Compiler.loop_info` field on both backends.
- `scanBranchTargets` becomes a thin caller of `LoopInfo.analyse`.
- **Gate**: Commit Gate items 1-5 + bench --quick on Mac.
  Acceptance: 0 test/spec/e2e/ffi failure; bench within ±2% of
  baseline.

### Phase 1 — Liveness in regalloc
- Add `vreg_first_def[]`, `vreg_last_use[]` computation at the end of
  `regalloc.zig`. Stored on `RegFunc`. No codegen change.
- **Gate**: Same as Phase 0.

### Phase 2 — `RegPool` abstraction
- Replace `vregToPhys` switch with `RegPool` driven by prologue
  analysis. Same physical assignment for existing cases (zero diff
  in emitted code for unmodified flows).
- Add `RegClass.hoist` but no users yet.
- **Gate**: Commit Gate full (1-8). Benchmarks within ±2%.

### Phase 3 — Magic-constant hoist (the W54 win)
- Extend `LoopInfo.analyse` with `invariant_consts` classification.
- Extend `emitLoopPreHeader` (both arches) for class 0 (udiv magic).
- Extend `tryEmitDivByConstU32` (both arches) with hoist consult.
- **Gate**: bench `--bench=tgo_strops` shows ≥30% improvement vs Phase 2.
  Full Commit Gate. Then full bench run on Mac + Ubuntu OrbStack.

### Phase 4 — Loop-invariant `known_consts`
- Implement the per-loop "no-internal-write" bitmap and the wipe
  exception.
- **Gate**: bench `--quick` should show small wins across
  matrix/strops; no regression.

### Phase 5 — Liveness-driven mov coalescing
- Extend `copyPropagate` (or replace with new `coalesceLiveRanges`).
- **Gate**: tgo_mfr/tgo_nqueens improvement; full bench Mac + Ubuntu.

### Phase 6 — sweep + memo + decisions.md
- D## entry for the new architecture (LoopInfo + RegPool + scalar
  preheader).
- W54 closeout in checklist.md. Open new W## for libm intrinsic
  recognition (rw_c_math) as follow-up.
- Squash-merge to main as ONE PR (per project policy this is
  preferable to a stack of phase commits — the phases are committed
  to the feature branch but the merge is single-shot).

### Cross-platform gate (before main merge)
- Mac aarch64: full Commit Gate + Merge Gate items 1-7.
- Ubuntu x86_64 via OrbStack: items 1-6 (Linux-relevant subset).
- Both must be green before merge.

## Risks and rollback

| Risk                                      | Detection             | Rollback                          |
|-------------------------------------------|-----------------------|-----------------------------------|
| RegPool change drops perf on a corner case| Phase 2 bench gate    | Revert Phase 2; rerun Phase 0/1   |
| Magic hoist register conflict on x86_64   | Phase 3 spec test     | Disable hoist on x86_64 only      |
| Coalescer breaks block-end MOV invariant  | Phase 5 e2e test      | Revert Phase 5 alone              |
| Loop-invariant const survives a write we  | Phase 4 fuzzing       | Revert Phase 4; tighten bitmap    |
| missed (correctness regression)           |                       |                                   |

Each phase is independently revertable because the feature branch
sequences them as separate commits.

## Out of scope (deferred)

- **libm intrinsic inlining** for `rw_c_math` — needs imported
  function name resolution + ARM64 FSQRT/FDIV/FNEG inline + libm soft
  fallback for sin/cos/pow. New W## task.
- **Bounds-check elision via constant induction** for `rw_c_string` —
  needs simple SCEV-style induction analysis. Could be Pillar 6 in a
  future round.
- **f64 cross-loop register pinning** for matrix benches — the
  `RegPool.hoist` class can carry one-iter f64 invariants but not
  cross-loop SSA-level pinning. Out of scope for this redesign.
- **Strength reduction** for matrix address computation — out of
  scope; left to clang.

## Estimated effort

- Phase 0: 0.5 day. Pure refactor.
- Phase 1: 0.5 day. Two passes over RegInstr.
- Phase 2: 1.5 days. Both arches; careful prologue testing.
- Phase 3: 1 day. Both arches; bench-driven tuning.
- Phase 4: 0.5 day. Bitmap + wipe exception.
- Phase 5: 1 day. Coalescer extension; correctness via fuzz.
- Phase 6: 0.5 day. Docs + closeout.

Total: ~5.5 days of focused work. Each phase commits independently.

## Success metrics

After Phase 5:
- `tgo_strops` ≤ 1.30× wasmtime.
- All other Mac+Ubuntu bench ratios within ±5% of pre-redesign.
- Spec/E2E/realworld/FFI: 0 fail, 0 leak, on both platforms.
- New `loop_info.zig` is the single source of truth for branch +
  loop info; `scanBranchTargets` is a 5-line wrapper.
- `vregToPhys` is replaced by `RegPool.claim/release`; the
  `inst_ptr_cached` collision class no longer exists.
