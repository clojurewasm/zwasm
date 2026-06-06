;; f32x4.relaxed_min (0xFD 0x10D) — min(3.0, 7.0)=3 at lane0 (finite distinct ⇒
;; cross-arch identical, ADR-0169). truncate to i32 for result.
(module (func (export "test") (result i32)
  (i32.trunc_f32_s (f32x4.extract_lane 0
    (f32x4.relaxed_min (v128.const f32x4 3.0 0 0 0) (v128.const f32x4 7.0 0 0 0))))))
