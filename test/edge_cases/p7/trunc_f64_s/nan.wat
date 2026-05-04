;; Boundary: i32.trunc_f64_s with src = NaN. Spec requires
;; "invalid conversion to integer" trap. The NaN check via
;; FCMP src,src; B.VS trap at sub-h3b's emit pass catches this.
(module
  (func (export "test") (result i32)
    f64.const nan
    i32.trunc_f64_s))
