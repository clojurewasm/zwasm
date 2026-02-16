;; Bulk memory operations: memory.fill and memory.copy
;; Run: zwasm run --invoke test examples/wat/bulk_memory.wat
;; Expected: 42
(module
  (memory 1)
  (func (export "test") (result i32)
    ;; Fill 4 bytes at offset 0 with value 42
    i32.const 0    ;; dest
    i32.const 42   ;; value
    i32.const 4    ;; length
    memory.fill
    ;; Copy 4 bytes from offset 0 to offset 100
    i32.const 100  ;; dest
    i32.const 0    ;; src
    i32.const 4    ;; length
    memory.copy
    ;; Load the copied value
    i32.const 100
    i32.load8_u))
