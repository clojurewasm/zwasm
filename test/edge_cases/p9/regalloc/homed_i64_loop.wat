;; Boundary (D-265 campaign Phase IV stage 4, x86_64 parity): a register-HOMED
;; i64 local ($acc) carries a value WIDER than 32 bits across a loop back-edge.
;; $acc = 13! = 6227020800 (> 2^32). If the i64 home's get/set/prologue-seed
;; used a 32-bit MOV (the x86_64 stage-4 miscompile risk), the high dword is
;; lost every iteration and the wrapped result diverges. The function returns
;; `i32.wrap_i64 $acc` so the i32-only edge-runner can check it: 13! mod 2^32 =
;; 1932053504 — recoverable ONLY if every intermediate i64 product kept its
;; full width in the home register. ($i is a second homed i64 local.)
(module
  (func (export "test") (result i32)
    (local $i i64) (local $acc i64)
    (local.set $i (i64.const 1))
    (local.set $acc (i64.const 1))
    (block $done
      (loop $loop
        (br_if $done (i64.gt_s (local.get $i) (i64.const 13)))
        (local.set $acc (i64.mul (local.get $acc) (local.get $i)))
        (local.set $i (i64.add (local.get $i) (i64.const 1)))
        (br $loop)))
    (i32.wrap_i64 (local.get $acc))))
