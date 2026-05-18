# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6 (revised 2026-05-18). ADR-0069 §Phase 2 + §Phase 3 partial
   close: Cat II Class C residual = D-148 (large-sig x86_64 SysV
   regalloc-pressure mis-marshal; Mac aarch64 PASSES).
2. **READ NEXT** D-148 row in `.dev/debt.md` + lesson
   [`2026-05-18-apple-arm64-natural-packing.md`](lessons/2026-05-18-apple-arm64-natural-packing.md).
3. `git log --oneline -10`. Latest: D-148 defer commit (manifest
   revert to skip-impl) after D-140 Mac green / x86_64 fail.
4. `bash scripts/p9_simd_status.sh` — live status.
5. `cat .dev/debt.md`. `now`: D-079, D-133, **D-148**.

## Active state — D-140 partial close: Mac green, x86_64 deferred to D-148

D-140 landed on Mac aarch64 (`func.wast::large-sig` 17 params /
16 mixed Class C results PASSES). Two ABI fixes shipped:

- **ADR-0026 amend (Convention Swap)**: x86_64 SysV MEMORY-class
  returns now use standard SysV §3.2.3 (RDI=&buffer, RSI=rt).
  Entry helpers revert to native `callconv(.c)` — no inline-asm.
- **arm64 Apple natural-size stack packing** (lesson
  `2026-05-18-apple-arm64-natural-packing.md`): Mac arm64 packs
  stack overflow args at natural size, not standard AAPCS64
  8-byte stride. Cursor logic now branches on
  `builtin.target.os.tag == .macos|.ios|.watchos|.tvos`.

**x86_64 SysV regalloc-pressure mis-marshal (D-148, now)**:
ubuntunote large-sig fails at slots r10..r15 (8 FP + 8 INT result
vregs vs 6 XMM + 4 GPR allocatable on x86_64). Manifest reverted
to `skip-impl multi-result large-sig` so the 2-host gate stays
bit-identical **25324/0/689**.

Cat II skip-impl multi-result residual: 1× `large-sig` (D-148).

### Next-session active task — D-148 x86_64 regalloc fix

Dependency chain to §9.9 [x]:

```
D-148 — instrument x86_64 marshalReturnRegs MEMORY-class to dump
        per-result (src_vreg, slot, home/spill). Identify the
        spill-aliasing or vreg-mis-resolve pattern. Candidate
        fixes: raise allocatable_xmms cap (free XMM6/XMM7 per
        abi.zig TODO(p7-7.7)) or audit spill-slot uniqueness
        across the function-return live range. Re-promote
        large-sig to `assert_return` in regen_spec_2_0_assert.sh
        once green on both hosts.
  ↓
§9.9 [x]  →  §9.12 substrate audit (USER GATE)  →
§9.13-0 windowsmini reconcile (LOOP)  →
§9.13 Phase 10 entry gate (USER GATE)
```

### Discipline reminders

No `--no-verify`. 2-host per chunk (Mac + ubuntunote);
windowsmini at §9.13-0 (post-§9.12). After D-148, §9.9 [x]
flips and Phase 9 enters the §9.12 substrate-audit hard gate.

### Outstanding `now` debts

D-079; D-133 (blocked by §9.12 audit cleanup); **D-148**
(active — large-sig x86_64). Relocated to §9.13-0: D-084 /
D-028 / D-136.

## Sandbox + References

`~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
Per-chunk 2-host; windowsmini Phase-boundary batch.

PRIMARY: [`phase9_close_plan.md`](phase9_close_plan.md).
ADRs: [`0017`](decisions/0017_jit_runtime_abi.md) (2026-05-18
amend) / **[`0026`](decisions/0026_x86_64_runtime_invariant_strategy.md)**
(2026-05-18 Convention Swap) / [`0069`](decisions/0069_multi_result_return_abi.md)
§Phase 3 (D-140 partial close).
Lessons: [`2026-05-18-apple-arm64-natural-packing.md`](lessons/2026-05-18-apple-arm64-natural-packing.md)
(Apple arm64 ABI fix); previous D-140 / D-147 lessons remain.
