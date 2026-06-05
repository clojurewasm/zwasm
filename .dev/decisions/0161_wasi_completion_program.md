# 0161 — WASI completion program: preview1-full → all-engine → horizon (preview2/0.3)

- **Status**: Accepted (2026-06-05; user-directed program — see chat 2026-06-05).
- **Date**: 2026-06-05
- **Author**: claude (user directive: "WASI を最新まで対応してほしい")
- **Tags**: wasi, scope, roadmap, §11, §8, all-engine, component-model, async,
  D-251, D-244, D-007, ADR-0140, ADR-0135
- **Amends**: ROADMAP §11.1 (corrects the "preview1 full" overclaim), §8 (WASI
  strategy staging), Phase Status widget (Phase 11 exit wording).

## Context

A 2026-06-05 audit (subagent, cite `src/api/wasi.zig:285 lookupWasiThunk`) found
the WASI preview1 surface is **21/46 syscalls (~46%)**, NOT "full" as ROADMAP
§11.1 `[x]` claims. The `[x]` reflected "the realworld corpus (50 fixtures) goes
green" — which exercises only stdio + basic file ops — not the full preview1 ABI.

**Wired (21)**: proc_exit, sched_yield, args_get/_sizes_get, environ_get/_sizes_get,
clock_time_get, random_get, fd_read/write/close/seek/tell/fdstat_get/fdstat_set_flags/
filestat_get/prestat_get/prestat_dir_name, path_open, path_unlink_file, poll_oneoff.

**Missing (25)**: all 9 sockets (sock_*), fd_readdir (dir enumeration), 7 path_*
(create_directory/remove_directory/rename/link/symlink/readlink/filestat_get/
filestat_set_times), fd_pread/pwrite, fd_sync/datasync/advise/allocate,
fd_fdstat_set_rights, fd_filestat_set_size/set_times, clock_res_get, proc_raise.

The user directs WASI "to latest" — the project should ultimately reach the line
zwasm v1 claimed (v1 README: WASI Preview1 100% **+ Component Model** = WIT parser,
Canonical ABI, WASI P2 adapter), and the horizon is left open beyond that
(WASI 0.3 async/streams; async-Zig know-how lives in the read-only reference clone
`~/Documents/MyProducts/ClojureWasmFromScratch` — `runtime/agent.zig` etc.).

## Decision

A staged WASI completion program, NOT a single phase:

1. **preview1-full (v0.1.0 line)** — implement the missing 25 syscalls to reach
   46/46, on the **interp** path first. Correct §11.1's overclaim: re-label the
   existing `[x]` as "preview1 **core subset** (21/46, realworld-corpus-sufficient)"
   and open a new scheduled task for the 21→46 completion. This is real work
   (sockets = networking, fd_readdir = dir enumeration, path_* = filesystem).
2. **all-engine WASI** — the WASI host today runs **interp-only**; `--engine=jit`
   and AOT are compute-only (ADR-0140; D-251/D-244 d-3). Extend the completed WASI
   host to JIT + AOT so a WASI-importing `.wasm` runs on all three engines
   (D-251 serialises import metadata into `.cwasm`; reuse `populateDispatch` /
   `wasi/jit_dispatch.zig`).
3. **Component Model / WASI P2 (v1-parity line; post-v0.1.0)** — WIT parser +
   Canonical ABI + P2 adapter (what v1 shipped). **De-risked by a NOW survey**
   (does it force a big design pivot in zwasm's Zone/ZIR/dispatch?) before any
   implementation — survey only, implementation is post-v0.1.0.
4. **WASI 0.3 / async / streams (open horizon, beyond v1)** — aspirational, not a
   fixed endpoint; async-Zig design references ClojureWasmFromScratch's agent
   model. No commitment beyond keeping the staging open.

### §8 staging (amended)

```
[now / v0.1.0]   WASI preview1-FULL (46/46, interp → all-engine)
[v1-parity]      Component Model / WASI P2 (WIT, Canon ABI, P2 adapter)   post-v0.1.0
[open horizon]   WASI 0.3 / async / streams                              beyond v1
```

## Consequences

- ROADMAP §11.1 re-labelled (honesty: subset, not full); a new WASI-completion
  task scheduled (preview1 21→46). Debt D-007 (RunOpts/preopens), D-251 (AOT-WASI),
  D-244 d-3 (JIT-WASI) re-wired under this program (blocked-by → scheduled).
- The "all-engine WASI" goal makes D-251 + D-244 d-3 a single unit (both engines
  gain WASI together) rather than indefinitely deferred.
- Component Model gets a survey-now / implement-later split (de-risk the possible
  large design pivot the user flagged), keeping v0.1.0 unblocked.
- No autonomous release (ADR-0156 unchanged): this program advances the 完成形
  surface; tag/cutover stays user-only.

## References

- `src/api/wasi.zig:285` (lookupWasiThunk dispatch — the 21-name table); `src/wasi/`
  (fd/path/clocks/proc handlers); audit 2026-06-05 (chat). ROADMAP §8 / §11.1 / §11.P.
  ADR-0140 (--engine=jit compute-only), ADR-0135 (rooting re-sequence), ADR-0156
  (no autonomous release). D-251 / D-244 / D-007. v1 README (WASI P1 100% + CM).
  ClojureWasmFromScratch `runtime/agent.zig` (async-Zig reference for WASI 0.3).
