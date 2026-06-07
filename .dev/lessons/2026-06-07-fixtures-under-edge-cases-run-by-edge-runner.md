# Fixtures under `test/edge_cases/` are auto-run by the edge-case runner

**2026-06-07** (CM-B6 IT-3b-2 → fix `8337f7b6`)

The edge-case runner (`test/edge_cases/runner.zig`, wired into `test-all`) walks
**every** `.wasm` under `test/edge_cases/` and runs it as a **core module**. I
committed component-model fixtures (`greet_component.wasm` + `greet_core.wasm`)
under `test/edge_cases/p17/component/`; the runner tried to run them as core
modules and failed (53→51 pass, 2 fail), breaking `test-all`.

**Mac `zig build test` did NOT catch it** — that step runs only the in-source
unit tests, NOT the edge-case runner. The edge-case runner runs under
**`test-all`** (the ubuntu/windows gate), so the breakage surfaced only on the
remote x86_64 run, one cycle later.

Rules:
1. **Component / non-core `.wasm` fixtures never go under `test/edge_cases/`** —
   that dir is the edge-runner's corpus (core modules with optional `.expect`).
   Component fixtures live in `test/component/` (a category the edge runner does
   not walk).
2. When adding ANY `.wasm`/`.wat` fixture, remember `zig build test` ≠
   `test-all`: the spec / edge-case / realworld / wasi runners only run under
   `test-all`. A fixture-placement or feature-config breakage is invisible to
   the Mac `zig build test` loop and only the 3-host gate catches it.
3. Corollary: a green `zig build test` + `lint` is necessary but NOT sufficient
   when the diff adds test corpus — the ubuntu Step-0.7 verdict is the real gate.

**Now mechanically enforced (recurred 2026-06-07, fix in `gate_commit.sh`).** It
recurred: a host-import-needing core fixture (`call_indirect_host.wasm`, the
D-310 boundary test) landed under `test/edge_cases/p17/`; the edge-runner ran it
standalone, found no `.expect`, FAILED — green on Mac, red on the next ubuntu
Step 0.7. Fix = relocate to `test/component/` (not walked) AND `gate_commit.sh`
now runs `zig build test-edge-cases` (BOTH fast + full modes) whenever a commit
touches `test/edge_cases/` or `test/realworld/`. A misplaced / unrunnable fixture
fails the commit LOCALLY now — loud, not swallow/skip (skipping would be the
false-coverage trap of `2026-05-30-edge-runner-fixture-cache-false-coverage`).
Rule #2's "remember the gap" is made structural; rule #1 is gate-checked.
