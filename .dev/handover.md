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

## Active state — **Phase 9 extended; m-2a landed 2026-05-12**

§9.11 [x]; §9.10 [~] Phase 11; §9.12 [ ] 🔒 (waits §9.9);
**§9.9 [ ]** scope = full Wasm 2.0 PASS on Mac+OrbStack per
ADR-0056. m-2a adds JIT `table.get` / `table.set` / `table.size`
both arches (4th-gen JitRuntime ABI extension: `TableSlice` +
`tables_ptr`). Mac aarch64 + OrbStack test-all green incl. 5
new p9/table_ops edge_cases fixtures (size_initial /
get_null_funcref / set_get_roundtrip / get_oob / set_oob).
Live counts in `bash scripts/p9_simd_status.sh`.

12 chunks landed across the §9.9 close window so far. 7 debt
rows discharged. 3 ADRs (ADR-0055, ADR-0056, ADR-0058)
accepted; ADR-0003 amended; ADR-0017 implicit Revision
extensions x4 (m-1b, m-3a, m-3b, m-2a TableSlice).

## Implementation queue (sequential — pickup detail in pickup doc)

Next session picks up at **m-2b**. Order:

1. **m-2b NEXT** — table.grow + table.fill both arches. grow
   returns -1 on OOM/max (spec §4.4.13; runtime-helper call);
   fill = inline loop. Builds on m-2a's `tables_ptr` TableSlice
   shape per ADR-0058. The TableSlice.max field (m-2a allocated
   but currently unused) is consumed here by the grow cap check.
2. m-2c — table.copy + table.init. memmove semantics for copy;
   init reads `elem_dropped_ptr` (already in JitRuntime). Closes
   m-2 cluster.
3. m-4c — untyped .select (0x1B) lower-time type inference.
4. l-1 — non-SIMD spec_assert_runner. ADR-0057 expected.
5. k-1 — Wasm 2.0 non-SIMD wast vendor (~30 files).
6. k-2 — SIMD wast vendor (33 files).
7. n-1 — fib2 perf root cause.
8. j-3b — SKIP gate real enforcement (last).

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

- `private/p9-close-next-session-pickup.md` — **read first**
  on next session. Per-chunk recipes, file paths, design notes,
  edge cases, test fixture suggestions.
- `private/d084-phase10-scope.md` — Win64 ABI agent (history).
- `private/p9-x-wasm2-non-simd-coverage.md` — coverage audit.
- `private/p9-y-tests-bench-audit.md` — bench/tests audit.
- `private/p9-z-realworld-v1-parity.md` — realworld + v1 parity.

TaskList state in CLI mirrors this queue (#3 m-2b + #4 m-2c
pending; #2 m-2a completed).
