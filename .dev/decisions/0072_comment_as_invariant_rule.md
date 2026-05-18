# 0072 — Comment-as-invariant rule

- **Status**: Proposed
- **Date**: 2026-05-19
- **Author**: continue loop §9.12 substrate audit cycle
- **Tags**: phase-9, hygiene, rules, comment-discipline, regression-prevention

> **状態**: skeleton。§9.12-pre で full draft に展開。

## Context

D-132 / D-133 (arm64 `op_table.zig` の hardcoded X10/X11/X12 scratch register) が
顕在化した経緯 (詳細: `.dev/lessons/2026-05-16-regalloc-pool-scratch-overlap.md`):

- `op_table.zig` のコメントに「X10/X11/X12 are private scratch within the handler」
  と書かれていたが、これは prose-only invariant でコード強制無し
- regalloc は同 register slot を allocatable scratch として使用
- ある corpus + nested-table-op の組合せで両者が同時に同 slot を要求し latent な
  silent corruption (D-132 root cause)
- Lesson が示唆: prose invariant が **comment-as-invariant** という anti-pattern を
  作っている

これは Phase 9 完備 substrate audit Q5 (substrate hygiene) で識別された 5 つの
trigger の 1 つ。詳細: `.dev/phase9_completion_substrate_audit.md` §Q5。

## Decision

`.claude/rules/comment_as_invariant.md` 新設 (auto-load on `src/**/*.zig`):

> プロセに不変条件 (= "X は常に Y" / "X は private scratch" / "X は alignment N"
> 等) を書くときは、必ず以下のいずれかと組:
> (a) `comptime assert`
> (b) runtime `std.debug.assert`
> (c) lint script (`audit_scaffolding §G grep`)
> (d) 削除 (= 不要なら書かない)
>
> 違反例: `op_table.zig` の "X10/X11/X12 are private scratch" コメント (D-132 /
> D-133 failure mode の元)。修正例: 該当の register を `abi.zig` に named
> constant 化 + comptime disjointness check 拡張。

### Enforcement

- `.claude/rules/comment_as_invariant.md` (auto-load rule)
- `audit_scaffolding §G` grep 拡張 (D-132 / D-133 検出強化)
- §9.12-C で D-133 sweep (op_table / op_memory の hardcoded register-numeral を
  named-constant 経由に置換)

## Alternatives considered

> Skeleton — §9.12-pre で展開。

## Consequences

- **Positive**: 同 class の latent bug を予防 (= regalloc / ABI 不変条件が code-level
  で強制される)
- **Negative**: 既存コメントの sweep 必要 (D-133 で実施)
- **Neutral / follow-ups**: `bug_fix_survey` 規律 (sibling sites grep) と組み合わせて
  catch coverage を上げる

## References

- `.dev/lessons/2026-05-16-regalloc-pool-scratch-overlap.md` (D-132 root cause)
- D-133 (op_table sweep — §9.12-C で discharge)
- ADR-0071 (Phase 9 substrate audit resolution; Q5 deliverable の 1 つ)
- ADR-0018 (regalloc reserved set; 同 class の comptime check の先例)
- `.dev/phase9_completion_substrate_audit.md` §Q5

## Revision history

| Date       | SHA          | Note                                                         |
|------------|--------------|--------------------------------------------------------------|
| 2026-05-19 | `<backfill>` | Initial skeleton — Q5 deliverable; full draft in §9.12-pre.  |
