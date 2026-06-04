;; §15.4 / D-246 residual chunk B boundary fixture — i8x16.add_sat_u
;; (arm64 UQADD .16B). Stress axis: unsigned saturating add × lane.
;; A = i8x16 [255(=-1),...], B = [10,...] (bytes interpreted unsigned).
;; lane0: 255+10 saturates to 255 (no wrap to 9).
;; extract_lane_u 0 returns 255.
;; Returns 1 iff extract_lane_u 0 == 255.
(module
  (func (export "test") (result i32)
    (local $r v128)
    (local.set $r
      (i8x16.add_sat_u
        (v128.const i8x16 -1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
        (v128.const i8x16 10 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))
    (i32.eq (i8x16.extract_lane_u 0 (local.get $r)) (i32.const 255))))
