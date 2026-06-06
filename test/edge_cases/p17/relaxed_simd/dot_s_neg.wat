;; i16x8.relaxed_dot_i8x16_i7x16_s — NEGATIVE a (signedness regression guard;
;; x86 PMADDUBSW must treat a as SIGNED). a=-1 (0xFF) ×16, b=2 ×16.
;; lane0 = a[0]*b[0]+a[1]*b[1] = (-1*2)+(-1*2) = -4.
(module (func (export "test") (result i32)
  (i16x8.extract_lane_s 0
    (i16x8.relaxed_dot_i8x16_i7x16_s
      (v128.const i8x16 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1)
      (v128.const i8x16 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2)))))
