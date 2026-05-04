;; Boundary: i32.trunc_f32_s with src = NaN. Spec requires
;; "invalid conversion to integer" trap. The NaN check via FCMP
;; src,src ; B.VS trap at sub-h3a's emit pass catches this.
;;
;; NaN representation: any f32 with exponent=0xFF and non-zero
;; mantissa. Use 0x7FC00000 (canonical quiet NaN).
(module
  (func (export "test") (result i32)
    f32.const nan
    i32.trunc_f32_s))
