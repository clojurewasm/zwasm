# ADR-0209: A bench for two per-call costs no existing harness can see

- **Status**: Proposed
- **Date**: 2026-08-14
- **Front**: B-hardening (D-584 / D-585)
- **Findings base**: two-host measurement 2026-08-14 (x86_64-linux-gnu +
  aarch64-macos), raw data and full report in a separate investigation
  repository; the numbers cited below are reproduced by
  `zig build bench-latency`.

## What this ADR does not propose

It does **not** propose making steady-state throughput a project goal, and it
does not touch §2 P3. Cold-start remains the primary metric; nothing here asks
for that to change, and no optimisation pass is being argued for.

What it proposes is an instrument. Two costs are on record with numbers that
measurement contradicts, and no committed harness can check either. The bench
exists to close that gap, not to introduce a new performance axis to optimise.

## Context

Every bench in `bench/` measures the same way: `scripts/run_bench.sh` drives
`hyperfine` over `zwasm run <module>`, timing a whole process — spawn, plus
instantiate, plus execute. `bench/results/history.yaml`,
`all_engine_matrix.md`, `aot_coldstart.md` and `docs/benchmarks.md` all derive
from that harness.

That harness makes **one guest invocation per process**. A cost paid on *every*
call is therefore paid exactly once per measurement and disappears into process
startup, which is milliseconds. The harness is not wrong about what it
measures; it is structurally unable to see this class of cost.

Two costs sit in that blind spot today. Neither is a trade the project
recorded and accepted; each is a gap between what the record says and what
measurement finds.

- **D-584** — `computeStackLimit` is recomputed on every JIT invocation
  (`engine/codegen/shared/entry.zig` lines 232 and 255,
  `entry_buffer_write.zig` line 86). On Linux/glibc, on the initial thread,
  glibc's `pthread_getattr_np` answers by opening and parsing
  `/proc/self/maps`. The baseline this PR commits measures **26.8 microseconds**
  per call on x86_64-linux; separate rounds on the same host read 24.6 to 26.9,
  so treat it as tens of microseconds rather than a fixed figure.
  On a worker thread glibc answers from the thread descriptor (561 to 578 ns);
  on aarch64-macos the query is a user-space struct read, **3.3 ns** on an M4
  Pro with repeat runs agreeing within 3% — measured, but not currently in
  `latency_history.yaml` (see Verification). Roughly four orders of magnitude below
  the Linux main-thread path. The
  interpreter caches the same value (`runtime/runtime.zig:593`), so the cost
  lands on one side only. AOT pays it identically — the `.cwasm` load path
  reaches the same entry helpers.

  The *decision* was deliberate (`a31e00558`). Two things about the record are
  not. Its commit message estimated the cost at `~µs`, and the measurement is
  more than an order of magnitude above that. And ADR-0105 D1 specifies
  instantiation time — "Set at instance instantiation to: ..." — while the
  code comment cites D1 and does it per call. The per-call choice has a real
  justification D1 did not anticipate (the value must describe the calling
  thread), but the ADR was never amended to say so.

  A visible consequence: `.auto` prefers the JIT for any module it can compile,
  without regard to call size, so on Linux it selects the slower engine by up
  to 64x for small frequent calls.
- **D-585** — the public embedding API resolves the export by name on every
  call, and `findExportFunc` runs `parser.parse()` over the whole module to do
  it. On aarch64-macos, where D-584's constant does not exist, that makes the
  public API **about 15x** the cost of `JitInstance.invokeIdx` underneath it
  (161 ns against 10.5 ns on a 107-byte guest) and makes it **lose to
  `.interp`** at 0 and 1 loop trips. The cost is **linear in module size**,
  measured at 687 to 859 ns per KiB. At sizes a real embedder would load, and
  measured rather than extrapolated: a 101 KiB module costs **76 to 78
  microseconds** per call, a 1.1 MiB module **779 to 781**.

  This one is not a trade at all. P3 buys compile speed by accepting weaker
  generated code; it does not license re-parsing the module on each
  invocation, and nothing is bought by doing so. `invokeIdx(func_idx, args)`
  already exists and takes the index directly.

A reviewer checking this on Linux alone will find the two paths agree within
2%, which reads as "the re-parse does not matter". That agreement is D-584's
constant, well over 100x larger, swamping D-585. The two costs cannot be separated on a
single platform; aarch64-macos is what makes D-585 visible.

The shape of both is the same: a cost paid on every call, invisible to every
committed measurement, sitting behind a recorded number that measurement
contradicts.

## Decisions

### D1 — Add an in-process per-call latency runner, as a `bench/` lane of its own

`bench/latency/percall_runner.zig`, wired to `zig build bench-latency`.
Instantiate once, call many times, time only the calls. Compile and instantiate
stay outside the timed region: folding them in answers the cold-start question,
which `scripts/bench_aot_coldstart.sh` already owns.

The guest is `bench/latency/percall_loop.wat` (107 bytes): one loop whose trip
count arrives as a runtime parameter so no engine can fold it away, with the
accumulator returned so none can delete the loop. Trip counts 0 / 16 / 512 —
short on purpose, because this is a regression guard rather than the sweep an
investigation uses. The small sizes are where a per-call constant shows; 512 is
near the Linux crossover and watches the engine itself.

`stack_limit_query_ns` is recorded on its own line, not folded into the JIT
column, so a regression in D-584's query can be told apart from a regression in
the engine.

**Not in `test-all`.** It is a measurement, not an assertion. Its absolute
values move with machine state — 7% between two rounds on the same host during
this investigation, more on a laptop under load.

### D2 — Record into `bench/results/latency_history.yaml`, not `history.yaml`

Append-only per ROADMAP A9, same as every other bench record, but a separate
file with its own schema and **nanoseconds** rather than `mean_ms`. A 10 ns
call has no significant digits left in milliseconds.

`bench/results/` already holds two other series that kept their own schema
instead of joining `history.yaml`: `skip_impl_history.yaml` (the §9.12-A
enforcement scaffold, referenced by ROADMAP §12 as ADR-0050 D-5/D-6) and
`size_history.yaml` (`6717fe366`, D-320). Neither shipped under an ADR of its
own, so this is a shape the repo has settled into rather than a rule it wrote
down. The alternative, widening `history.yaml`'s §12.3 schema, would force
every hyperfine row to carry fields it has no value for.

Appended by `scripts/record_latency_bench.sh --reason "<tag>: <gist>"`, kept
separate from `run_bench.sh` because it shares no machinery with it: no
`hyperfine`, no comparators, no dev shell. Plain Zig, so it runs on any target
with a JIT backend — which is every currently supported one, x86_64 and
aarch64. That includes `windowsmini`: D-249's remaining barrier is that
`run_remote_windows.sh` has no bench step and ADR-0137 scoped bench timing to
two hosts, so no `run_bench.sh` path reaches it today.

The runner times both engines and `verify` instantiates with an explicit
`.jit`, which never falls back (`api/instance.zig:930-947`). On a target
without a JIT backend it would fail at instantiation rather than degrade to an
interpreter-only row. No such supported target exists, and `-Dengine=interp`
does not produce one (`engine_mode` reaches `build_options` but only
`cli/main.zig`'s version string reads it), so this is a constraint to know
about rather than a case to handle.

### D3 — No threshold gate; the record is for human review

`bench.yml` covers macOS and Linux and is `workflow_dispatch:` only, so it runs
when someone asks for it, not on every push. This bench could be added to it.
Either way it is deliberately **not** gated on a threshold.

The absolute numbers are machine-state sensitive by construction: this
measures a syscall on one platform and a parse on all of them, both of which
move with cache and frequency state. A threshold tight enough to catch a real
regression would fire on noise; one loose enough not to would miss a 2x. What
makes the measurement useful is the **shape** — `jit_over_interp` across trip
counts, and `stack_limit_query_ns` standing alone — which a reader can
interpret and a threshold cannot.

`bench-latency-build` — compile-only, no run — IS in the core gate. Compiling
it costs the gate almost nothing and catches public-API drift; running it there
would record a shared CI runner's numbers as if they meant something. Wiring
the measurement itself into `bench.yml` is left for a follow-up, once there is
more than one row to compare against. Recording it by hand at merge time, the way
`run_bench.sh --phase-record` is already used, is enough to start.

## Alternatives rejected

- **Widen `history.yaml`'s schema (§12.3) to carry nanosecond fields.** Every
  existing row would gain fields it cannot fill, and the two measurement kinds
  would be indistinguishable in the same list. The repo has twice chosen a
  separate file for a separate schema instead.
- **Add the guest as another `run_bench.sh` fixture.** It would be measured the
  way everything else is, through `hyperfine` on a whole process, which is
  precisely the harness that cannot see the cost. Adding a fixture to a blind
  harness produces a number that looks like coverage and is not.
- **Gate on a threshold now.** See D3. A gate that fires on noise gets muted,
  and a muted gate is worse than no gate because it reads as covered.
- **Assert in `test-all` that `jit_over_interp` at 512 trips is below 1.0.**
  Tempting, since it is the crossover, but it encodes one host's answer.
  aarch64-macos is already below 1.0 at *every* size; x86_64-linux is above 1.0
  until roughly 6,500 wasm instructions. The same assertion is trivially true on
  one and a real constraint on the other.
- **Measure through `JitInstance.invokeIdx` instead of the public API.** It
  would report the engine's number, about 10 ns, and hide D-585 entirely. The
  bench deliberately measures what an embedder can actually reach:
  `Instance.jitHandle` is private, so `invokeIdx` is not reachable through
  `zwasm.Engine` at all.
- **Defer until D-584 and D-585 are fixed.** Backwards. Without the bench the
  fixes have no before-and-after, and nothing stops the next per-call cost from
  landing the same way these two did.

## Consequences

### Positive

- D-584's recorded estimate and D-585's scaling become checkable rather than
  asserted, and stay checkable as the code moves.
- D-584 and D-585 become measurable, so their fixes can be shown to work rather
  than asserted.
- Runs with plain Zig and no external tools, so it also covers `windowsmini`,
  which no `run_bench.sh` path reaches today (D-249).

### Negative

- A second bench harness to maintain. Mitigated by keeping it small: one guest,
  three trip counts, no comparators, no external tools.
- `latency_history.yaml` grows monotonically like every other append-only
  record.

### Neutral

- No existing bench, schema, or CI job changes. `run_bench.sh`,
  `history.yaml`, `bench.yml` and `docs/benchmarks.md` are untouched.

## Verification

- `zig build bench-latency` emits a YAML fragment; `yq length` on the appended
  file parses and counts entries correctly across repeated appends.
- The runner asserts both engines return the same value for the same input
  before timing anything, so a lane that silently ran a different function
  fails rather than reporting plausible nanoseconds.
- One x86_64-linux baseline is committed. Every aarch64-macos figure in this
  ADR comes from runs on a host that is not this one and is NOT in
  `latency_history.yaml`; the schema change to `engine_build_mode` /
  `runner_build_mode` invalidated the row that was there. Re-recording it is
  outstanding. Until then, read the macOS numbers here as reported rather than
  as something the record backs.
- Harness overhead was measured, not assumed: an empty `once()` costs 0.000 ns
  and a `doNotOptimizeAway`-only body 0.276 ns, against 423 ns for the cheapest
  lane recorded. The comptime duck-typed `ctx` cannot distort these numbers.
- Warm-up adequacy was measured, not assumed. Sweeping it over
  0 / 1 / 10 / 100 / 1000 / 10000 at 512 trips moved the result 6.6% (JIT) and
  2.5% (interpreter), non-monotonically — noise within the machine-state drift,
  not an under-warmed engine. `Engine.compile` compiles the module up front, so
  there is no lazy per-call compilation for a warm-up to pay off.
- First recorded row (x86_64-linux, ReleaseFast) reproduces the investigation's
  figures: `stack_limit_query_ns` in the 26 to 27 microsecond range and
  `jit_over_interp` near 70 at 0 trips. The 512-trip row sits ON the
  x86_64-linux crossover and reads either side of 1.0 between runs (0.948 and
  1.054 observed), which is the point of recording it rather than a number to
  quote.
