# 0070 — libc dependency policy

- **Status**: Proposed
- **Date**: 2026-05-19
- **Author**: continue loop §9.12 substrate audit cycle
- **Tags**: phase-9, libc, dependency-boundary, posix, hygiene

> **状態**: skeleton。§9.12-pre で full draft に展開。

## Context

Phase 9 完備 substrate audit (ADR-0062 §9.12 Q6) で識別された問題:
- v2 は signal recovery で `sigsetjmp` / `siglongjmp` を libc 経由で使う
- `std.c.*` 系の呼び出しが各所に分散 (`std.c.write` / `_exit` / `getenv` /
  `munmap` 等; <100 sites)
- Zig 0.16 stdlib は buildable-without-libc 方向に進んでいる
- AOT (Phase 12) / Windows-native (Phase 13+) で libc 依存が boundary 問題化する

詳細: `.dev/phase9_completion_substrate_audit.md` §Q6。

## Decision

`std.c.*` 呼び出しを 3 区分に分類し、新規呼び出しは ADR 改正なしには追加不可とする。

### 区分

| 区分 | 例 | 取扱 |
|---|---|---|
| **necessary** | `sigsetjmp` / `siglongjmp` (Zig stdlib に無し); `pthread_jit_write_protect_np` (Darwin W^X) | 維持; Zig stdlib 追加待ち (Issue link 必須) |
| **replaceable** | `std.c.write` / `_exit` / `getenv` / `munmap` 等 | `std.posix.*` / `process.Environ` に migrate |
| **convenience** | `std.heap.DebugAllocator` (Debug build) | Debug build only で容認 |

### Enforcement

- `.claude/rules/libc_boundary.md` auto-load on `src/**/*.zig` (rule)
- `scripts/check_libc_boundary.sh` (新規 std.c.* 検出 + 区分照合 grep)
- `audit_scaffolding §G.5` 拡張
- ROADMAP §14 forbidden list amendment: "Unconscious libc fanout"

### Sample migration

§9.12-D で `std.c.{write,_exit,getenv,munmap}` の ~5-10 sites を `std.posix.*` 化
(rule has teeth の証明)。

## Alternatives considered

> Skeleton — §9.12-pre で展開。

## Consequences

- **Positive**: AOT / Windows / 将来 embedded target で libc 解放が容易
- **Negative**: 既存 ~100 site の段階的 migration が必要 (D-NNN sweep として)
- **Neutral / follow-ups**: necessary 区分の項目を Zig stdlib upstream PR で追跡

## References

- ROADMAP §14 (forbidden list amendment), §11 layers
- ADR-0067 (ubuntunote host pivot; D-134 Rosetta) — libc 信頼性問題の発端の 1 つ
- ADR-0071 (Phase 9 substrate audit resolution; Q6 deliverable の 1 つ)
- `.dev/phase9_completion_substrate_audit.md` §Q6

## Revision history

| Date       | SHA          | Note                                                          |
|------------|--------------|---------------------------------------------------------------|
| 2026-05-19 | `<backfill>` | Initial skeleton — Q6 deliverable; full draft in §9.12-pre.   |
