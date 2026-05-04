;; Boundary: i32.trunc_f64_s with src = -2147483649.0
;; (= INT32_MIN - 1). Exactly representable in f64. trunc(src) =
;; -2147483649 doesn't fit in i32; spec requires trap.
;;
;; Provenance: sub-h3b's lower bound (lo = 0xC1E0000000200000)
;; with `lo_cmp = .le` catches this exact value.
(module
  (func (export "test") (result i32)
    f64.const -2147483649.0
    i32.trunc_f64_s))
