---
paths:
  - "src/**/*.zig"
  - "build.zig"
  - "scripts/**"
  - ".claude/skills/continue/**"
---

# Extended challenge — when stuck, attempt self-resolution before stopping

> Lean stub (ADR-0118 D2). Full detail / examples / rationale / checklists: [`../references/extended_challenge.md`](../references/extended_challenge.md).

## Invariant

Before STOPPING / surfacing "external host/tool/file/binary absent" OR treating a failing infra step as blocked, MUST walk:

- **Step 1** — Confirm the SPECIFIC absence with one command (no guessing).
- **Step 2** — Self-provision if in scope: `git clone` / `nix|apt install` on project-managed env / `mkdir|cp|chmod` in tree / re-run a setup script. Out of scope (ask user): global system config, non-project-managed installs, network mounts/creds/secrets, `sudo` outside sandbox.
- **Step 3** — Only then surface, naming the specific absence + Step-2 attempts + a specific proposed user action.

Tie to `/continue` stop bucket-2: "**provably** absent" REQUIRES Steps 1+2 to have actually run. "I assume it's absent" is not a proof.

### Forbidden anti-patterns

- "It might not work, so I'll skip" — the only valid skip is Step 3, after Steps 1+2 ran.
- "I added a SKIP-X-MISSING fallback to make the gate pass" — workaround; forbidden unless paired with an ADR or a `D-NNN` debt row naming the structural barrier.
- "User will figure it out next session" — stop antipattern.

## Enforcement

Prose discipline + `/continue` loop self-audit + reviewer checklist (see reference). `audit_scaffolding` re-runs the Step-1 anchor commands periodically.

## Key cases

- **Step 4** — mid-cycle 裏取り (WebFetch/WebSearch, reference-repo deep-read, spike, `debug_jit_auto`) is autonomously allowed; cite the source (URL in commit/ADR, file+line in survey note, spike → ADR/lesson).
- **Step 5** — multi-cycle hard bugs SHOULD land at least one PERMANENT diagnostic primitive each cycle (counter / fault-address capture / dumper / `debug_jit_auto` recipe / rule), not throwaway probes.
- "wasmtime not on PATH" vs "stub exits 0 but `run` fails" are different absences demanding different responses — Step 1 output must be specific.

Everything else (per-step detail, Phase 6 case study, D-142 chain, reviewer checklist, stale-ness): [`../references/extended_challenge.md`](../references/extended_challenge.md).
