;; Boundary: i32.trunc_f64_s with src = 2^31 = 2147483648.0
;; (exactly representable in f64). 2^31 is one above INT32_MAX;
;; spec requires trap.
;;
;; Provenance: sub-h3b's upper bound (hi = 0x41E0000000000000)
;; with `cmp = .ge` traps here.
(module
  (func (export "test") (result i32)
    f64.const 2147483648.0
    i32.trunc_f64_s))
