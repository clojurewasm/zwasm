;; Boundary: i32.trunc_sat_f32_s with src = -Inf. Wasm 2.0 sat
;; semantics: -Inf → INT32_MIN = -2147483648. ARM64 FCVTZS
;; saturates negative overflow to INT_MIN naturally.
(module
  (func (export "test") (result i32)
    f32.const -inf
    i32.trunc_sat_f32_s))
