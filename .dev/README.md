# .dev/

> **Doc-state**: ACTIVE — load-bearing reference (Phase 9+ scope).

Project-level design and operational metadata. Tracked in git. English.

> **For readers browsing the repo:** this directory is zwasm's **development
> and decision record** — the ROADMAP, Architectural Decision Records
> (`decisions/`), design notes, a technical-debt ledger (`debt.yaml`), and
> observational lessons (`lessons/`). None of it is required to build, use, or
> embed zwasm (see the top-level README for that). It is kept public for
> transparency into how and why the runtime was designed the way it is; some
> files also carry maintainer-workflow bookkeeping (gate hosts, session
> handover) that only concerns day-to-day development.

## Always present (load-bearing project record)

- [`ROADMAP.md`](./ROADMAP.md) — **the** authoritative mission, principles,
  architecture, phase plan, success criteria, and quality-gate timeline.
  Single source of truth. If anything elsewhere disagrees with this file,
  this file wins.
- [`handover.md`](./handover.md) — short, mutable, current session state.
  Read at session start, updated 1–2 lines at session end.
- [`proposal_watch.md`](./proposal_watch.md) — WebAssembly proposal phase
  tracking. Reviewed quarterly. v2 implements Phase 5 (= Wasm 3.0)
  proposals; lower phases are watched but not implemented unless
  promoted.
- [`decisions/`](./decisions/) — Architectural Decision Records.
  - `README.md` — convention.
  - `0000_template.md` — copy this when adding a new ADR.
  - `NNNN_<slug>.md` — accumulated decisions.

## Maintainer-host setup (OPTIONAL — GitHub CI is the merge gate)

These document the maintainer's private multi-OS host farm, a pre-PR mirror
of what CI runs anyway (ADR-0076 D9, ADR-0206). A contributor never needs
them; see [`docs/development.md`](../docs/development.md).

- [`ubuntunote_setup.md`](./ubuntunote_setup.md) — Linux x86_64 SSH gate
  host (host alias overridable via `ZWASM_UBUNTU_HOST`).
- [`windows_ssh_setup.md`](./windows_ssh_setup.md) — Windows x86_64 SSH gate
  host (`ZWASM_WINDOWS_HOST`).
- [`orbstack_setup.md`](./orbstack_setup.md) — ARCHIVED (Mac-local scratch
  only, retired from the gate per ADR-0067).

## Created on demand (do NOT pre-create as empty stubs)

Empty files rot. Create them when they have real content:

- `known_issues.md` — long-lived debt log, when the first P0–P3 item appears.
- `spec-support.md` — per-proposal implementation tracker, when Phase 1
  starts touching the wasm decoder.
