;; Dynamic memory growth with memory.grow and memory.size
;; Run: zwasm run --invoke test examples/wat/grow_memory.wat
;; Expected: 2 (memory size after growing by 1 page)
(module
  (memory 1)
  (func (export "test") (result i32)
    ;; Grow memory by 1 page (returns previous size or -1)
    i32.const 1
    memory.grow
    drop
    ;; Return current memory size in pages
    memory.size))
