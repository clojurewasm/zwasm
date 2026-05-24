;; ADR-0110 Phase A.2 boundary fixture — Value-layer i32 INT_MIN
;; round-trip through global.set/get.
;;
;; Stress axis: numeric range (i32 INT_MIN). The Value extern union's
;; `.i32` variant overlaps with `.i64`/`.bits64`; this fixture asserts
;; that storing INT_MIN through `.i32` write and reading via `.i32`
;; preserves the sign bit faithfully through the Value slot.
;;
;; Behaviour-preservation contract for §9.13-V Phase A.4 cascade
;; (Value 8→16 widen per ADR-0110). Must remain green pre- and
;; post-widen — establishes the contract before the load-bearing
;; flip.
;;
;; Returns INT_MIN literal; runner expects "i32: -2147483648".
(module
  (global $g (mut i32) (i32.const 0))
  (func (export "test") (result i32)
    (global.set $g (i32.const -2147483648))
    (global.get $g)))
