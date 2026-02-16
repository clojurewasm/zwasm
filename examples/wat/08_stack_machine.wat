;; Stack machine basics: Wasm is a stack-based virtual machine.
;; This example demonstrates the implicit operand stack.
;;
;; Run: zwasm run --invoke rpn_calc examples/wat/08_stack_machine.wat
;; Output: 14
;; Computes (2 + 3) * 4 - 6 = 14 using stack operations.
(module
  ;; Evaluates (2 + 3) * 4 - 6 using pure stack manipulation.
  ;; Each instruction pushes/pops from the implicit operand stack.
  (func (export "rpn_calc") (result i32)
    i32.const 2     ;; stack: [2]
    i32.const 3     ;; stack: [2, 3]
    i32.add         ;; stack: [5]
    i32.const 4     ;; stack: [5, 4]
    i32.mul         ;; stack: [20]
    i32.const 6     ;; stack: [20, 6]
    i32.sub)        ;; stack: [14] → return 14

  ;; Demonstrate drop and local.tee.
  ;; Computes x*x + x (with x=5): 25 + 5 = 30.
  (func (export "square_plus") (param $x i32) (result i32)
    (local $copy i32)
    (local.tee $copy (local.get $x))  ;; tee: keep x on stack AND store in $copy
    (local.get $copy)                  ;; stack: [x, x]
    i32.mul                            ;; stack: [x*x]
    (local.get $copy)                  ;; stack: [x*x, x]
    i32.add))                          ;; stack: [x*x + x]
