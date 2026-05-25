# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8 (ARCHIVED-IN-PLACE 2026-05-25; cite-only).
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)。
- **Last commit**: `b10922d2` — J.5 Linker + Caller + host imports
  (ADR-0109 §3.2)。`src/zwasm/{linker,caller,host_func_marshal}.zig`
  新規; `api/instance.zig::instantiateInternal` 抽出により c_api と
  native の instantiation 経路を共有化。
- **Phase 9 close invariants gate (mac-host)**: **18/18 PASS** 維持。
- **Mac `zig build test`**: 1823/1837 passed (14 skipped); lint clean。
  J.5 で新規 +4 test: T1.9 host add / T1.10 caller.memory poke /
  T1.11 SignatureMismatch / T1.12 cross-instance memory sharing。
- **ubuntu test**: HEAD `b10922d2` を post-push でバックグラウンド
  kick 予定 — 次 resume Step 0.7 で verify。

## Active task — 10.J impl train (J.6 next)

ADR-0109 Accepted 2026-05-25。`/continue` loop は J.6..J.close まで自走。

| Sub-chunk | Scope | Gate | Status |
|---|---|---|---|
| J.2 | Engine + Module skeleton | substrate | CLOSED `017193bc` |
| J.3 | Instance + untyped invoke + full Trap | substrate | CLOSED `698c23ce` |
| J.4 | TypedFunc + Memory + multi-result | substrate | CLOSED `995270cf` |
| J.5 | Linker + Caller + host imports | substrate | **CLOSED `b10922d2`** |
| **J.6 NEXT** | Tier-2 `zig_facade_runner` (150-fixture parity) | **cohort** | 着手準備完了 |
| J.7 | WASI defineWasi skeleton | substrate | J.6 後 |
| J.close | Coverage audit + D-075 close + ROADMAP 10.J [x] | substrate | J.7 後 |

**J.6 exit criterion** (per plan §3 J.6):
(a) `zig build test-api-zig-facade` runs the runner exe;
(b) cljw_* (5 fixtures) all PASS;
(c) Non-WASI realworld fixtures (~45) report sensible pass/fail;
(d) p7 edge-case fixtures all PASS or produce expected `.expect`;
(e) WASI fixtures emit SKIP with reason;
(f) `test-all` aggregate GREEN with new step wired in。
新 `test/api/zig_facade_runner.zig` (~400 LOC) + `build.zig`
変更 (~30 LOC) + 新 debt row D-176 (WASI defineWasi deferred to J.7)。
Gate class **cohort** → Mac `zig build test-all` foreground。
詳細 plan §3 J.6。

## Known plan latent issues

- **S-4** (J.close): "100% public-symbol coverage" vs coverage matrix の
  "deferred" 行 (`defineGlobal`/`defineTable`) の自己矛盾を J.close 時に
  exit criterion を "100% except D6 defer" に reframe。

## Phase 10 progress

ROADMAP §10 = 13-row task table (10.0/10.C9 done; 10.J active;
10.F/10.Z/10.D/10.T/10.M/10.R/10.TC/10.E/10.G/10.P pending; Phase 10
は 10.J close 時点では大半未完)。

## Key refs

- **Plan**: [`phase10_zig_api_plan.md`](./phase10_zig_api_plan.md) §3 (J.6 → J.close)
- **ADR-0109**: [`decisions/0109_native_zig_api_inversion.md`](./decisions/0109_native_zig_api_inversion.md) (Accepted + amended 2026-05-25 row 3)
- **Phase 10 全体設計**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md) §3.1-§3.6
- **Zig API spec**: [`../docs/zig_api_design.md`](../docs/zig_api_design.md)
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
