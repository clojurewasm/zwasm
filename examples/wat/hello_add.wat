;; Basic: export a function that adds two i32 values.
;;
;; Run: zwasm run --invoke add examples/wat/hello_add.wat 2 3
;; Output: 5
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add))
