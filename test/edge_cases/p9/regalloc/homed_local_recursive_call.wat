;; Boundary (D-265 campaign Phase IV stage 4, x86_64 parity): a register-HOMED
;; accumulator ($sum) and counter ($k) are loop-carried AND live across a
;; RECURSIVE self-call inside the loop body. On x86_64 the homes land in
;; CALLEE-saved GPRs (RBX/R12-R14 — the whole pool is callee-saved, unlike arm64
;; whose first homes are caller-saved scratch). Each recursive callee uses the
;; SAME registers as ITS homes, so unless THIS frame's prologue snapshots + its
;; epilogue restores them (and likewise every recursive frame), the self-call
;; clobbers $sum/$k and the accumulation diverges — the observed `55 → 511` /
;; `13` x86_64 stage-4 miscompiles. The loop computes
;; sum_{k=1..6} fib(k) = 1+1+2+3+5+8 = 20, where fib is the plain recursive
;; definition; the homed accumulator must survive every recursive call.
(module
  (func $fib (param $n i32) (result i32)
    (if (i32.lt_s (local.get $n) (i32.const 2))
      (then (return (local.get $n))))
    (i32.add
      (call $fib (i32.sub (local.get $n) (i32.const 1)))
      (call $fib (i32.sub (local.get $n) (i32.const 2)))))
  (func (export "test") (result i32)
    (local $k i32) (local $sum i32)
    (local.set $k (i32.const 1))
    (local.set $sum (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.gt_s (local.get $k) (i32.const 6)))
        (local.set $sum (i32.add (local.get $sum) (call $fib (local.get $k))))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)))
    (local.get $sum)))
