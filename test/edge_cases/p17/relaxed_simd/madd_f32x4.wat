;; f32x4.relaxed_madd (0xFD 0x105) — a*b+c, lane0 = 3*5+4 = 19 (exact ⇒
;; fused==unfused, cross-arch identical per ADR-0169).
(module (func (export "test") (result i32)
  (i32.trunc_f32_s (f32x4.extract_lane 0
    (f32x4.relaxed_madd (v128.const f32x4 3 0 0 0) (v128.const f32x4 5 0 0 0) (v128.const f32x4 4 0 0 0))))))
