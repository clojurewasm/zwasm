;; Boundary (D-265 campaign Phase II): a local ($x) is WRITTEN then READ inside
;; the loop body; a register-residency rework must invalidate the cached $x on
;; local.set (no stale register). sum of 2*i for i=5..1 = 30.
(module (func (export "test") (result i32)
  (local $i i32) (local $x i32) (local $sum i32)
  (local.set $i (i32.const 5))
  (block $done (loop $loop
    (local.set $x (i32.mul (local.get $i) (i32.const 2)))
    (local.set $sum (i32.add (local.get $sum) (local.get $x)))
    (local.set $i (i32.sub (local.get $i) (i32.const 1)))
    (br_if $loop (local.get $i))))
  (local.get $sum)))
