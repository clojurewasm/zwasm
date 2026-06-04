;; §15.4 / D-246 chunk B boundary fixture — i16x8.extmul_low_i8x16_s
;; (arm64 SMULL .8H). Stress axis: signed widening multiply × lane.
;; Low 8 i8 lanes of A = [2,3,4,5,6,7,8,-1], B = [10,...,10].
;; Signed products -> i16: [20,30,40,50,60,70,80,-10].
;; Returns 1 iff extract_lane_s 0 == 20 AND extract_lane_s 7 == -10.
(module
  (func (export "test") (result i32)
    (local $r v128)
    (local.set $r
      (i16x8.extmul_low_i8x16_s
        (v128.const i8x16 2 3 4 5 6 7 8 -1 0 0 0 0 0 0 0 0)
        (v128.const i8x16 10 10 10 10 10 10 10 10 0 0 0 0 0 0 0 0)))
    (i32.and
      (i32.eq (i16x8.extract_lane_s 0 (local.get $r)) (i32.const 20))
      (i32.eq (i16x8.extract_lane_s 7 (local.get $r)) (i32.const -10)))))
