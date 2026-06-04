;; §15.4 / D-246 residual chunk B boundary fixture — i8x16.add_sat_s
;; (arm64 SQADD .16B). Stress axis: signed saturating add × lane.
;; A = i8x16 [127,-128,...], B = [10,-10,...].
;; lane0: 127+10 saturates to +127 (no wrap to -119).
;; lane1: -128+(-10) saturates to -128 (no wrap to +118).
;; Returns 1 iff extract_lane_s 0 == 127 AND extract_lane_s 1 == -128.
(module
  (func (export "test") (result i32)
    (local $r v128)
    (local.set $r
      (i8x16.add_sat_s
        (v128.const i8x16 127 -128 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
        (v128.const i8x16 10 -10 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))
    (i32.and
      (i32.eq (i8x16.extract_lane_s 0 (local.get $r)) (i32.const 127))
      (i32.eq (i8x16.extract_lane_s 1 (local.get $r)) (i32.const -128)))))
