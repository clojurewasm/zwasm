# GC sub/sub-final byte direction (0x50/0x4F) — a corpus-masked validation bug

**Date**: 2026-05-29
**Cycle**: 10.G-wasmgc cycle 126
**Citing**: `7c201f97` (cycle 126 feat commit)

## What happened

cyc125 wired `0x50`/`0x4F` subtype parse and set finality with the
direction **backwards**: `if (body[pos] == 0x4F) finals[i] = false`,
treating `0x50` as final. The authoritative source — the GC reference
interpreter `binary/decode.ml:256-266` — says the opposite:

- `0x50` (`-0x30 & 0x7f`) → `SubT(NoFinal,…)` = **sub (open, extendable)**
- `0x4F` (`-0x31 & 0x7f`) → `SubT(Final,…)` = **sub final**
- bare comptype → `SubT(Final, [], …)` (final, no supertypes)
- `0x4E` → rec group

## Why the corpus didn't catch it (the trap)

The 4 `type-subtyping-invalid` fixtures use `0x50` and extend another
`0x50` type. They are invalid for **two independent reasons** at once:
finality (extending a final type) AND structural (field mut/type
mismatch). With the finality direction backwards, the fixtures were
still rejected — by the wrong reason. `invalid pass=55` was unchanged,
so the unit test + corpus both looked green. The bug was only
exposable once a **valid** fixture (ts.3: type2 extends type1=`0x50`=
open) reached `validateTypeSection` — which required `0x4E rec` parse
(cyc126) to land first.

## The general lesson

A validation bug is **masked when test inputs fail for multiple
independent reasons**. The corpus count being correct does not prove
each validation dimension is individually correct. When a check has
several sub-conditions (finality × structural × bounds), verify each
in isolation (a fixture that fails ONLY on that dimension) or pin the
semantics against the authoritative spec/reference at write time —
don't infer direction from an aggregate pass count.

## Resolution

cyc126 fixed the direction (`0x50 → fin=false`), flipped the cyc125
parse-test assertions (they were backwards-consistent with the bug),
and added the `0x4E rec` parse that finally lets valid subtype
fixtures reach the check. Result: gc return 0→2, invalid 55→57, no
regression.

## Related

- ADR-0124 (GC structural subtype lattice)
- `2026-05-29-wasmgc-corpus-scope.md` (corpus survey)
- `2026-05-29-zig-run-step-cache-stale-diag.md` (DIRECT-binary discipline)
