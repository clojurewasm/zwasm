---
description: "Test discipline — boundary fixture obligation at code-write time (気付いたら即追加) + bug-fix-time same-class-cases grep before patching symptom. Absorbs former edge_case_testing.md + bug_fix_survey.md per ADR-0118 D3."
paths:
  - "src/**/*.zig"
  - "test/**/*.zig"
  - "test/edge_cases/**"
  - "build.zig"
---

# Test discipline

> Lean stub (ADR-0118 D2). Full detail / examples / rationale / checklists: [`../references/test_discipline.md`](../references/test_discipline.md).

## Invariant

- **§1** Crossing a numeric / alignment / register-pressure / dispatch / ABI / control-flow / validator boundary → ADD a boundary fixture (`test/edge_cases/p<N>/<concept>/<case>.{wat,wasm,expect}`) in the SAME commit (unless one exists).
- **§2** Before fixing a bug at one site → grep siblings (same symbol / shape) and fix all, OR document the exemption.
- **§3** Inline-asm test wrappers invoking FP-chain-walking code MUST install a `[2]usize align(16)` sentinel `{0,0}` as initial X29 (arm64) / RBP (x86_64). Else SysV x86_64 host-FP-walk corrupts `@errorReturnTrace()` → heisenbug SEGV in an unrelated test.
- **§4** Host-conditional test gates (`if (!(macos and aarch64)) return error.SkipZigTest;`) MUST cite a spec-pinned rationale OR a `D-NNN` debt row. Never bare.

## Enforcement

- §1: `scripts/p<N>_*_status.sh` + `audit_scaffolding §I` (fixture `.wasm`↔`.wat` sync, ADR-0020).
- §2: bug-fix-time grep (`rg -n '<symbol>' src/`); see [`bug_fix_grep_procedure.md`](../references/bug_fix_grep_procedure.md).
- §3 / §4: reviewer checklist at Step 4 / pre-commit (see reference).

## Key cases

- §1 fixtures target **observable spec-defined boundaries**, not type-system-enforced / trivially-mechanical / internal-only invariants.
- Fixture-internal workaround (`// FIXME`/`// TODO`/`// HACK`/bypass-constant) → paired `D-NNN` row same commit.
- Test-side JIT byte offsets MUST go via prologue helper, not hardcoded literals (exception: opcode-pinned first two prologue words).
- §2 skip OK for trivial fixes, type-system errors, refactor-rename via `replace_all`. If unsure, run the grep.
- §4 forbidden gate-comment phrasing: "Mac-only path is fully wired; verify there first" / "Linux x86_64 SysV is gated behind ..." (no concrete ref) / bare `if (!(macos and aarch64))` with no comment.

Everything else (stress-axis table, `.expect` format, canonical sentinel asm, D-027/D-180 case studies, anti-patterns): [`../references/test_discipline.md`](../references/test_discipline.md).
