# Audit subagents find the sites but overstate severity — trace the ownership/lifetime model before acting

**Date**: 2026-06-06
**Tags**: audit subagent, memory-safety review, false positive, CRITICAL overstatement, adversarial verify, ownership model, lifetime contract, zombie-parking, borrow-vs-own, documented-contract, 3-host-green maturity, flip-flop tell

## Observation

Three memory-safety audit subagents this session each surfaced a confidently-labelled
**"CRITICAL / REAL BUG"** that **dissolved under verification** — 3 for 3 on mature,
3-host-green code:

1. **Cross-module aliasing** → claimed a table-refs **UAF** ("CRITICAL BUG"). DISPROVED:
   the c-api **zombie-parking** model (`wasm_instance_delete` parks runtime+arena on the
   store's zombie list, reaped only at `wasm_store_delete`, `api/instance.zig:263`) keeps
   aliased storage alive past individual instance deletes → no early dangle.
2. **WASI fd lifecycle** → claimed an **fd-leak** "REAL BUG" on `Host.deinit`. DISPROVED:
   Host correctly **BORROWS** preopen handles (no dup; closing them would be the bug),
   `path_open` is unimplemented (no *owned* fds exist), and the CLI preopen fds are an
   intentional documented process-lifetime choice (`cli/run.zig:62`).
3. **Linker lifetime (#6)** → flagged a `Linker.deinit` **UAF** as a bug. Reframed: it's a
   real but **documented caller-contract** (Linker must outlive its Instances; the importer
   holds a raw ptr into Linker-owned `CallCtx`) — the fix was *documentation*, not code.

The cross-module audit even **flip-flopped mid-analysis** (said "sound", then revised to
"BUG") — a tell of low-confidence severity assessment.

## Why

An audit subagent reasons **locally**: it sees "`deinit` frees X, there's no close/guard/
refcount" and concludes **BUG**. It reliably **locates the relevant sites** but does NOT
trace the **full ownership/lifetime model** — zombie-parking, borrow-vs-own, path-not-
implemented, or an existing documented contract — which is exactly what determines whether
the local observation is a real defect.

## Rules

1. **Audit subagents are reliable at FIND, unreliable at SEVERITY.** Trust the site
   pointers; treat every "CRITICAL/REAL BUG" as a *hypothesis to refute*, not a verdict.
2. **Trace the model before acting**: who *owns* vs *borrows*? Is teardown *deferred*
   (zombie-parking/arena)? Is the "missing close/guard" actually a *documented contract*
   (systems API, like wasmtime's `unsafe`/Store-ownership)? Is the faulting feature even
   *implemented*?
3. **On mature 3-host-green code, a dissolving "critical" is the NORM, not the exception** —
   budget verification effort accordingly; do NOT commit a "fix" before the model check.
4. A subagent that **flip-flops** within its own report is signalling low confidence — weight
   it as a lead, never as a conclusion.
5. The genuine residue is usually *documentation* (make the real contract explicit, e.g.
   `477a9004` Linker lifetime) — valuable, but not the code change the audit demanded.

Cf. `encode-rule-after-survey-not-audit` (audit *path*-guesses are unreliable; here it's
audit *severity*-guesses). Subsumes nothing; complements the investigation_discipline
adversarial-verify guidance with concrete 3-for-3 evidence.
