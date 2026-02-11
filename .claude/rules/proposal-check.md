# Proposal Implementation Checklist

Auto-loads when modifying opcode.zig, module.zig, predecode.zig for proposal work.

## Before Implementation

- [ ] Read the proposal spec: `~/Documents/OSS/WebAssembly/<repo>/proposals/<name>/Overview.md`
- [ ] Read the zwasm summary: `.dev/references/proposals/<name>.md`
- [ ] Check reference impl in wasmtime: `~/Documents/OSS/wasmtime/`
- [ ] Check reference impl in zware: `~/Documents/OSS/zware/`

## Every Commit

- [ ] `zig build test` passes
- [ ] `python3 test/spec/run_spec.py --summary` passes (ALWAYS required for proposals)
- [ ] No regression in spec pass count (must be ≥ previous count)

## Per Task Completion

- [ ] `bash bench/run_bench.sh --quick` — no performance regression
- [ ] Update `spec-support.md` if new opcodes implemented
- [ ] Update `.dev/status/proposals.yaml` status field

## Stage Boundary (first + last task)

- [ ] `bash bench/record.sh --id=TASK_ID --reason=REASON` — record baseline/final
- [ ] Update `.dev/status/compliance.yaml` pass counts

## References

- Proposal catalog: `.dev/status/proposals.yaml`
- Proposal summaries: `.dev/references/proposals/*.md`
- Spec repos: `~/Documents/OSS/WebAssembly/` (see `.dev/references/repo-catalog.yaml`)
