# .dev/

Project-level design and operational metadata. Tracked in git. English.

## Always present (load-bearing)

- [`ROADMAP.md`](./ROADMAP.md) — **the** authoritative mission, principles,
  architecture, phase plan, success criteria, and quality-gate timeline.
  Single source of truth. If anything elsewhere disagrees with this file,
  this file wins.
- [`handover.md`](./handover.md) — short, mutable, current session state.
  Read at session start, updated 1–2 lines at session end.
- [`proposal-watch.md`](./proposal-watch.md) — WebAssembly proposal phase
  tracking. Reviewed quarterly. v2 implements Phase 5 (= Wasm 3.0)
  proposals; lower phases are watched but not implemented unless
  promoted.
- [`orbstack_setup.md`](./orbstack_setup.md) — one-time VM setup,
  iteration loop, and gate integration for the OrbStack Ubuntu x86_64
  cross-platform gate.
- [`decisions/`](./decisions/) — Architectural Decision Records.
  - `README.md` — convention.
  - `0000_template.md` — copy this when adding a new ADR.
  - `NNNN_<slug>.md` — accumulated decisions.

## Created on demand (do NOT pre-create as empty stubs)

Empty files rot. Create them when they have real content:

- `known_issues.md` — long-lived debt log, when the first P0–P3 item appears.
- `spec-support.md` — per-proposal implementation tracker, when Phase 1
  starts touching the wasm decoder.
