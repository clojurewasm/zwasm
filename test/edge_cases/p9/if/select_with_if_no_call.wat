;; D-097 d-18 probe: `select` consuming an i32 `if`-result without
;; any calls in the if-arms. If this passes on x86_64 the residual
;; `as-select-mid/last` bug is call-induced (= regalloc spill
;; interaction); if it fails the bug is in the basic select+if
;; merge sequence on x86_64.
;;
;; Expected: select(2, 0, 3). cond=3≠0 → val1=2. Result = 2.
(module
  (func (export "test") (result i32)
    (select
      (i32.const 2)
      (if (result i32) (i32.const 0)
        (then (i32.const 1))
        (else (i32.const 0)))
      (i32.const 3))))
