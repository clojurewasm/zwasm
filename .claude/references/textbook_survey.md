# Textbook survey before implementation — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/textbook_survey.md`](../rules/textbook_survey.md).

# Textbook survey before implementation

Auto-loaded when editing Zig sources. Codifies how the `/continue`
per-task TDD loop's **Step 0 (Survey)** consults the reference
codebases without being pulled by their styles.

## The textbooks

| Path                                              | What it teaches                                                          | When to use                                                             |
|---------------------------------------------------|--------------------------------------------------------------------------|-------------------------------------------------------------------------|
| `~/Documents/MyProducts/zwasm/`                   | zwasm v1, ~65K LOC, the immediate predecessor                            | Always when introducing or replacing a v1 feature                       |
| `~/Documents/OSS/wasmtime/cranelift/`             | CLIF + VCode + regalloc2 + ISLE                                          | When designing IR shape, regalloc, or the JIT mid-layer                 |
| `~/Documents/OSS/wasmtime/winch/`                 | Single-pass JIT, MacroAssembler abstraction                              | When designing the per-arch emit layer                                  |
| `~/Documents/OSS/zware/`                          | Zig idiomatic Wasm interpreter                                           | When deciding Zig data structures / allocator threading / module layout |
| `~/Documents/OSS/wasm3/`                          | M3 IR + tail-call dispatch                                               | When designing the interpreter inner loop                               |
| `~/Documents/OSS/wasmer/lib/compiler-singlepass/` | Wasmer singlepass, per-target emit                                       | When the per-arch emit layer needs a second reference                   |
| `~/Documents/OSS/wazero/`                         | Go-based dual-engine runtime                                             | When deciding interpreter vs JIT engine selection                       |
| `~/Documents/OSS/wasm-c-api/include/wasm.h`       | Industry-standard C ABI                                                  | When `wasm.h`-implementation work is at stake                           |
| `~/Documents/OSS/regalloc2/`                      | Cranelift register allocator                                             | When designing regalloc invariants and verify()                         |
| `~/Documents/OSS/wasm-tools/`                     | wasm-tools smith, validate, parse                                        | When fuzz corpus generation or wasm parsing edge cases                  |
| `~/Documents/OSS/sightglass/`                     | Bytecode Alliance bench suite                                            | When designing bench/runners/                                           |
| `~/Documents/OSS/wasm-micro-runtime/`             | WAMR — interpreter + AOT + lightweight runtime                           | When comparing to small-footprint engine designs                        |
| `~/Documents/OSS/cap-std/`                        | Capability-based std for Rust                                            | When designing WASI capabilities                                        |
| `~/Documents/OSS/wit-bindgen/`                    | Component Model bindgen                                                  | (post-v0.1.0) WIT / Component Model work                                |
| `~/Documents/OSS/zig/lib/std/`                    | Zig 0.16 stdlib                                                          | When `std.Io.*` / `std.atomic.*` / `std.process.*` API is in question   |
| `~/Documents/OSS/WebAssembly/spec/`               | Reference interpreter (OCaml) + spec text                                | When semantic edge cases are the question                               |
| `~/Documents/OSS/WebAssembly/testsuite/`          | Spec testsuite                                                           | When deciding what tests to import                                      |
| `~/Documents/OSS/WebAssembly/<proposal>/`         | Per-proposal spec + test bundles                                         | When designing for a specific Wasm proposal                             |
| `~/zwasm/private/v2-investigation/`               | Pre-skeleton design surveys (16 files including CONCLUSION, ~7000 lines) | The design rationale for *this* project                                 |

## Survey discipline (gate)

Step 0 of the TDD loop dispatches an Explore subagent to survey how
the concept is implemented in v1 + 1–2 industry references; the
deliverable is 200–400 lines naming files / line ranges / data shapes /
2–3 likely **DIVERGENCE** points based on ROADMAP §2 principles.

The five anti-pull guards (cite ROADMAP before adopting v1 idiom;
always note one DIVERGENCE; §14-forbidden patterns stay forbidden;
W54-lessons mandatory for regalloc / per-arch work; **no copy-paste**)
are load-bearing — see
[`references/textbook_survey_skip_rules.md`](../references/textbook_survey_skip_rules.md)
for the worked-out form, the narrow "continuation of prior task"
skip definition, and the v1-monolith-file trap discipline.

**Skip Step 0 only when ALL hold**: refactor / rename / doc-only
change OR scaffolding verification, AND no new public API, AND no
externally-observable behaviour change. **Adding any new `encXxx`
function, helper, scratch-reg reservation, multi-instr synthesis
pattern, or const-pool entry forfeits skip eligibility** even under
the same parent ROADMAP row. `audit_scaffolding §G` walks recent
commits to verify Step 0 was actually run when required.

If you discover mid-implementation that you skipped Step 0 when you
shouldn't have, **dispatch the Explore subagent now**, even if code is
already written. The survey informs the Step 4 refactor pass.

The summary lands in `private/notes/<phase>-<task>-survey.md`
(gitignored, optional). ADR-grade decisions surfaced from a survey
land at `.dev/decisions/NNNN_<slug>.md` per ROADMAP §18.

詳細(各 Guard の正確な条件、§9.6 worked examples, v1-monolith trap,
mid-cycle correction) は
[`references/textbook_survey_skip_rules.md`](../references/textbook_survey_skip_rules.md)
を参照。

