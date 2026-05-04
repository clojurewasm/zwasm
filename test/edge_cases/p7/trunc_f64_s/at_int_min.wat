;; Boundary: i32.trunc_f64_s with src = -2^31 exactly.
;; Provenance: sub-h3b's f64-source bounds. -2147483648.0 IS the
;; smallest valid INT32 and exactly representable in f64 (53-bit
;; mantissa easily covers 32-bit integers).
;;
;; trunc(src) = INT32_MIN, fits in i32, no trap.
(module
  (func (export "test") (result i32)
    f64.const -2147483648.0
    i32.trunc_f64_s))
