# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — MAINTENANCE MODE (post-v2.0.0)

**v2.4.1 is the release line** (tag cut 2026-08-04, USER-GRANTED in-session per
ADR-0156 — consumer-driven patch: a component with 2+ exports failed validation
(#157, plus the follow-on it exposed where an export satisfied its own sortidx
bound) + a capture buffer had no bound (#158/#159, ~64 GB reachable). Both were
found from ClojureWasm and neither was reachable by zwasm's own fixtures; cljw
is re-pinned to the tag. v2.4.0 = 2026-08-03 external-consumer release
(`-Dcompiler-rt` #154 + sub-3.0 GC-cohort DCE #150); v2.3.0 = 2026-07-17
WASI-0.3.0 sweep + Homebrew tap `brew install clojurewasm/tap/zwasm`; v2.2.1 =
binary-size line, v2.2.0 = AOT line). v1 frozen at `v1.11.1`. Dev model: cut a
`develop/<slug>` branch from `main` → PR → CI `ci-required` 3-OS gate must be
green to merge. **Release stays user-only (ADR-0156)** — never autonomously tag /
publish / cut over. No active campaign; no cron self-re-arm.

## Consumer doc-truth gaps (both CLOSED) + closed campaigns

- #153/#154 compiler-rt opt-in + #163 default-engine sweep (reporter
  `jtakakura`): future prose gates go in the always-on CI **`doc-truth` job**
  (`check_engine_default_claims.sh` precedent).
- Binary-size CLOSED (ADR-0204, v2.2.1; D-522 demand-driven); AOT
  full-fidelity CLOSED (ADR-0203, v2.2.0; residual D-515(2)+D-514).

## Active front — wasi03-full (2026-08-10, ADR-0205, user-directed)

Full WASI 0.3 coverage campaign (six 0.3.0 proposals; `@unstable` excluded).
Conformance = vendored official `prod/testsuite-base` wasip3 binaries
(`=0.3.0`-pinned, dual-world 0.2+0.3 imports), run by an in-process
manifest-driven harness in `component_wasi_p3.zig` (`test-wasi-p3`).
- **A substrate — DONE/green** (8a793863f): timer waitables + scheduler seam +
  `wait-until`/`wait-for` + `exit-with-code`. Closes D-524.
- **B filesystem — DONE/green** (6d95ac124): full `wasi:filesystem@0.3.0`;
  official fs corpus 14/14; generation-aware `WasiGen` dispatch.
- **C sockets — COMPLETE/green**: official 12/12 (control + TCP/UDP data
  planes + ip-name-lookup real DNS). Keys: parked reads EXECUTE at
  readiness, tcp.send future non-eager, stream-drop = SHUT_WR/SHUT_RD,
  udp connect = OS dgram connect, explicit-bind connect = raw posix
  (ADR-0070 amendment) / own AFD on windows.
- **D http — COMPLETE/green**: full `wasi:http@0.3.0` (types resources +
  handler EXPORT + client.send). Model = src/wasi/p3_http.zig. Keys: `new`
  consumes headers/options owns (immutable after); harness drives the guest's
  exported handler.handle per manifest `request` op (service world = no
  cli/run); task.return generalizes to >1-flat results via defineFuncRaw;
  client.send parks as a subtask + real std.http.Client exchange (harness
  echo endpoint on a bg thread → HTTP_ENDPOINT); `resolveDroppedPeers` (poll
  seam) completes a parked copy whose peer dropped after it parked.
- **E claims sweep — DONE**: README/migration/ROADMAP/CHANGELOG flipped to
  full-coverage; `check_wasi03_coverage_claims.sh` doc-truth guard wired into
  CI. ADR-0205 = COMPLETE.
Official corpus **45/45 green** on POSIX. Linux x86_64 sockets fixed
(c5ce34fa4: SO_REUSEADDR-only `posixListen` — stdlib `reuse_address` couples
SO_REUSEPORT and Linux caches `fastreuseport` at first bind; spike
`private/spikes/linux-reuseport-bind`). 0.3.1 WIT diff vs 0.3.0 = 3 doc lines.

## Active bundle — wasi03 Windows port (user-directed 2026-08-11)

- **Bundle-ID**: wasi03-win-port
- **Cycles-remaining**: ~1 (code DONE — remaining: 3-OS full-gate pass + PR)
- **Continuity-memo**: windowsmini p3off.log "All 48 tests passed." (0 skip —
  D-568 AND D-569 discharged) + `[run_remote_*] OK` on all 3 hosts
- **Goal**: official corpus green on windows (user: 全部実装しきる → PR → CI
  3-OS green → user merge). ACHIEVED at source level (d5b81f7e3): all 10
  baseline fails fixed + explicit-bind/stream connect via the own AFD layer.
  Full root-cause record = ADR-0205 phase F; mechanism notes live as code
  comments in `p2_sockets.zig` (AFD section) + `path.zig` (winPathLink).
- **Iteration loop**: Mac cross-build
  `zig build test-wasi-p3 -Dtarget=x86_64-windows-gnu -Dtest-filter=wasip3-official`
  (run-step fails on mac = expected) → scp exe → windowsmini p3off.exe →
  read p3off.log.
- **Exit-condition**: official corpus 0-fail 0-skip on windowsmini (MET) +
  test-all green on all 3 hosts → PR to main.

## Operational invariants (keep using)

- **Win64 fast-repro** (~2min): cross-build on Mac (run-step "fails" but
  test.exe builds) → `scp` to windowsmini → ssh-run from the repo dir.
- **Mac `zig build test` is INSUFFICIENT** for flip/ABI/platform-branch
  changes — ubuntu+windows gates mandatory; arm64/POSIX masks the rest (this
  campaign: "45/45 green" was a POSIX-only claim; Linux had 3 fails, windows 10).
- **Step-0.7 NOTE**: `failed command: …--listen=-` / host-example exe lines are
  COSMETIC (exit 0); trust `[run_remote_*] OK/FAIL` + `N passed, 0 failed`.
- CI `ci_gate.sh` = fmt + `test-all` + (core) `run-rust-host` + (extended)
  lint/DCE/AOT/`zone_check`/`spill_aware`. Doc-only PRs: `doc-truth` job only
  (runs `check_engine_default_claims` + `check_wasi03_coverage_claims`).

## Parked / gated — do NOT speculatively grind (see debt.yaml)

- **D-477/D-478** JIT slivers (build-on-demand); **D-475 residual**
  spec-harness register-table wiring; **D-502** CM string encodings;
  **D-444** split `component_wasi_p2.zig` (grew again this campaign);
  **D-526** doc-staleness sweep; D-305/D-464/D-462 long-tail.
- G-senior-gap G1/G2/G3 COMPLETE
  (`.dev/meta_audits/2026-07-06-senior-runtime-gap-analysis.md`).

## State (release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON; **0.3**: POSIX full (windows port in flight, bundle above).
- **Surfaces**: C-API · Zig-API · lean CLI · memory-safety sound · dogfooded
  into cljw. Realworld 56 interp 56/0; JIT diff-gated. Debt: 0 `now`-class.

## Key refs

- `flake.nix` `.#gen-wasip3`; `docs/zig_api_design.md`; lessons INDEX. ADRs:
  **0156** (NO autonomous release) · **0153** (rework) · **0099** (file-size)
  · **0172** (components=interp) · **0205** (this campaign).
