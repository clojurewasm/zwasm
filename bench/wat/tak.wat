;; Takeuchi function — deeply recursive, integer-only
;; tak(18, 12, 6) = 7, ~500K recursive calls
(module
  (func $tak (export "tak") (param $x i32) (param $y i32) (param $z i32) (result i32)
    (if (result i32) (i32.le_s (local.get $x) (local.get $y))
      (then (local.get $z))
      (else
        (call $tak
          (call $tak (i32.sub (local.get $x) (i32.const 1)) (local.get $y) (local.get $z))
          (call $tak (i32.sub (local.get $y) (i32.const 1)) (local.get $z) (local.get $x))
          (call $tak (i32.sub (local.get $z) (i32.const 1)) (local.get $x) (local.get $y))
        )
      )
    )
  )
)
