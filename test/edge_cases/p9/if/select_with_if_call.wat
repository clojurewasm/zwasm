;; D-097 d-18 probe: `select` consuming an i32 `if`-result that
;; spans calls (force-spilled per ADR-0060). Mirrors
;; `if.wast:as-select-mid(i32:0)`. cond_if=0 → else-arm: returns 0.
;; Outer select: cond=3≠0 → val1=2. Expected 2.
(module
  (func $dummy)
  (func (export "test") (result i32)
    (select
      (i32.const 2)
      (if (result i32) (i32.const 0)
        (then (call $dummy) (i32.const 1))
        (else (call $dummy) (i32.const 0)))
      (i32.const 3))))
