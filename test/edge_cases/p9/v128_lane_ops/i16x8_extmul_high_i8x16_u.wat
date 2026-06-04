;; §15.4 / D-246 chunk B boundary fixture — i16x8.extmul_high_i8x16_u
;; (arm64 UMULL2 .8H). Stress axis: unsigned widening multiply × lane
;; × high-half select. High 8 i8 lanes of A = [255,2,3,4,5,6,7,8],
;; B = [2,...,2]. Unsigned products -> i16: [510,4,6,8,10,12,14,16].
;; 0xFF zero-extends to 255 (not -1), so lane 0 = 510 verifies the
;; unsigned path. Returns 1 iff extract_lane_u 0 == 510 AND
;; extract_lane_u 7 == 16.
(module
  (func (export "test") (result i32)
    (local $r v128)
    (local.set $r
      (i16x8.extmul_high_i8x16_u
        (v128.const i8x16 0 0 0 0 0 0 0 0 255 2 3 4 5 6 7 8)
        (v128.const i8x16 0 0 0 0 0 0 0 0 2 2 2 2 2 2 2 2)))
    (i32.and
      (i32.eq (i16x8.extract_lane_u 0 (local.get $r)) (i32.const 510))
      (i32.eq (i16x8.extract_lane_u 7 (local.get $r)) (i32.const 16)))))
