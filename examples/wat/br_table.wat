;; br_table: indexed branch (like a switch statement).
;;
;; Run: zwasm run --invoke day_kind examples/wat/br_table.wat 0
;; Output: 1
;; (0=Sun→1=weekend, 1..5=Mon-Fri→0=weekday, 6=Sat→1=weekend)
(module
  ;; Returns 1 for weekend (0=Sun, 6=Sat), 0 for weekday (1-5).
  ;; Input 0-6 maps to Sun-Sat.
  (func (export "day_kind") (param $day i32) (result i32)
    (block $weekend (block $weekday (block $default
      (br_table
        $weekend   ;; 0: Sunday → weekend
        $weekday   ;; 1: Monday → weekday
        $weekday   ;; 2: Tuesday → weekday
        $weekday   ;; 3: Wednesday → weekday
        $weekday   ;; 4: Thursday → weekday
        $weekday   ;; 5: Friday → weekday
        $weekend   ;; 6: Saturday → weekend
        $default   ;; default: out of range
        (local.get $day)))
      ;; $default: treat out-of-range as weekday
      (return (i32.const 0)))
    ;; $weekday
    (return (i32.const 0)))
    ;; $weekend
    (i32.const 1)))
