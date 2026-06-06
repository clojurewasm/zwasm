;; f64x2.relaxed_max (0xFD 0x110) — max(8.0, 2.0)=8 at lane0.
(module (func (export "test") (result i32)
  (i32.trunc_f64_s (f64x2.extract_lane 0
    (f64x2.relaxed_max (v128.const f64x2 8.0 0) (v128.const f64x2 2.0 0))))))
