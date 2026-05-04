# engine/codegen/x86_64

Reserved subsystem slot per ADR-0023 §3 reference table + §3 P-C
(engine sibling parity).

Implementation phase: §9.7 / 7.6 — ARM64 baseline lands first
(items 1-8 of §9.7), then this directory mirrors `arm64/`'s
shape (`emit.zig`, `op_*.zig`, `bounds_check.zig`, `inst.zig`,
`abi.zig` (System V + Win64), `prologue.zig`, `label.zig`).

Until §9.7 / 7.6 opens, this directory is intentionally empty
except for this README.
