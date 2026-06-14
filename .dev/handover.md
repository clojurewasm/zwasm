# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Just closed — D-332 JIT sandbox-triad completion: `--max-table-elements` (`bd355258`)

**`bd355258`**: the JIT runner enforced fuel + max_memory but NOT a table-elements cap (the interp
eager-alloc path did) — an asymmetric triad gap + a setup.zig comment that falsely claimed the bound.
Added `RunLimits.max_table_elements` + `Error.TableLimitExceeded`, early-reject in `runWasiLenient`
(Σ declared table mins > cap) before setup's eager `table_refs` alloc; CLI `--max-table-elements`
mirrors `--max-memory`; null = unlimited. Test + lint green (2864/2876, 0 fail). This was the D-332
"low-value follow-on" — now closed; the sandbox triad (fuel/memory/table) is cross-engine complete.

**Phase-B debug tooling (user-directed persistence, prior turns)** — a reusable lldb value-trace stack for JIT
miscompiles that produce wrong output but DON'T crash:
- `ZWASM_DEBUG=jit.dump` prints per-func machine bytes (`db3109d8`, compile.zig) + runtime entry
  addr (`f49b3675`, setup.zig) — the instruction-level lens the 4 prior IR-level c_sha256 attempts lacked.
- **`scripts/jit_value_trace.sh {addr|disasm|trace}`** (`39d53605`) automates the ~9-attempt lldb-on-JIT
  flow (disable-aslr stable addrs; arm `-H` bp AFTER the W^X page maps by stopping at a host symbol;
  llvm-mc disasm). VALIDATED: `-H` bp fires on a JIT page (func 11). Wired into debug_jit_auto Recipe 18
  + decision-tree + lesson `2026-06-15-lldb-value-trace-on-jit-code`.

**D-330 c_sha256 `\n` — MECHANISM CONFIRMED (`4365e478`, via the harness)**: c_sha256 is LINE-buffered
(3 fd_writes). Read iovecs at `jit_dispatch.zig:78`: write 1 (input) iov[1] len=1 → `\n` correct; write 3
(verify: OK) iov[0] len=**10** not 11, iov[1]=**{0,0}** → `\n` in NEITHER iovec. Buffered `wpos-wbase`=10
not 11: the final `putc('\n')` didn't advance `wpos` — `\n` dropped at buffer-construction. Same value-
miscompile family as discharged D-330 primary. **NEXT**: disasm/trace the wpos-store for the verify line
(jit_value_trace.sh). Deprioritized cosmetic (values+interp correct; 55/56 byte-exact). Trail: D-330 debt.

## Prior session — D-332 table-cap SHIPPED (`3cb5e3bf`) + D-330 coalescing/fp-select/D-289

**D-332** `3cb5e3bf`: `InstantiateOpts.max_table_elements` (default 10M) bounds the initial eager table
alloc (ADR-0179 amendment); debt deleted; follow-on (low value) = `--engine jit` CLI table cap.
**D-330 primary** `6790c204`: LSRA free-pool expiry coalesced a result vreg into a same-pc last-use
operand's slot (`<=`→strict `<`; ADR-0037 amend); emcc_fasta byte-exact. **EXPOSED latent x86_64
`emitFpSelect` spilled-cond clobber** → fixed `cccb2313` (TEST cond first). wasm-2.0-assert 25437/0 on
arm64 + Rosetta + ubuntu + Win64. **D-289** `682401fd`: regalloc cap 4095→65535 + allocator-backed.
Residual = the c_sha256 `\n` above (the func-8 framing in earlier handovers was DISPROVEN → func 4).

## ACTIVE AGENDA (user-directed 2026-06-14) — real-world toolchain/bench reproduction

Project is feature-complete + 3-host green + tag-ready (**tag = USER-ONLY, ADR-0156**).
D-238 x86_64 EH `c534afca`; cljw guest-wasm retired `02ef14b0` (cljw tests consumer-side).

**The agenda — drive via `/continue`. Authoritative plan (ordering + 2026 language
scope + the live JIT-trap inventory):**
[`realworld_reproduction_plan.md`](realworld_reproduction_plan.md) — its work sequence
supersedes ROADMAP §9 for these tasks. **User ordering: Phase A QUICK → Phase B
SUSTAINED**; the user assists when a toolchain needs installing.

- **Phase A — reproduction infra: DONE.** A1 Zig fixtures (`5c044967`; AssemblyScript/WasmGC →
  D-329) + A2 embenchen (`1aac480f`) + A3 `--wasmer` 2nd-oracle lane (`897b54d7`) + runtime bump
  (wasmtime 45 / wasmer 7.1). A4 remote rust provisioning = D-254; hyperfine = D-249. Details in plan.
- **Phase B — deep JIT bug-hunt (SUSTAINED).** B1 = D-283 `--jit` lane DONE (`219dbd17`); now working
  the remaining miscompiles (D-330 coalescing FIXED `6790c204`; see Phase-B status below). Multi-cycle.

**Tool currency (user directive 2026-06-14) DONE+VERIFIED on ALL 3 hosts**: Mac+ubuntu via
flake (wasmtime 45, wasmer 7.1, nixpkgs 06-10, rust/zig-overlay 06-14; **zig PINNED 0.16.0**;
ubuntu gate green `fa0381cd`). windowsmini native via `install_tools.ps1` (wasmtime 45/
wasm-tools 1.251/+wasmer 7.1) — user REBOOTED 2026-06-14, verified ACTIVE (post-reboot ssh:
wasmtime 45.0.0/wasm-tools 1.251.0/wasmer 7.1.0/zig 0.16.0). windows gate re-validating with
wasmtime 45 (verify next Step 0.7). D-249 hyperfine-absent premise dissolved.

**Phase A+B history (DONE, archived in commits/debt/lessons)**: A2 embenchen `1aac480f`; B1 = D-283
`--jit` diff-lane `219dbd17` (realworld_run 56/56); D-331(A) table-cap red-herring fix `45ff0b94`
(+ D-332). All detail in those commits + the cited lessons; not repeated here.

**Dogfooding milestone (2026-06-15)**: the `test-realworld-diff-jit` corpus is now **1 mismatch** — ONLY
`c_sha256_hash` (107 vs 106). emcc_fasta flipped to byte-exact MATCH; this session's D-330 coalescing +
fp-select + D-289 fixes cleaned the rest. The last `c_sha256` `\n` residual is **DEPRIORITIZED** (niche
cosmetic; values + interp correct): **4 hypotheses now DISPROVEN** (func-11/func-8/block-merge/numbering-
desync). Empirically: func 4 regalloc VALID (0 overlaps) AND liveness↔emit PERFECT LOCKSTEP (561=561, 0
per-pc divergence) → NOT regalloc, NOT a desync. So it's a genuine value-miscompile (10→0 at a branch)
needing RUNTIME instruction tracing — source-level guessing failed 4×; do NOT re-chase. (NOT the same as
go_regex/D-331B, whose emit DOES exceed liveness — the prior "unification" was wrong.) **NEXT: diversify —
the JIT-residual cluster is exhausted of cheap leads; pick a 完成形 surface/dogfooding/debt item (e.g. D-332).**

**Phase-B status**: D-283 `--jit` lane 3-host green (REPORT-ONLY). **D-330 coalescing miscompile FIXED**
`6790c204` + x86_64 fp-select `cccb2313` — 4-env green. Remaining JIT-correctness debt, each its own
investigation, ALL parked/blocked with recipes recorded: **D-330 residual** (c_sha256 `\n` → func-8
`__overflow` fast-path miscompile; NICHE, partial — next-probe recipe in debt) + **D-331(A)-next** go_*
runtime-corruption (panicmem teardown deref; INFRA-BLOCKED — needs per-function interp-fallback bisect,
which does not exist) + **D-331(B)/D-289** go_regex — regalloc cap RAISED `682401fd` (4095→65535 +
allocator-backed buffers, the 4th dynamic-vs-fixed instance; func[1516]/16070 vregs now clears regalloc+
prologue); remainder = a SEPARATE emit-side `vreg>=slots.len` mismatch (parked, recipe in debt). **NEXT
(diversify — all JIT items parked/blocked)**: best COMPLETABLE clean item = **D-332** (sandboxing-triad:
bound the INITIAL eager table alloc, cross-engine). Design to decide+ADR: `store_table_elements_max` is
set post-instantiation, so add an instantiation-TIME cap source — thread `max_table_elements: ?u64=null`
through the JIT `RunLimits` + interp instantiate config (+ C/Zig API), enforce at the initial table
alloc (setup.zig + instantiate.zig) as a clean trap (not OOM); default null = unlimited (no regression).
TDD: adversarial fixture w/ huge declared table.min + cap. (go bugs are fix-but-still-broken / niche.) (A1 Zig + A2
embenchen + A3 wasmer-oracle + runtime-bump + tool-currency-3host + B1 jit-diff-lane DONE; D-331 primary
`10d7d2b2` + (A) `45ff0b94`; D-330 coalescing `6790c204` FIXED.)

## State (tag-ready baseline, all 3-host green)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON (ADR-0182/0183; corpus 158/0/0). Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 (+preopen_dir/inherit_env, ADR-0184) · Zig-API
  complete (+`WasiConfig.{envs,preopens,io}` — full WASI parity) · lean CLI ·
  memory-safety sound · dogfooded into cw (consumer-side). Runners ReleaseSafe (ADR-0177,
  Rev 2026-06-14 floored `core_comp` too; `check_releasesafe_runners.sh` guards it).
- **EH**: cross-instance exception-handling on JIT works on BOTH arches (arm64 `4f73d9ee`
  + x86_64 D-238/ADR-0185 `c534afca`). Interp + JIT EH spec corpus green.
- **Debt**: 47 entries, **zero `now`**; all blocked-by are external (upstream
  Zig / hosts) / future-phase (11/12/14) / user-gated, or `note`/`partial` long-tail.
  D-283 Phase-B anchor; D-330 (%s) + D-331 (go, primary + (A) FIXED, miscompile-next) + D-332 JIT-debt.
- **Realworld corpus**: 50 fixtures (c/cpp/rust/tinygo/go), interp 50/50; JIT run-stage
  opt-in (`ZWASM_JIT_RUN=1`) — the Phase-B signal source. cljw fixtures retired.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`realworld_reproduction_plan.md`](realworld_reproduction_plan.md) — the ACTIVE
  AGENDA's full plan. [`flake.nix`](../flake.nix) `devShells.gen` — fixture toolchains.
- [`docs/zig_api_design.md`](../docs/zig_api_design.md) · **ADR-0185** (x86_64 EH
  frame-walk) · **0177** (ReleaseSafe runners) · **0156** (NO autonomous release) ·
  **0153** (rework) · **0109** (Linker/facade API).
- lessons [`releasesafe-runner-floor-audit`] · [`global-predicate-cannot-replace-local-codemap`].
