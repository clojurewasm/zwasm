;; memory64 bounds check must trap when `ea + access_size` overflows
;; 64-bit. With ea = 2^64 - 4 (i64.const -4) and a 4-byte i32.load,
;; ea + 4 wraps to 0 — a plain ADD+CMP would read 0 as in-bounds and
;; skip the trap (the spec memory_trap64 -4/-2/-1 cases). The JIT now
;; emits a flag-setting ADDS + carry branch (B.HS / JC) so the wrap
;; traps. Mirrors the interp, which traps on the unwrapped address.
;;
;; Stress axes:
;;   - Numeric boundary: ea + size unsigned-overflows 2^64.
;;   - Spec-defined trap condition (bounds-check on i64 addr).
;;   - Both arches (arm64 B.HS, x86_64 JC over the same oob stub).
(module
  (memory i64 1)
  (func (export "test") (result i32)
    i64.const -4
    i32.load))
