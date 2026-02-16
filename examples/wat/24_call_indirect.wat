;; call_indirect: function pointers via a table.
;;
;; A table holds function references. call_indirect dispatches
;; by index, enabling dynamic dispatch (like vtables or callbacks).
;;
;; Run: zwasm run examples/wat/24_call_indirect.wat --invoke apply 0 10 3
;; Output: 13   (add)
;; Run: zwasm run examples/wat/24_call_indirect.wat --invoke apply 1 10 3
;; Output: 7    (sub)
;; Run: zwasm run examples/wat/24_call_indirect.wat --invoke apply 2 10 3
;; Output: 30   (mul)
(module
  (type $binop (func (param i32 i32) (result i32)))

  (func $add (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1)))
  (func $sub (param i32 i32) (result i32)
    (i32.sub (local.get 0) (local.get 1)))
  (func $mul (param i32 i32) (result i32)
    (i32.mul (local.get 0) (local.get 1)))

  (table 3 funcref)
  (elem (i32.const 0) func $add $sub $mul)

  ;; Apply operation by index: 0=add, 1=sub, 2=mul.
  (func (export "apply") (param $op i32) (param $a i32) (param $b i32) (result i32)
    (call_indirect (type $binop)
      (local.get $a) (local.get $b) (local.get $op))))
