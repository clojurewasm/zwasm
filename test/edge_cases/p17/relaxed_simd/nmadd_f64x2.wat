;; f64x2.relaxed_nmadd (0xFD 0x108) — -(a*b)+c, lane0 = -(6*7)+50 = 8.
(module (func (export "test") (result i32)
  (i32.trunc_f64_s (f64x2.extract_lane 0
    (f64x2.relaxed_nmadd (v128.const f64x2 6 0) (v128.const f64x2 7 0) (v128.const f64x2 50 0))))))
