;; i32x4.relaxed_trunc_f32x4_s (0xFD 0x101) — OOB+ → saturate INT32_MAX (v2 choice).
;; lane1 = trunc_sat(1e30) = 2147483647.
(module (func (export "test") (result i32)
  (i32x4.extract_lane 1
    (i32x4.relaxed_trunc_f32x4_s (v128.const f32x4 2.5 1e30 -3.5 4.5)))))
