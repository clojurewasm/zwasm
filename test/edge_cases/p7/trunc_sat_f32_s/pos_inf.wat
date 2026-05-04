;; Boundary: i32.trunc_sat_f32_s with src = +Inf. Wasm 2.0 sat
;; semantics: +Inf → INT32_MAX = 2147483647. ARM64 FCVTZS
;; saturates positive overflow to INT_MAX naturally.
(module
  (func (export "test") (result i32)
    f32.const inf
    i32.trunc_sat_f32_s))
