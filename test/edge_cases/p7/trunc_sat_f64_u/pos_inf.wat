;; Boundary: i32.trunc_sat_f64_u with src = +Inf. Wasm 2.0 sat
;; semantics: +Inf → UINT32_MAX = 0xFFFFFFFF. ARM64 FCVTZU
;; saturates positive overflow to UINT_MAX naturally.
(module
  (func (export "test") (result i32)
    f64.const inf
    i32.trunc_sat_f64_u))
