;; f64x2.relaxed_madd (0xFD 0x107) — a*b+c, lane0 = 6*7+8 = 50.
(module (func (export "test") (result i32)
  (i32.trunc_f64_s (f64x2.extract_lane 0
    (f64x2.relaxed_madd (v128.const f64x2 6 0) (v128.const f64x2 7 0) (v128.const f64x2 8 0))))))
