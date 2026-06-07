# ADR-0176 — Component-Model validation: structural-first, incremental

> **Doc-state**: ACTIVE
> Status: Accepted (2026-06-08)

## Context

The CM campaign (ADR-0170) targets **wasmtime-equivalent** Component
Model support. wasmtime *rejects* malformed/invalid components; zwasm v2
currently does NOT — `decode.decode()` is purely structural (enumerate
sections) and `types.decodeTypeInfo()` does only scattered local checks
(oversized LEB → `InvalidTypeIndex`, `EmptyEnum`, flags-count, non-empty
record/variant/tuple). No cross-reference validation (type-index bounds,
alias targets, name format) exists. So an invalid component currently
decodes "OK" and may instantiate or mis-behave.

The official conformance corpus
(`~/Documents/OSS/WebAssembly/component-model/test/wasm-tools/*.wast`) is
**365 `assert_invalid` + 17 `assert_malformed` = 382** negative cases.
Reason-string survey: the bulk are *structural* — "type index out of
bounds" (~39), "index out of bounds" (26), "not in kebab case" (9),
"type not valid to be used as export" (15), "not a valid extern name"
(5), "not valid base64" (5), "invalid outer alias count" (5), "refers to
resources not defined" (5), etc. A minority need deep
canonical-ABI-lowering / subtyping logic.

## Decision

Add a **dedicated component validator** `src/feature/component/validate.zig`
(`pub fn validate(info: *const TypeInfo) Error!void`), invoked **after
`decodeTypeInfo()` and before instantiation** at the three host entry
points (`instantiate`, `instantiateGraph`, `runWasiP2Main`). It walks the
decoded `TypeInfo` struct (no re-parse — this is the deliberate divergence
from wasm-tools, which interleaves validate-with-decode).

**Scope = STRUCTURAL-FIRST, incremental.** Each validation *rule* is one
TDD chunk under the **E3-CM-validation bundle**, driven by official
`assert_invalid` fixtures. Rules land in frequency order:

1. **Type-index bounds** — every `ValType.type_index` (recursively in all
   deftypes), `own`/`borrow`, `Canon.{lift.type_index, resource_*}`,
   `TypeBound.eq`, `ExternDesc.{func,component,instance}` must be `<` the
   respective index-space length. **(this ADR's first chunk: ValType +
   own/borrow.)** Correctness note: the bounds check is against the TRUE
   type-index-space size — `type`-section defs PLUS type-sort aliases, type
   imports, and type exports (a new `TypeInfo.type_space_len`) — NOT
   `deftypes.len`, which counts only the type section. Using `deftypes.len`
   false-positives on real wit-bindgen components that reference aliased
   interface types (caught at first gate). Deeper index spaces
   (`func`/`component`/`instance`, alias-target existence) follow as rules.
2. Name format (kebab-case + valid extern/import names).
3. Outer-alias count ≤ nesting depth; alias-target existence.
4. … further structural rules as the corpus surfaces them.

**Out of scope (deferred, truthfully `skip-impl` in the runner with a
specific per-case reason — NOT a blanket skip, per the D-301 lesson):**
deep canonical-ABI lowering constraints, full structural subtyping of
component/instance type bounds, resource-type-identity equality. These
need the canon-lowering machinery and are a later bundle.

**Errors reuse the existing `types.Error` set** (`InvalidTypeIndex`,
`InvalidName`, `InvalidAlias`, …) — no new shared-error widening
(platform_panic_vs_error spirit: a validator error is caller-meaningful,
so it stays in the function-local/​module error set already in use).

## Alternatives rejected

- **Full §-by-§ component validation up front** — months of work
  (subtyping, canon-ABI), disproportionate to v0.2; the structural-first
  tier catches ~80% of the corpus at a fraction of the cost.
- **Ingest the corpus + blanket `skip-impl` all 382** — violates the
  D-301 "no blanket skips" lesson and delivers ~zero real conformance.
- **Validate-during-decode (wasm-tools shape)** — would re-thread decode;
  zwasm already separates decode→`TypeInfo`, so a struct-walking pass is
  simpler and reuses the decoded form.

## Consequences

- Invalid components are rejected before instantiation (wasmtime-equivalent
  direction). Existing valid fixtures (greet/adder/wasi_p2_*) are
  unaffected (no OOB indices / bad names).
- The component spec runner (`component_model_assert_runner.zig`, E1)
  gains `assert_invalid` / `assert_malformed` directives; the corpus grows
  rule-by-rule with truthful pass/skip.
- Bundle `E3-CM-validation` tracks the multi-cycle rule rollout.
