;; Boundary: i32.trunc_sat_f64_u with src = -Inf. Wasm 2.0 sat
;; semantics: -Inf → 0 for unsigned destination (saturates to
;; the type's minimum, which is 0 for u32). ARM64 FCVTZU
;; clamps to 0 naturally.
(module
  (func (export "test") (result i32)
    f64.const -inf
    i32.trunc_sat_f64_u))
