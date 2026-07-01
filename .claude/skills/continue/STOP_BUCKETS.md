# Stop conditions — full whitelist

> **RETIRED CAMPAIGN MACHINERY (2026-07-01).** The autonomous loop's stop-bucket
> whitelist. In maintenance mode there is no auto-continue: a task ends at its
> natural boundary (PR opened) — see `SKILL.md`. Any `zwasm-from-scratch` /
> direct-push references below are historical.

Sibling of [`SKILL.md`](SKILL.md). The `/continue` loop stops ONLY for
one of the 3 buckets below. Anything else continues.

## Bucket 1 — User explicitly intervenes

A new directive arrives, the user interrupts, asks for pause, or types
a message incompatible with continuing. The user typing **nothing** is
NOT intervention.

## Bucket 2 — Genuinely unsolvable problem

- Root cause unclear after investigation.
- Load-bearing trade-off conflicts with ROADMAP §2 (P/A) or §14
  (forbidden list).
- Required external host (`ubuntunote`, `windowsmini`) is **provably
  absent** — and "provable" means [`extended_challenge.md`](../../rules/extended_challenge.md)
  Steps 1+2 actually ran and confirmed structural absence. "I assume
  it's absent" is NOT a proof.

Document the blocker in handover.md "Open questions / blockers" (with
the Step 1+2 evidence trail), then stop.

## Bucket 3 — All forward work user-input-gated AND autonomous prep walked

Every remaining ROADMAP / close-plan row is blocked on a user
touchpoint (ADR `Status: Proposed → Accepted` flip, collaborative
review, etc.); AND `.dev/debt.yaml` has zero `now` rows AND no
`blocked-by:` barrier dissolved this resume; AND the autonomous prep
paths for each gating ADR have been walked.

In bucket 3: surface the specific user touchpoint(s) needed and stop
**WITHOUT `ScheduleWakeup` re-arm**. User resumes by satisfying the
gate.

**Distinct from "User can /continue when ready"** (forbidden
anti-pattern): that surrenders forward work that IS autonomous-
eligible. Bucket 3 fires only after every autonomous lever pulled and
the remaining work *structurally* needs the user.

**NOT a bucket-3 gate (ADR-0132)**: "a phase's exit/scope references
work scoped to a later phase" is NOT a user touchpoint — re-sequence/
re-scope the ROADMAP autonomously (ADR + §18.2 four-step + forward-ref
each deferred item). A row blocked only by such a mismatch is
autonomous-eligible, not bucket-3.

Handover.md framing for bucket-3: see
[`handover_doc_discipline.md`](../../rules/handover_doc_discipline.md)
§4 ("Bucket-3 stop — user touchpoint required").

### Autonomous prep paths for user-gated ADRs

Before bucket 3 fires, attempt each path applicable to the gating ADR.
Each path produces value the user can review at flip time — NOT "wait
around" work.

- **Reference-repo enrichment** — read v1
  (`~/Documents/MyProducts/zwasm/`), wasmtime / cranelift / wasm3 /
  regalloc2 / spec testsuite (`~/Documents/OSS/`). Append concrete
  file / line citations to the ADR's `References` or `Alternatives`.
  Commit: `chore(adr): enrich NNNN references from <source>`.
- **Throwaway spike** — under `private/spikes/<adr-slug>/` per
  [`spike_discipline.md`](../../rules/spike_discipline.md). Prototype
  the ADR's chosen path or rejected alternative. Outcome → Status:
  rejected lesson OR ADR `Consequences` refinement. Spike work is
  autonomous; on-branch impl stays gated.
- **Consequences refinement** — re-walk ADR's `Consequences` /
  `Removal condition` text against current code state. Dissolved /
  sharpened consequence → ADR edit (Revision history footer per
  `.dev/decisions/README.md`).
- **WebFetch spec / upstream** — for ABI / spec / upstream-API ADRs,
  fetch the authoritative doc (W3C Wasm spec, Arm IHI 0055, Intel SDM,
  MSDN, ziglang/zig issues). Cite URL in ADR References. Per
  `extended_challenge.md` Step 4.

ALL applicable paths walked for ALL gating ADRs → bucket 3 unlocked.
Record the walked-paths list in handover.md "Open questions / blockers"
so the next resume doesn't re-walk.

## Non-stop conditions (explicit, exhaustive)

Encountering any of these means **continue the loop**. If you reach
for one to justify stopping, you are violating this skill.

### Phase / scaffolding state — never a stop on its own

- A Phase boundary just closed (§9.<N> → §9.<N+1>); §9.<N> table
  empty; multiple `[x]` flips + SHA backfills pending.
- The next task is "big" / N commits have already landed / you
  produced a long status summary and feel like a good stopping point —
  loop-discipline traps, not stop signals.
- An `audit_scaffolding` finding is `block` — fix locally if scope is
  local, else file ADR + queue in handover. Either path continues.

### Delegation / autonomous mechanics — handle and continue

- Next task needs Explore / Plan / Bash subagent — fork and continue.
- Next task requires `git push` — push and continue (see Push policy
  in [`LOOP.md`](LOOP.md)).
- `windowsmini` gate failed because commit isn't yet on origin — push
  and re-run, then continue.
- Context fill high or auto-compact looks imminent — `PostCompact`
  hook recovers state. Never a pre-emptive stop.

### User signal — silence is NOT intervention

- User has not replied for a long time — that is the **point** of the
  skill.

## Destructive-action policy — autonomous within scope

The harness's general "ask before destructive" guidance does NOT gate
the autonomous loop on these local, reversible actions. Run without
confirmation:

- `rm <file>` / `rm -r <dir>` / `rm -rf <dir>` for paths under
  `private/`, `.zig-cache/`, `zig-out/`, `/tmp/`, scratch artifacts
  you just created.
- `mv` / `cp` / `mkdir` / `rmdir` for the same scope.
- `git stash` / `git restore <path>` / `git checkout -- <path>` to
  discard uncommitted local edits when re-starting after auto-compact.
- `git reset <commit>` (mixed / soft) on local `zwasm-from-scratch`
  when working tree is yours alone. `git reset --hard` remains denied
  by `.claude/settings.json` and is a bucket-2 stop if genuinely needed.

Out of scope (still ask user / stop):

- `rm -rf /`, `rm -rf ~/`, `rm -rf $HOME`, `rm -rf .git` — denied in
  `.claude/settings.json`.
- Anything outside project working tree + `additionalDirectories` in
  settings.json.
- `git push --force` / `--force-with-lease` — denied; main push
  forbidden by §14.

## If unsure whether to stop

**Don't.** The user will interrupt if needed.
