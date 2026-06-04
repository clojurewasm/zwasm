;; Boundary (D-265 campaign Phase II): multiple loop-carried locals ($i,$a,$b)
;; all read in the body each iteration — stresses residency + pressure together.
;; a = 6+..+1 = 21; b = 3*21 = 63; a+b = 84.
(module (func (export "test") (result i32)
  (local $i i32) (local $a i32) (local $b i32)
  (local.set $i (i32.const 6))
  (block $done (loop $loop
    (local.set $a (i32.add (local.get $a) (local.get $i)))
    (local.set $b (i32.add (local.get $b) (i32.mul (local.get $i) (i32.const 3))))
    (local.set $i (i32.sub (local.get $i) (i32.const 1)))
    (br_if $loop (local.get $i))))
  (i32.add (local.get $a) (local.get $b))))
