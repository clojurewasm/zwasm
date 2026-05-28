# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `293793a0` — chore(p10): ADR-0122 D-193 ungate, 3 portable
  codegen tests (compile.zig 312/351 + linker.zig 524) (10.G cycle 44).
  Mac aarch64 `zig build test` exit 0 + lint clean. cycle 43
  (`24b054c4`, entry.zig 8 tests) verified green on Linux x86_64
  (ubuntu `OK (HEAD=9d38d9f7)`). cycle 44 Linux x86_64 verification
  pending via ubuntu kick — Step 0.7 next cycle reads `/tmp/ubuntu.log`.
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 18 — all `blocked-by:` with named structural
  barriers. Zero `now`-status rows.
- **No Active bundle** — D-193 ungate is per-cycle opportunistic
  triage (ADR-0122 D6), not a bundle.

## Active task — D-193 per-site ungate (ADR-0122 D6)

Discharging the Mac-aarch64-only test gates that hide Linux x86_64
coverage (D-180 hazard class). 12 sites remain (see D-193 row).

**NEXT chunk** — Group A cleanup batch (9 sites): `entry_buffer_write.zig`
×7 + `linker.zig` 689/789. Their gates already include x86_64 (they
run on ubuntu today); ungate removes the defensive over-skip on
non-CI hosts (Linux aarch64 / Mac x86_64). Recipe: remove the
`if (!(mac aarch64) and !(x86_64 and !win)) skip.blocker` block, add
`if (windows) return skip.phaseEnd(.win64)`. The 6 arch-first
entry_buffer_write gates are identical (replace_all); site 179 is
os-first (separate edit). No CI delta — pure non-CI-host cleanup.

**Last** — Category (a), 3 arm64-byte-pinned sites (dedicated cycle):
`jit_mem.zig` MOVZ-X0-#42 probe; `linker.zig` 610 (asserts B 0x14… +
`inst.encB`) + 650 (asserts BL 0x94…). These test arm64-specific
machine code; ungating breaks x86_64 compile. Need an x86_64 sibling
test OR comptime arch guard + SIBLING-AT comment per ADR-0122 D3.

## Larger §10 work (not started; bigger than per-cycle ungate)

- **10.TC JIT-side** — regalloc terminator-class extension
  (ADR-0113 §A) + `op_tail_call.zig` + `frame_teardown.zig` +
  `cross_module_tail_call.zig` + safepoint-free comptime assert.
  Interp trampoline already landed (D-187 `8f8a01ec`); JIT emit side
  is the remaining ROADMAP 10.TC scope. Bundle candidate.
- **10.G op_gc** — runtime substrate landed end-to-end (parse +
  side-tables + struct/array ops + β mark-sweep + root walker).
  Spec-corpus exercise is D-179-blocked (wabt 1.0.41+).
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (HEAD `96a17d5a`; unchanged by gate-only cycles)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(fail2) exception=4(fail4)
[function-references] invalid=12 (all pass)
```

EH 40 fails gated on the bigger 10.G/10.E work (D-192).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.
- D-186 — `return_call_ref` blocked-by 10.R-3/4/5 (GC-gated).
- D-188 — 2 now (try_table.8 + try_table.10); blocked-by 10.E
  validator strictness (GC-gated via D-192).
- D-192 — EH runtime path blocked-by exnref ValType + cross-module
  register support (GC-gated).

## Key refs

- ADR-0122 (test skip categorization; D5 helper, D6 ungate review).
- ADR-0076 (D1 scope-adaptive gate, D2 single-push, D3 ubuntu kick).
- ADR-0113 §A/§B/§C (regalloc terminator/N-successor/stack-map axes).
- ROADMAP §10 rows 10.TC / 10.G; Phase log `.dev/phase_log/phase10.md`.
- Lessons: `.dev/lessons/INDEX.md` 2026-05-28 (x86_64-uses-runtime-ptr
  EH gap = D-180 root cause; the hazard class D-193 ungates verify).
