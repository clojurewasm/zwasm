;; Type conversions between i32, i64, and f64.
;;
;; Run: zwasm run --invoke widen examples/wat/13_type_convert.wat 42
;; Output: 42
;; Run: zwasm run --invoke narrow examples/wat/13_type_convert.wat 100
;; Output: 100
(module
  ;; i32 → i64 (sign-extend).
  (func (export "widen") (param $x i32) (result i64)
    (i64.extend_i32_s (local.get $x)))

  ;; i64 → i32 (wrap, keeps low 32 bits).
  (func (export "narrow") (param $x i64) (result i32)
    (i32.wrap_i64 (local.get $x)))

  ;; i32 → f64.
  (func (export "to_float") (param $x i32) (result f64)
    (f64.convert_i32_s (local.get $x)))

  ;; f64 → i32 (truncate, may trap on overflow).
  (func (export "to_int") (param $x f64) (result i32)
    (i32.trunc_f64_s (local.get $x))))
