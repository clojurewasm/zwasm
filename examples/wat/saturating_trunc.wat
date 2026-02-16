;; Saturating truncation: clamps out-of-range floats instead of trapping
;; Run: zwasm run --invoke clamp_to_i32 examples/wat/saturating_trunc.wat 1e30
;; Expected: 2147483647 (i32 max)
(module
  (func (export "clamp_to_i32") (param f64) (result i32)
    local.get 0
    i32.trunc_sat_f64_s))
