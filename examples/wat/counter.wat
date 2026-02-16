;; Mutable global: a simple counter.
;;
;; Run: zwasm run --invoke inc examples/wat/counter.wat
;; Output: 1
;; (Each call increments from the initial value 0.)
(module
  (global $count (mut i32) (i32.const 0))

  ;; Increment the counter and return the new value.
  (func (export "inc") (result i32)
    (global.set $count (i32.add (global.get $count) (i32.const 1)))
    (global.get $count))

  ;; Read the current counter value.
  (func (export "get") (result i32)
    (global.get $count))

  ;; Reset the counter to zero.
  (func (export "reset") (result i32)
    (global.set $count (i32.const 0))
    (i32.const 0)))
