# 0024 — Module graph and lib root (single shared Module across artifacts)

- **Status**: Accepted
- **Date**: 2026-05-05
- **Author**: Shota / post-ADR-0023 build-system gap discovery
- **Tags**: roadmap, build, module-graph, refactor, phase7, post-implementation

## Context

ADR-0023 normalised the `src/` directory shape (parse / validate /
ir / runtime / instruction / feature / engine / wasi / api / cli /
platform / diagnostic / support). The structural relocation
landed in 30+ commits, all of which kept `zig build test` green.

**The gap surfaced when running `zig build test-all`**: the
`test-c-api` step (which builds `libzwasm.a` from a separate
module root and links it against `examples/c_host/hello.c`)
broke at item 11 (`c_api_lib.zig` → `api/lib_export.zig` rename).
The error was `import of file outside module path: '../runtime/
runtime.zig'`, fired by Zig 0.16's module-isolation rule:

> A `*std.Build.Module`'s `root_source_file` defines a subtree
> boundary. `@import("../X")` from any file inside the subtree
> resolves only if the resolved absolute path stays inside that
> subtree. Escaping is rejected at compile time (intentional;
> see ziggit "Importation and dependencies" + ziglang issue
> #22284).

Symptom-fix attempts that surfaced during recovery:

1. Set `lib zwasm` root to `src/main.zig` — fails because
   `main.zig` declares `pub fn main(...)` and the resulting
   archive duplicate-defines `_main` against the C host's own
   `int main(void)`.
2. Move `api/lib_export.zig` back to top-level `src/lib_export.zig`
   — works, but is a workaround that contradicts ADR-0023 §3
   reference table (`api/lib_export.zig — dylib symbol export
   surface`) and forces the ADR to be amended around the build-
   system constraint rather than the design intent.

Neither symptom-fix is structurally sound. The build-system
shape was missing from ADR-0023's design surface; this ADR
fills the gap.

### Web + reference research (informs the Decision)

Investigated 2026-05-05 against authoritative sources:

- [Zig 0.16 build-system guide](https://ziglang.org/learn/build-system/)
- [ziglang issue #22284 — addExecutable/addTest take root_module](https://github.com/ziglang/zig/issues/22284)
- [ziggit — Importation and dependencies](https://ziggit.dev/t/importation-and-dependencies/4067)
- [ziggit — Style: importing by module or source file](https://ziggit.dev/t/style-question-importing-by-module-or-source-file/5569)
- [ghostty/build.zig + src/build/GhosttyZig.zig](https://github.com/ghostty-org/ghostty/blob/main/build.zig) — production triple-artifact pattern (static + shared + wasm) sharing one `Module`
- [bun/build.zig](https://github.com/oven-sh/bun/blob/main/build.zig) — `bun.addImport("bun", bun)` self-import idiom
- [zls/build.zig](https://github.com/zigtools/zls/blob/master/build.zig) — core lib module + thin exe wrapper

Summary findings:

- **`@import("../X")` subtree restriction is intentional.** Module
  isolation is a load-bearing Zig design feature. The canonical
  workarounds are (a) named modules + `addImport`, or (b) lib
  root placed at or above the deepest reachable file.
- **`b.createModule` vs `b.addModule`** = internal vs published-to-
  Zig-package-manager. zwasm v2 ships a C ABI artifact, not a
  Zig package, so `createModule` is correct everywhere.
- **Per-zone named modules (one `addModule` per `parse/`,
  `validate/`, ...) is overkill.** Multiplies compile units,
  re-introduces the same footgun if any zone leaf attempts a
  cross-zone reach. Anti-recommendation in both surveys.
- **Single shared `Module` across artifacts (Ghostty pattern)** is
  the production-proven shape: one `core` module reused as
  `.root_module` of static lib + shared lib + wasm lib + test
  runners; the CLI exe lives in a separately-rooted module that
  imports `core` by name.
- **Self-import (Bun pattern)** — `core.addImport("zwasm", core)`
  — lets every leaf inside the subtree write `@import("zwasm")
  .runtime` to reach the central re-export hub regardless of
  depth. This is the canonical ergonomics solution for deep
  trees and frees the codebase from `../../../runtime/...` path
  fragility.

## Decision

### D-1 — Single shared `Module` rooted at `src/zwasm.zig`

Adopt the Ghostty pattern: one `core` module, multiple artifacts.

```zig
const core = b.createModule(.{
    .root_source_file = b.path("src/zwasm.zig"),
    .target = target,
    .optimize = optimize,
});
core.addImport("zwasm", core); // self-import (Bun pattern)
core.addOptions("build_options", options);

// Library artifacts share the same Module:
const lib_static = b.addLibrary(.{
    .name = "zwasm",
    .linkage = .static,
    .root_module = core,
});
// (lib_shared / lib_wasm follow the same shape post-v0.1.0)

// CLI exe has its own thin module rooted at src/cli/main.zig
// and imports core by name. main.zig's `pub fn main` no longer
// duplicates with C hosts' `int main` because it lives behind
// a separate module root.
const exe_root = b.createModule(.{
    .root_source_file = b.path("src/cli/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{ .{ .name = "zwasm", .module = core } },
});
const exe = b.addExecutable(.{ .name = "zwasm", .root_module = exe_root });

// Test runners reuse `core` directly via `.root_module = core`,
// or via a sibling test-root module that addImports core (when
// the runner has its own entry point).
```

### D-2 — `src/zwasm.zig` is the library re-export hub

`src/zwasm.zig` (new file) declares `pub const <zone> =
@import("<zone>/<entry>.zig")` for every zone. Acts as both:

1. The `core` module's `root_source_file` (so `addImport("zwasm",
   core)` exposes the hub through self-import).
2. The single source-of-truth for what is part of the zwasm
   public Zig surface.

Test loader rows (`_ = @import("...")` for unit-test discovery
that previously lived in `src/main.zig`'s `test {}` block) move
to `src/zwasm.zig`. The CLI `src/cli/main.zig` ceases to be
involved in test-loader bookkeeping.

### D-3 — Cross-zone imports use `@import("zwasm").<zone>` (named)

Within-zone (sibling-file or parent-in-same-zone) imports stay
relative — they're idiomatic Zig and don't escape any module
boundary. Cross-zone imports rewrite to the named form:

```zig
// Old (cross-zone relative — fragile to refactor, escapes nested module roots):
const runtime = @import("../runtime/runtime.zig");

// New (cross-zone named — refactor-safe, root-agnostic):
const runtime = @import("zwasm").runtime;
```

Symbol-level access stays identical (`runtime.Runtime` etc.) so
the rewrite is mechanical at the import-declaration line; no
call-site changes.

The two-tier rule:

| Import kind                              | Form                              |
|------------------------------------------|-----------------------------------|
| stdlib / builtin / build_options         | `@import("std")` etc. (unchanged) |
| within-zone sibling                      | `@import("value.zig")`            |
| within-zone parent                       | `@import("../runtime.zig")`       |
| cross-zone reference                     | `@import("zwasm").<zone>`         |

### D-4 — `api/lib_export.zig` is removed; `main.zig` moves

Two file-system moves accompany the build-system change:

- `src/api/lib_export.zig` → **deleted**. Its only purpose was
  forcing comptime inclusion of `api/{wasm,wasi,trap_surface,
  vec,instance}.zig` into the lib archive. `src/zwasm.zig`'s
  `pub const api = @import("api/wasm.zig")` (and per-symbol
  re-exports) subsumes that role through the shared `core`
  module.
- `src/main.zig` → `src/cli/main.zig`. The `pub fn main(init:
  std.process.Init) !void` entry now lives in the CLI zone where
  it belongs (zone consistency: `cli/run.zig` has been there
  since item 12). This separates the CLI exe's `main` symbol
  from the library archive cleanly.

### D-5 — `scripts/zone_check.sh` recognises the named form

The zone-dependency checker walks `@import` lines. It learns the
named form: `@import("zwasm").<zone>` is classified by `<zone>`'s
membership in the zone hierarchy declared in `.claude/rules/
zone_deps.md`. The arch-A3 cross-arch ban
(`engine/codegen/arm64` ↔ `engine/codegen/x86_64`) and the
Zone-N → Zone-(N+M) upward-import ban remain enforced.

## Alternatives considered

### Alternative A — Per-zone named modules (one `addModule` per zone)

Declare `parse`, `validate`, `runtime`, `ir`, `instruction`,
`feature`, `engine`, `wasi`, `api`, `cli`, `diagnostic`,
`support` each as separate `Module`s with explicit `addImport`
chains in build.zig. Leaf files import other zones by zone-
named module: `@import("runtime")` instead of `@import("zwasm")
.runtime`.

**Why rejected**: Both reference-codebase research and Web
research independently flagged this as overkill. It multiplies
compile units (each module is a separate compilation), forces
build.zig to maintain a 14-node dependency graph manually, and
re-introduces the subtree footgun if any zone leaf reaches into
a sibling's internals (e.g., `runtime/instance/instance.zig`
needing `parse/sections.zig` would force `runtime` module to
addImport `parse` — a cross-zone build-system dependency that
doesn't reflect a code-level decision). The one-`core`-module
approach (D-1) gets the same isolation benefits at the
zone_check.sh level without paying the build-graph cost.

### Alternative B — Restore `src/lib_export.zig` to top-level (workaround)

Move `api/lib_export.zig` back to `src/lib_export.zig` and use
that as the lib root.

**Why rejected**: Symptomatic fix; contradicts ADR-0023 §3
reference table (`api/lib_export.zig — dylib symbol export
surface`). The motivating constraint (Zig subtree restriction)
remains hidden in build.zig, so future ADR-0023-shape
refactorings hit the same trap. Records the build-system
constraint as an unwritten rule rather than a design
artifact.

### Alternative C — `src/main.zig` stays as both CLI entry and lib root

Keep `pub fn main` in `src/main.zig`, set lib root to
`src/main.zig`, and use `--no-entry` or comparable flags to
suppress the C-host duplicate-`_main` link error.

**Why rejected**: Couples CLI and library concerns at the
file-system level (one file plays two roles depending on which
artifact pulls it); `main.zig` then can't live cleanly in any
zone (cli or lib?) and the `test {}` block at the bottom mixes
test-loader concerns with the CLI argv parser. The two-file
shape (D-4) keeps each file's purpose single.

## Consequences

### Positive

- The "import of file outside module path" trap is closed at the
  build-graph level; future ADR-0023-shape directory rearrangements
  no longer need to predict which file ends up as a module root.
- `libzwasm.a` and `zwasm` (exe) compile from one shared `core`
  module, eliminating the two-roots-with-overlapping-source
  smell. Future shared lib (`libzwasm.dylib` / `.so`) and Wasm-
  guest builds (zwasm-as-a-Wasm-module) extend the same triple.
- Cross-zone imports become refactor-safe: moving
  `runtime/runtime.zig` to `runtime/core.zig` requires editing
  one re-export line in `src/zwasm.zig`, not 30+ leaf files.
- `src/cli/main.zig` lives in its zone; ROADMAP §4.1 zone
  classification stays consistent (cli is Zone 3).
- Self-import (`core.addImport("zwasm", core)`) keeps deep-tree
  ergonomics simple — `engine/codegen/arm64/emit.zig` writes
  `@import("zwasm").runtime` regardless of how nested it is.

### Negative

- One ADR-0023-shape file (`api/lib_export.zig`) is removed
  post-implementation. ADR-0023 §3 reference table is amended in
  the same commit (post-implementation correction; recorded in
  ADR-0023's Revision history).
- The bulk rewrite from `@import("../<zone>/<file>.zig")` to
  `@import("zwasm").<zone>` touches ~30 leaf files at import-
  declaration lines. Mechanical (sed-class) but visible in the
  diff; commit message lists the rule.
- `scripts/zone_check.sh` parser learns one new form. The
  existing regex (`@import\("[^"]+\.zig"\)`) widens to catch
  the named-self-import sub-expression `@import("zwasm").<zone>`.
- `src/cli/main.zig` is the CLI exe entry — its sibling-module
  shape (separate root with `addImport`) is one more thing for
  the build.zig reader to keep in mind. Documented inline.

### Neutral / follow-ups

- Naming: the named module is `"zwasm"` (the project's name).
  Self-import keeps the namespace short and readable.
- Path layout for the lib root file (`src/zwasm.zig`) places
  the library entry surface at the same depth as `src/cli/`,
  symmetric with the binary entry. Avoids a per-file zone
  classifier exception (zwasm.zig sits at Zone level "library
  surface" — described in `.claude/rules/zone_deps.md`).
- ROADMAP §5 directory layout and CLAUDE.md "Layout" sync to the
  new shape in the same commit per ROADMAP §18.2.

## References

- [Zig 0.16 build system guide](https://ziglang.org/learn/build-system/)
- [ziglang/zig issue #22284 — explicit root_module on artifacts](https://github.com/ziglang/zig/issues/22284)
- [ziggit — Importation and dependencies](https://ziggit.dev/t/importation-and-dependencies/4067)
- [ziggit — Style question: importing by module or source file](https://ziggit.dev/t/style-question-importing-by-module-or-source-file/5569)
- [ghostty/build.zig](https://github.com/ghostty-org/ghostty/blob/main/build.zig) — single-Module / triple-artifact precedent
- [bun/build.zig](https://github.com/oven-sh/bun/blob/main/build.zig) — self-import idiom
- [zls/build.zig](https://github.com/zigtools/zls/blob/master/build.zig) — core lib + thin exe wrapper
- ADR-0023 (src/ directory structure normalisation) — amended by this ADR
- ROADMAP §4.1 (Four-zone layered) / §5 (directory layout) / §18 (amendment policy)
- `.claude/rules/zone_deps.md` (updated to reflect the named-import form)

## Revision history

| Date       | Commit       | Why-class | Summary                                                   |
|------------|--------------|-----------|-----------------------------------------------------------|
| 2026-05-05 | `<backfill>` | initial   | Adopted; closes the "import of file outside module path" gap surfaced by `test-c-api` after ADR-0023 item 11 landed. |
