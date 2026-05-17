# 0067 — Adopt `ubuntunote` (native x86_64 Linux) as the per-chunk gate host; retire OrbStack `my-ubuntu-amd64` (Rosetta-translated)

- **Status**: Accepted
- **Date**: 2026-05-17
- **Author**: zwasm v2 maintainer (D-134 root cause discharge + autonomous loop pivot)
- **Tags**: infra, gate, host, x86_64, linux, rosetta, d-134, autonomous-loop

## Context

ADR-0049 (`defer windowsmini to phase-close batch`) established the
per-chunk 2-host gate shape: Mac aarch64 (foreground) + Linux
x86_64 (background, via OrbStack `my-ubuntu-amd64`); windowsmini
reconciles at Phase boundary. This shape has held since the
chunk 7.9-d / Phase 7 close.

Through D-134 (filed d-64, initially classified as a layout-
flake heisenbug per
[`2026-05-16-zig-sigsegv-recovery-flake.md`](../lessons/2026-05-16-zig-sigsegv-recovery-flake.md))
the OrbStack-side `zwasm-spec-wasm-2-0-assert` step
non-deterministically SEGV'd at ~30% / ~70% rate (green /
crash) under identical SHA. The 2026-05-17 root-cause
investigation (lesson
[`2026-05-17-d134-rosetta-2-signal-translation-limit.md`](../lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md))
identified the cause: **Apple Rosetta 2 dynamic translation
on the Apple Silicon host kernel** (`[rosetta]` dmesg prefix +
ARM64 register dump for an x86_64-named process) drops
SIGSEGV delivery to guest-installed `sigaction(.SEGV, ...)`
handlers under long-running JIT workloads. zwasm code and
Zig stdlib are both correct (1M-iter vanilla repro green;
JIT-page repro green).

A **retry wrapper** (`scripts/orb_test_all_with_d134_retry.sh`)
provides 5-attempt re-invocation on the D-134 fingerprint
(`zwasm-spec-wasm-2-0-assert failure` + `process terminated
with signal SEGV`); this mitigates but does not eliminate the
underlying Rosetta race.

In parallel, the user provisioned a **native x86_64 Linux
host** (`ubuntunote.local`, 192.168.11.6, Ubuntu 24.04.4 LTS,
8 cores / 31 GB) reachable from Mac via SSH + mDNS, with
NOPASSWD sudo, Determinate Nix 3.20.0 (multi-user), direnv +
nix-direnv pinned to the project's `flake.nix`, and the
zwasm repo cloned at `~/Documents/MyProducts/zwasm_from_scratch`.
Validation runs (`bash scripts/run_remote_ubuntu.sh test-all`
× 1 full corpus + `test-spec-wasm-2.0-assert` × 5 in
sequence) **all exited 0** with identical 1268-line log
outputs and 24034 / 0 / 2015 + 13301 / 0 / 440 PASS counts
bit-identical to Mac aarch64. D-134 is **completely absent**
on native x86_64.

The per-chunk gate's "Linux x86_64" requirement is therefore
satisfied better by `ubuntunote` than by OrbStack
`my-ubuntu-amd64`:

- D-134 root cause (Rosetta signal-translation race) is
  structurally absent — native silicon, no translation
  abstraction.
- Real Intel/AMD cache, branch-predictor, AVX/SSE
  micro-architecture exposed — future Phase-8b /
  Phase-15-style micro-arch-sensitive optimisations will
  fail or succeed *on the hardware* the JIT is targeting,
  not via an emulation layer.
- Same SSH-remote pattern as `windowsmini`
  (`scripts/run_remote_*.sh` + `.dev/*_setup.md`), so the
  Mac-side autonomous loop discipline is a copy-paste
  extension rather than a new architectural shape.

## Decision

The per-chunk 2-host gate's **Linux x86_64 host is `ubuntunote`**
(native, SSH-remote via `scripts/run_remote_ubuntu.sh`).
OrbStack `my-ubuntu-amd64` is **retired from the per-chunk
gate** but **retained as a dev-convenience host** for
interactive scratch.

Concretely:

1. `.claude/skills/continue/LOOP.md` per-chunk OrbStack
   invocation (`orb run -m my-ubuntu-amd64 ...`) is replaced
   by `bash scripts/run_remote_ubuntu.sh test-all >
   /tmp/ubuntu.log 2>&1` (`run_in_background: true` per the
   established discipline).
2. The retry wrapper
   `scripts/orb_test_all_with_d134_retry.sh` is **preserved
   in-tree** as historical record + fallback (D-134-shaped
   flake surfacing on a future Rosetta-class host can be
   classified using its fingerprint logic) but **not invoked
   by the autonomous loop**.
3. `.dev/orbstack_setup.md` is **retained** with a header
   note marking it deprecated for gate use; dev-time `orb`
   workflows (interactive shell, local scratch) remain
   documented there.
4. `.dev/ubuntunote_setup.md` is the canonical setup
   reference for the Linux x86_64 gate host (mirror of
   `.dev/windows_ssh_setup.md`'s shape).
5. ADR-0049 receives a `Revision history` row pointing at
   this ADR; its Decision body (windowsmini deferred to
   phase-boundary reconcile) is **unchanged**.
6. D-134 (`.dev/debt.md`) flips Status `mitigated` →
   `closed (root cause absent on native x86_64 host;
   OrbStack-Rosetta path retired from gate per ADR-0067)`.
   The lesson file keeps its analysis content; a closing
   addendum cites this ADR.

## Alternatives considered

### Alternative A — Keep OrbStack, rely on retry wrapper

- **Sketch**: `scripts/orb_test_all_with_d134_retry.sh`
  becomes the production gate invocation; D-134 stays
  `mitigated`.
- **Why rejected**: rate-reduction is fragile; D-134's
  reproduction rate (~70% on current SHA) is layout-sensitive
  and can worsen with future code changes. Continued reliance
  on retry adds wall-clock noise (5 retries × ~2-5 s each on
  bad-luck commits) + cognitive load (every D-134 fingerprint
  match requires classification). When a native x86_64 host
  is available, choosing the workaround over the structural
  fix is the "no_workaround.md" anti-pattern in spirit.

### Alternative B — Switch to OrbStack `my-ubuntu-arm64`

- **Sketch**: replace `my-ubuntu-amd64` with `my-ubuntu-arm64`
  (native ARM64 in OrbStack, no Rosetta).
- **Why rejected**: loses x86_64 codegen coverage on the
  Linux side. The per-chunk gate would become "Mac aarch64 +
  Ubuntu aarch64" — both ARM64 — and the x86_64 backend
  (`src/engine/codegen/x86_64/`) would only execute at
  windowsmini Phase-boundary reconcile. Cross-arch regressions
  (W54-class — `src/engine/codegen/arm64/` and `x86_64/`
  must NOT import from each other per §A3) would surface days
  late.

### Alternative C — Replace OrbStack with qemu-user-static (binfmt_misc)

- **Sketch**: keep the OrbStack VM but route x86_64 ELF
  through `qemu-x86_64` instead of Rosetta.
- **Why rejected**: qemu-user is slower than Rosetta (~3-10x
  for JIT-heavy workloads), and qemu's x86 ISA implementation
  diverges from real silicon in subtle areas (FP exception
  flags, denormal handling, `cpuid` reporting). Trading
  Rosetta's bug for qemu's bugs without gaining real-silicon
  coverage.

### Alternative D — Cloud x86_64 (GitHub Actions / EC2 / etc.)

- **Sketch**: per-chunk gate runs Linux x86_64 on a CI
  runner; Mac side waits for CI status.
- **Why rejected** (for now): operational complexity
  (secrets, network latency, CI minute budget) outweighs the
  benefit when a user-owned native machine is already
  available. Reconsidered at the v0.1.0 RC if the project
  outgrows the home-lab setup; tracked under future infra
  work.

## Consequences

- **Positive**:
  - D-134 closed cleanly; retry wrapper retired from the
    hot path.
  - Native silicon coverage for x86_64 JIT codegen —
    micro-arch corner cases surface during development, not
    at v0.1.0 RC integration.
  - Same SSH-remote pattern as `windowsmini` — `windowsmini`
    + `ubuntunote` form a symmetric pair, both reachable as
    `*.local` via mDNS, both gated by analogous
    `scripts/run_remote_*.sh` wrappers.
  - `scripts/run_remote_ubuntu.sh` uses `nix develop
    --command` to pin the toolchain via `flake.nix`,
    guaranteeing bit-identical Zig / wasm-tools / lldb
    versions with the Mac side.
  - The Mac-host laptop no longer carries the JIT-heavy
    `zwasm-spec-wasm-2-0-assert` corpus (24,000+ fixtures)
    in addition to its own gate — load distributed.

- **Negative**:
  - `ubuntunote` must be reachable when the autonomous loop
    runs. Suspend / power-off blocks the gate. Mitigation:
    keep it always-on (low power consumption for an x86_64
    desktop / laptop); Wake-on-LAN trigger from Mac is a
    follow-up if needed (`.dev/ubuntunote_setup.md`
    "Lifecycle / sleep behavior").
  - SSH path = network reliability dependency. Wi-Fi
    transient drops fail the gate spuriously; the existing
    `windowsmini` keepalive settings (60s × 3) carry over.
  - Initial flake fetch on first `nix develop` is ~5 min
    (Zig + dev-shell deps). One-time per host.
  - Operational addition: a second remote machine to
    maintain (apt updates, Nix profile updates). Mitigated by
    Nix's reproducibility — toolchain pinning is
    project-controlled.

- **Neutral / follow-ups**:
  - `windowsmini` reconciliation discipline unchanged
    (ADR-0049 Phase-boundary batch).
  - OrbStack retains its role as a Mac-local interactive
    scratch host (e.g. quick `orb run` smoke tests during
    development). `.dev/orbstack_setup.md` is retained.
  - The `scripts/orb_test_all_with_d134_retry.sh` script is
    preserved in-tree as a Rosetta-class fingerprint
    classifier. If a future Rosetta-class flake surfaces on
    a different host (e.g. macOS-host development on Apple
    Silicon with Rosetta-translated containers), the same
    fingerprint check applies.
  - `.dev/debt.md` D-134 row flips to `closed`. The lesson
    file
    [`2026-05-17-d134-rosetta-2-signal-translation-limit.md`](../lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md)
    receives a closing addendum citing this ADR + the 5/5
    green validation.
  - **Ubuntu debug tooling** (`gdb`, `strace`, `ltrace`,
    `nasm/ndisasm`, `valgrind`, `bpftrace`, `linux-tools`
    perf, `bpfcc-tools`, `qemu-user-static`) installed via
    apt at setup time; Nix dev-shell continues to provide
    `lldb` / `wasm-tools` / `wasmtime` (per `flake.nix`).
    apt-vs-nix decision rationale documented in
    `.dev/ubuntunote_setup.md`.

## References

- ROADMAP §A3 (inter-arch isolation), §A8 (host coverage),
  §A10 (release gates), §A12 (build-flag separation).
- Related ADRs:
  - [`0049_defer_windowsmini_to_phase_close_batch.md`](0049_defer_windowsmini_to_phase_close_batch.md)
    — per-chunk gate host subset; this ADR refines the
    Linux x86_64 host identity. Revision row added.
  - [`0009_zlinter_no_deprecated_gate.md`](0009_zlinter_no_deprecated_gate.md)
    — Mac-host lint gate (unchanged; lint stays Mac-only).
  - [`0015_canonical_debug_toolkit.md`](0015_canonical_debug_toolkit.md)
    — canonical debug tooling spec; this ADR ensures
    `ubuntunote` carries those tools.
- Lessons:
  - [`2026-05-17-d134-rosetta-2-signal-translation-limit.md`](../lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md)
    — root cause investigation that motivated this pivot.
  - [`2026-05-16-zig-sigsegv-recovery-flake.md`](../lessons/2026-05-16-zig-sigsegv-recovery-flake.md)
    — superseded earlier hypothesis tree.
- Setup docs:
  - [`../ubuntunote_setup.md`](../ubuntunote_setup.md) — new
    canonical Linux x86_64 gate-host setup procedure.
  - [`../windows_ssh_setup.md`](../windows_ssh_setup.md) —
    parallel pattern for windowsmini (unchanged).
  - [`../orbstack_setup.md`](../orbstack_setup.md) —
    deprecated for gate; retained for dev scratch.
- Validation evidence (this commit):
  - 5/5 `test-spec-wasm-2.0-assert` green via
    `bash scripts/run_remote_ubuntu.sh`, identical 1268-line
    output (decision-deterministic; no Rosetta flakiness).
  - Full `test-all` green: 24034 / 0 / 2015 spec_assert
    non-simd + 13301 / 0 / 440 simd, bit-identical with Mac
    aarch64.

## Revision history

| Date       | SHA        | Note                                    |
|------------|------------|-----------------------------------------|
| 2026-05-17 | `58e69207` | Initial accepted version (D-134 closed; OrbStack retired from per-chunk gate). |
