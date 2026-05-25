# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8 (ARCHIVED-IN-PLACE 2026-05-25; cite-only).
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)。
- **Last commit**: `97434726` — J.6 Tier-2 `zig_facade_runner`
  (test-only)。`test/api/zig_facade_runner.zig` 新規 + build.zig
  `test-api-zig-facade` step + test-all dep。55 realworld fixtures
  全 SKIP-WASI (D-176 開設; J.7 で flip)。
- **Phase 9 close invariants gate (mac-host)**: **18/18 PASS** 維持。
- **Mac `zig build test`**: 1823/1837 passed (14 skipped); lint clean。
  J.6 は test-only — src 変更なし; 既存 in-source tests に影響なし。
- **ubuntu test**: HEAD `97434726` を post-push でバックグラウンド
  kick 予定 — 次 resume Step 0.7 で verify。

## Active task — 10.J impl train (J.7 next; J.6 unlock predicate)

ADR-0109 Accepted 2026-05-25。`/continue` loop は J.7..J.close まで自走。

| Sub-chunk | Scope | Gate | Status |
|---|---|---|---|
| J.2 | Engine + Module skeleton | substrate | CLOSED `017193bc` |
| J.3 | Instance + untyped invoke + full Trap | substrate | CLOSED `698c23ce` |
| J.4 | TypedFunc + Memory + multi-result | substrate | CLOSED `995270cf` |
| J.5 | Linker + Caller + host imports | substrate | CLOSED `b10922d2` |
| J.6 | Tier-2 zig_facade_runner | substrate | **CLOSED `97434726`** |
| **J.7 NEXT** | WASI `defineWasi` skeleton + smoke + D-176 close | substrate | 着手準備完了 |
| J.close | Coverage audit + D-075 close + ROADMAP 10.J [x] | substrate | J.7 後 |

**J.7 exit criterion** (per plan §3 J.7):
(a) Tier-1 T1.13 `linker.defineWasi(.{ .args = &.{}, .env = &.{}, .stdin = ... })`
+ instantiate a minimal WASI module succeeds (no syscall actually exercised);
(b) zig_facade_runner WASI fixtures move from SKIP-WASI to PASS
(instantiation-only) or proper-FAIL (real syscall needed → still SKIP
with phase-11 reason);
(c) D-176 closes (this commit's pair commit message body).
新 `src/zwasm/wasi_config.zig` (~60 LOC) OR inline in linker.zig;
EDIT `src/zwasm/linker.zig` (add `defineWasi`);
EDIT `test/api/zig_facade_runner.zig` (un-SKIP WASI with smoke-test mode)。
Full WASI semantics + per-syscall surface は Phase 11 scope (新 debt
D-177 を J.7 中に open)。詳細 plan §3 J.7。

## Known plan latent issues

- **S-4** (J.close): "100% public-symbol coverage" vs coverage matrix の
  "deferred" 行 (`defineGlobal`/`defineTable`) の自己矛盾を J.close 時に
  exit criterion を "100% except D6 defer" に reframe。

## Phase 10 progress

ROADMAP §10 = 13-row task table (10.0/10.C9 done; 10.J active;
10.F/10.Z/10.D/10.T/10.M/10.R/10.TC/10.E/10.G/10.P pending; Phase 10
は 10.J close 時点では大半未完)。

## Key refs

- **Plan**: [`phase10_zig_api_plan.md`](./phase10_zig_api_plan.md) §3 (J.7 → J.close)
- **ADR-0109**: [`decisions/0109_native_zig_api_inversion.md`](./decisions/0109_native_zig_api_inversion.md) (Accepted + amended 2026-05-25 row 3)
- **Phase 10 全体設計**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md) §3.1-§3.6
- **Zig API spec**: [`../docs/zig_api_design.md`](../docs/zig_api_design.md)
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
