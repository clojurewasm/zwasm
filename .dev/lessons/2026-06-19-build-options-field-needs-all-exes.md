# A new `build_options` field must be wired into EVERY `addOptions()` instance

**Observation.** Adding a `-Dd331` build flag + `options.addOption(bool, "d331_probe", …)`
to ONE `b.addOptions()` instance, then referencing `build_options.d331_probe` in a
COMPILED-everywhere module (`arm64/emit.zig`, inside a comptime-`false` `if`), built green
on the Mac dev host but **failed to COMPILE on a fresh ubuntu clone**:
`error: root source file struct 'options' has no member named 'd331_probe'` — in the
**test exe** (`emit_test`), whose module graph uses a *separate* options module that never
got the field.

**Why it's sneaky.**
1. Zig SEMANTICALLY ANALYZES a comptime-`false` branch's body (it type-checks even though
   it's eliminated), so a missing `build_options` field is a HARD compile error, not dead.
2. The repo wires `build_options` via multiple `addOptions()` / per-exe options modules
   (main exe, `test`, `test-all` sub-exes). A field added to one is absent in the others.
3. The **local incremental cache masked it** — the Mac `zig build test` reused a cached
   `emit_test.o` from before the field existed; only ubuntu's clean build recompiled it and
   hit the gap. A green local `zig build test` is NOT proof a fresh build compiles.

**Rules.**
1. Adding a `build_options` field consumed by `src/` (esp. codegen, compiled into every exe)
   → grep `b.addOptions` in build.zig and add the field to ALL instances (or use ONE shared
   options module that every exe imports). Then `git clean`-equivalent verify, not incremental.
2. Verify a build-graph change on a SECOND host (ubuntu) or a from-scratch build before
   trusting a green local `zig build`. Cross-compile alone isn't enough — the failing unit was
   a TEST exe that cross-compile-to-main doesn't build.
3. A comptime-gated diagnostic that touches `build_options` is a build-graph change, not just
   "gated code" — it carries this whole-graph wiring obligation.

Cost: a `-Dd331` diagnostic reverted (`7b37ad6d`) after an ubuntu test-all build FAIL (D-331A).
