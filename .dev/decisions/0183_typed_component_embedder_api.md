# ADR-0183 — Typed component embedder API (component-as-namespace enabler)

> **Doc-state**: ACTIVE
> Status: Accepted (2026-06-13; user-directed via the CWFS WIT-north-star
> discussion)

## Context

ClojureWasmFromScratch (the primary dogfooding consumer) decided
(their ADR-0135, 2026-06-13) that **WIT is the north star** of
ClojureWasm's differentiation: `require` a component as a namespace and
call its exports with Clojure data — records↔maps, lists↔vectors,
results→exceptions — with the interface taken from the **self-describing
component binary** (no `.wit` sidecar). Their explicit runtime asks:

1. **Introspection**: decode a component → export list WITH their
   component-level (WIT) types.
2. **Typed invoke**: Canonical-ABI lift/lower for rich values at the
   embedder API, beyond today's flat `invokeFlat`/`invokeStringExport`.

zwasm already owns the machinery: `decodeTypeInfo` retains exports +
the full type index space (records/variants/lists/options/results/
strings/enums/flags with labels — campaign chunks A2/B2–B5), and
`canon.zig` implements size/align/flatten + lift/lower for these types.
What is missing is the **public surface**: a component-level value tree
and the plumbing from it through canon onto guest memory.

## Decision

Add a typed component embedder API to the Zig facade (`-Dcomponent`
build; C-API exposure deferred until the Zig shape settles):

1. **`ComponentValue`** — a public value tree mirroring the WIT value
   model: `bool/s8..s64/u8..u64/f32/f64/char/string/list/record/
   tuple/variant/enum/option/result/flags` (own/borrow handles join when
   resource passing is needed). DISTINCT from `runtime.Value`
   (`single_slot_dual_meaning`; the component layer never leaks core
   values).
2. **Introspection**: `ComponentInstance.exportedFuncs()` (and a
   pre-instantiation equivalent on the decoded component) returning
   `{ name, params: []{name, type}, result: ?type }` referencing the
   decoded type model (`types.DefType` re-exported read-only). The
   binary IS the interface — matching CWFS's no-sidecar requirement.
3. **Typed invoke**: `invokeTyped(name, args: []const ComponentValue,
   alloc) !ComponentValue` — validates args against the export's WIT
   type, LOWERS via the canonical ABI (flat core args when they fit,
   `cabi_realloc` + memory writes for compound values, exactly as the
   existing canon paths do), invokes the lifted core func, LIFTS the
   result back into a `ComponentValue` owned by the caller's allocator.
4. **Proof fixtures**: a real wit-bindgen component exchanging a record
   + list + result with the host (gen-shell built, committed), driven by
   e2e tests; the existing greet/adder corpus rows gain typed-invoke
   directives in the component spec runner.

Out of scope here (later, demand-driven): async/stream/future canon
builtins (`UnsupportedCanon` today — the spec's own async story is still
settling), resource passing through `ComponentValue` (own/borrow arms
reserved), C-API mirroring.

## Alternatives rejected

- **Keep string/flat-only invoke and let CWFS marshal manually** —
  re-implements the canonical ABI host-side in every consumer; defeats
  the self-describing-binary contract and the dogfooding purpose.
- **Expose `.wit` text parsing as the interface source** — the binary
  already carries the types (CWFS explicitly wants no sidecar); WIT text
  stays a dev-tooling concern (the existing `wit/` layer remains for
  tooling).
- **JSON-ish dynamic value (stringly)** — loses the typed contract that
  is the whole point.

## Consequences

- New bundle `typed-component-api` drives the rollout (value type →
  introspection → lower/lift plumbing → proof fixture).
- `component_model_plan.md` gains Phase F (embedder typed API) — the
  campaign's consumer-facing tier on top of Tier 1/2.
- CWFS unblocks its ADR-0135 namespace experience on this surface; the
  shape is co-evolved with them (dogfooding feedback loops as with cw v1).
