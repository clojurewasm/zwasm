# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).
5. **Read `private/p9-close-next-session-pickup.md`** — full
   per-chunk pickup chain (recipes, file paths, ADR notes) for
   the queue below. Authoritative for next session continuation.

## Active state — **Phase 9 extended; D-091 discharged 2026-05-12**

### One-line state

D-091 closed: x86_64 `i32.trunc_f64_s` lower-bound predicate
now uses `-(2^31 + 1.0)` with `JBE`. Mac + OrbStack
`test-spec-wasm-2.0-assert`: **6518 / 0 / 102 bit-identical**
(0 skip-impl + 102 skip-adr-skip_text_format_parser; latter
unrelated to D-091). simd_assert 13301/0/440 + spec_assert
212/0/20 unchanged.

### Standing reminder for the autonomous loop

**Project tone is `.claude/rules/no_workaround.md`: fix root
causes, never work around.** Even when investigation cost
looks high. See
`.dev/lessons/2026-05-12-loop-defers-over-fixes-when-cost-high.md`
for the recurring failure mode. Skip-ADRs are for ADR-grade
upstream workarounds; debt rows are for structurally blocked
work. Neither is a scheduling smoother. On the next chunk's
first obstacle, walk `extended_challenge.md` Step 1 (confirm
what's absent, with a concrete command) BEFORE reaching for
a filter / fallback / skip-ADR. Pivoting to a cheaper chunk
to avoid investigation is forbidden.

### Next task — **single track**

**D-092 root-cause investigation** (no alternative branch).
Identify which op or precondition in `f32.0.wasm` / `f64.0.wasm`
trips `compileWasm` with `UnsupportedOp` on x86_64. The
investigation procedure is in the D-092 debt row body
(`.dev/debt.md`): bisect via the NAMES list + targeted
stderr capture; instrument `Module.compile` if needed; then
fix the handler / lift the gate; then re-add `f32` + `f64`
to `scripts/regen_spec_2_0_assert.sh`. Three-host gate
bit-identical confirms discharge.

Forbidden discharge paths: per-op skip-ADR for an op the
runtime should support; widening the regen filter to mask
the failure; pivoting to k-1-expand-2 or any other chunk
before D-092 is closed.

### Original m-2 cluster state (earlier this session)

§9.11 [x]; §9.10 [~] Phase 11; §9.12 [ ] 🔒 (waits §9.9);
**§9.9 [ ]** scope = full Wasm 2.0 PASS on Mac+OrbStack per
ADR-0056. m-2 cluster base scope (a + b + c + c-init) landed
this session: JIT `table.get` / `table.set` / `table.size` /
`table.fill` / `table.copy` / `table.init` both arches per
ADR-0058 (+ amendment). JitRuntime ABI extended with TableSlice
+ ElemSlice (head_size 152 → 184 bytes). 18 new p9/table_ops
edge_cases fixtures (size_initial / get_null_funcref /
set_get_roundtrip / get_oob / set_oob / fill_happy / fill_oob /
fill_n_zero / copy_same_table_forward / copy_same_table_backward /
copy_cross_table / copy_oob_dst / copy_oob_src / init_happy /
init_oob_dst / init_oob_src / init_dropped / init_n_zero). Live
counts in `bash scripts/p9_simd_status.sh`.

16 chunks landed across the §9.9 close window so far. 7 debt
rows discharged. 3 ADRs (ADR-0055, ADR-0056, ADR-0058 + 1
amendment) accepted; ADR-0003 amended; ADR-0017 implicit
Revision extensions x6 (m-1a, m-1b, m-3a, m-3b, m-2a TableSlice,
m-2c-init ElemSlice).

## Implementation queue (sequential — pickup detail in pickup docs)

Next session picks up at **D-092** (single track — no
alternative branch listed; that was the failure mode this
lesson corrects). See the standing reminder above + the
D-092 debt row body for the investigation procedure.
k-1-expand-2 + any other chunk wait until D-092 closes.

Per-stage state of l-1 (l-1a all complete; l-1b in progress):

| Stage | Status | What |
|---|---|---|
| l-1a-1..6 | [x] | base extraction + runCorpus + arg-parser + makeJitRuntime hoists |
| l-1b-runner | [x] bff477f5 | new spec_assert_runner_non_simd.zig + test-spec-wasm-2.0-assert + test-all wiring |
| l-1b-corpus | [x] 3b92bed6 | regen_spec_2_0_assert.sh + conversions starter (37/0/581) |
| l-1b-widen  | [x] 774ae3c8 | 10 cross-type entry helpers + dispatch arms + boundary skip-adr (493/0/125) |
| l-1b-nan    | [x] 207330be | scalar NaN-pattern result matcher in base (501/0/117) |
| l-1b-trap-widen | [x] a7bf59d8 | assert_trap f32/f64 arms + i32.wrap_i64 shape (567/0/51; **skip-impl 0**) |
| k-1-expand-1 | [x] 894e0e00 | 6 binop helpers + 7 wasts (i32/i64/f32_cmp/f64_cmp/int_exprs/int_literals/float_literals); 6467/0/153 (**skip-impl 0**); D-092 filed |
| D-091-close | [x] f22acf6c | x86_64 i32.trunc_f64_s lower-bound `-(2^31+1)` + JBE; 6518/0/102 (**skip-impl 0**, **D-091 boundary skip-adr → 0**) |
| **D-092** | **NEXT (sole track)** | **x86_64 f32/f64 module UnsupportedOp — root-cause investigation, not deferral** |

Then l-1b (new spec_assert_runner_non_simd.zig + curated wasm-2.0
corpus + test-spec-wasm-2.0-assert build step).

Other queued chunks (post-l-1):
- k-1 — Wasm 2.0 non-SIMD wast vendor (~30 files); blocked by l-1b runner.
- k-2 — SIMD wast vendor (33 files); standalone after l-1.
- m-4c (= D-090) — untyped .select non-i32 type inference; needs
  lower.zig type-stack walker.
- m-2d — table.grow JIT with allocator-helper infrastructure.
- n-1 — fib2 perf root cause (22KB Rust-WASI binary; 41s/run).
- j-3b — SKIP gate real enforcement (last).
2. k-1 — Wasm 2.0 non-SIMD wast vendor (~30 files).
3. k-2 — SIMD wast vendor (33 files).
4. m-4c (= D-090) — untyped .select non-i32 type inference.
   Needs lower.zig type-stack walker mirroring the validator's
   per-op type tracking. Filed as debt D-090 with concrete
   discharge plan.
5. m-2d — table.grow JIT with allocator-helper infrastructure.
   Last piece of the m-2 cluster; needs `*const Allocator`
   surfacing into JitRuntime via opaque-state pointer + helper
   function pointer.
6. n-1 — fib2 perf root cause (22KB Rust-WASI binary; 41s/run
   on Mac). Requires JIT profiling infra; investigation chunk.
7. j-3b — SKIP gate real enforcement (last).

## Sandbox quirks + hook scope

- `~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- OrbStack daemon log-rotation panic — restart via
  `pkill -9 -f OrbStack && open -a OrbStack`.
- `scripts/run_remote_windows.sh` mDNS flake — direct
  `ssh windowsmini ...` works.
- Per-chunk 2-host (Mac+OrbStack) per ADR-0049; windowsmini
  reconcile only at §9.9 close (Win64 already done via i-1).

## Open debt — see `.dev/debt.md`

- `now`: none (7 discharged this session).
- `blocked-by`: D-007/010/016/018/020/021/022/026/028/052(partial)/
  055/057/058/059/062(partial)/065/072/073/074/075/079(ii)/
  081/082.

## Reference chain for next /continue

- **`private/l-1a-next-session-pickup.md`** — **read first on
  next session**. l-1a stages 1-3 done; stage 4 (runCorpus
  extraction) recipe inline. Mandatory for resuming.
- `.dev/decisions/0057_spec_assert_runner_factoring.md` — ADR
  for the factoring design (Option B accepted).
- `.dev/decisions/0058_table_ops_jit_design.md` — m-2 cluster
  TableSlice + ElemSlice ABI design + amendment.
- `private/notes/p9-99-l-1-spec-assert-survey.md` — factoring
  boundary survey for spec_assert_runner.
- `private/notes/p9-99-m-2-table-survey.md` — m-2 cluster survey.
- `private/p9-close-next-session-pickup.md` — original §9.9
  close pickup (now superseded by l-1a pickup for the
  active chunk; still useful for the broader queue context).
- `private/d084-phase10-scope.md`, `private/p9-x-wasm2-non-simd-
  coverage.md`, `private/p9-y-tests-bench-audit.md`,
  `private/p9-z-realworld-v1-parity.md` — Agent W/X/Y/Z
  investigation reports.

TaskList state in CLI mirrors this queue (#5 m-2d + new m-4c
pending; #2/#3/#4/#6 m-2a/b/c/c-init completed).
