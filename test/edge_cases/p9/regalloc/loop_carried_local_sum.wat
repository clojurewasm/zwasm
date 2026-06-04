;; Boundary (D-265 campaign Phase II): loop body READS a loop-carried local
;; ($i) every iteration AND $i is reassigned via local.set across the back-edge.
;; Pins correct value so a register-residency rework cannot regress it.
(module (func (export "test") (result i32)
  (local $i i32) (local $sum i32)
  (local.set $i (i32.const 10))
  (block $done (loop $loop
    (local.set $sum (i32.add (local.get $sum) (local.get $i)))
    (local.set $i (i32.sub (local.get $i) (i32.const 1)))
    (br_if $loop (local.get $i))))
  (local.get $sum)))
