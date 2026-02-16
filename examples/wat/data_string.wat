;; Memory-based string: store ASCII bytes and read them back.
;;
;; Run: zwasm run --invoke char_at examples/wat/data_string.wat 0
;; Output: 72
;; (ASCII 72 = 'H' from "Hello!")
;; Run: zwasm run --invoke length examples/wat/data_string.wat
;; Output: 6
(module
  (memory (export "memory") 1)

  ;; Initialize "Hello!" in memory at offset 0.
  ;; Called automatically by other exported functions.
  (func $init
    ;; "Hell" = 0x6C6C6548 (little-endian)
    (i32.store (i32.const 0) (i32.const 0x6C6C6548))
    ;; "o!" = 0x216F (little-endian)
    (i32.store16 (i32.const 4) (i32.const 0x216F)))

  ;; Return the byte at position i in the string.
  (func (export "char_at") (param $i i32) (result i32)
    (call $init)
    (i32.load8_u (local.get $i)))

  ;; Return the length of the string.
  (func (export "length") (result i32)
    (i32.const 6)))
