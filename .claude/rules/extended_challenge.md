# Extended challenge — when stuck, attempt self-resolution before stopping

Auto-loaded when editing Zig sources, build files, or running the
`/continue` autonomous loop. Codifies a lesson from Phase 6:
treating "external host doesn't have X" as a stop condition leads
to debt accumulation and workarounds. Most "absent" conditions are
**provisionable** by the loop itself.

## The rule

Before invoking the **stop / surface-to-user** path because:

- a required external host (`my-ubuntu-amd64`, `windowsmini`)
  appears to lack a tool / clone / file / binary, or
- a build / test / runner step is failing for a reason that
  looks like missing infrastructure rather than a code bug,

the loop must walk the **3-step extended challenge** below.
Stopping prematurely on bucket-2 of the `/continue` stop whitelist
is a violation of this rule.

## The 3 steps

### Step 1 — Confirm what is actually absent

A single command, no guessing.

- Tool absent: `ssh windowsmini "command -v <tool>"` /
  `orb run -m my-ubuntu-amd64 bash -c 'command -v <tool>'` /
  `which <tool>` locally.
- Path absent: `ssh ... "test -e <path> && echo present || echo absent"`.
- Binary stub vs real: `ssh ... "<tool> --version"` — succeeds
  meaningfully? exits 0 with garbage? times out?
- File missing: `find <root> -name <pattern>` — there or not?

The output of Step 1 is one line that **specifically** identifies
what's missing. "wasmtime not on PATH" vs "wasmtime stub on PATH
but `--version` non-zero" vs "wasmtime present and `--version`
returns 43.0.1 but `wasmtime run <fixture>` exits non-zero" are
**three different absences** demanding three different responses.

### Step 2 — Self-provision when in scope

Once Step 1 names the absence, ask: can the loop fix it autonomously
within scope?

- **In scope (autonomous OK)**:
  - `git clone` a missing repo into a path the loop already knows
    about (e.g. `~/Documents/MyProducts/...`).
  - `nix profile install` / `apt install` a missing tool **on a
    project-managed environment** (OrbStack VM, dev shell).
  - `mkdir` / `cp` / `chmod` to create missing scaffolding inside
    the project tree or its known subordinate dirs.
  - Re-run a setup script (`.dev/orbstack_setup.md` /
    `.dev/windows_ssh_setup.md` / `scripts/setup_*.sh`) to verify
    the documented procedure still works.
- **Out of scope (ask user)**:
  - Modifying user's global system config (`~/.ssh/config`,
    `~/.gitconfig`, system PATH).
  - Installing software into a non-project-managed environment
    (host Mac via Homebrew when not in flake.nix).
  - Network mounts, credentials, secrets.
  - Anything that requires `sudo` outside a sandboxed environment.

For in-scope provisioning, **just do it** and proceed. Add a
debt-ledger entry if the manual step had to be performed and
there's an automation gap (e.g. "host setup script doesn't
auto-install <tool>").

### Step 3 — If still blocked, document specifically

If Step 1 + Step 2 don't resolve it, the loop genuinely is blocked.
Surface to the user with:

- The specific absence (Step 1 output).
- The provisioning attempts (Step 2 commands run + their
  results).
- The proposed user action (one specific step the user can take).

This produces a useful interrupt — "windowsmini's wasmtime stub
exits 0 on `--version` but errors on `run <file>`; tried `nix
profile install nixpkgs#wasmtime` over SSH but the windowsmini
profile lacks nix; please install wasmtime via the host's package
manager or whitelist the workaround in an ADR" — instead of a
vague "windowsmini wasmtime broken, skipping".

## Forbidden anti-patterns

- **"It might not work, so I'll skip"** — the only valid skip is
  Step 3, after Steps 1 + 2 have actually run.
- **"I added a SKIP-X-MISSING fallback to make the gate pass"**
  — that's a workaround. Forbidden unless paired with an ADR or
  a debt-ledger row whose `Status` names the structural barrier
  (per `.dev/debt.md` discipline).
- **"User will figure it out next session"** — the loop is
  designed for autonomy; passing a vague problem back to the
  user is a stop antipattern (per `/continue`'s "Anti-patterns
  observed in past sessions").

## Phase 6 case study (the bug this rule was written for)

`§9.6 / 6.F` close: windowsmini reported "0 / 50 matched, 50
skipped-wasmtime-fail" because `which wasmtime` resolved to a
stub that fails to actually execute. The original response was
to add `SKIP-WASMTIME-UNUSABLE` to the runner's gate logic
(commit `e4095e8`). This bypassed the gate but left the root
cause uninvestigated.

Per this rule, the correct response was:

- Step 1: `ssh windowsmini "wasmtime --version"` → ?  (never
  ran).
- Step 1: `ssh windowsmini "which wasmtime"` → ?  (never ran).
- Step 2: `ssh windowsmini "nix profile install nixpkgs#wasmtime"`
  → ?  (never attempted).
- Step 3: surface to user with specifics.

The runner-side `SKIP-WASMTIME-UNUSABLE` is acceptable as a
**runner robustness improvement** (real wasmtime can transiently
fail in CI), but pairing it with **investigated root cause** is
mandatory. The current state is a debt entry (D-008).

## How this rule interacts with `/continue` stop conditions

The `/continue` skill's `LOOP.md` defines stop bucket 2:

> A required external host (`my-ubuntu-amd64`, `windowsmini`) is
> provably absent.

The keyword is **"provably"**. This rule defines what
"provably" means — Steps 1 + 2 must have actually run before
"provably" applies. "I assume it's absent" is not a proof.

## Reviewer checklist (apply during code review and on /continue
self-audit)

- [ ] When the loop chose to skip / surface / fallback, did Step 1
      (the confirmation command) actually run?
- [ ] If the answer is "we added a SKIP-X-Y fallback", is there a
      paired root-cause investigation OR a debt entry naming the
      structural barrier?
- [ ] If the loop self-provisioned (Step 2), is the action small,
      reversible, and within the project/managed-env scope?
- [ ] If the loop surfaced to user (Step 3), did the surface
      message name the **specific** absence and the **specific**
      proposed action?

## Stale-ness

- The 3-step procedure must remain executable from a fresh shell
  with the project's flake.nix dev shell active. If a step's
  command doesn't work in the dev shell, the rule itself is
  stale; fix it.
- `audit_scaffolding` skill periodically re-runs the example
  Step 1 commands (`ssh windowsmini "command -v zig"`, `orb run
  ... "command -v zig"`) to verify the rule's anchor commands
  still apply.
