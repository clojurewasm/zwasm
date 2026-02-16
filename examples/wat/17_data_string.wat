;; Data section: initialize memory with a string at compile time.
;;
;; The (data ...) section embeds bytes directly into linear memory,
;; avoiding manual i32.store setup. Supports escape sequences like \n.
;;
;; Run: zwasm run examples/wat/17_data_string.wat --invoke char_at 0
;; Output: 72   (ASCII 'H')
;; Run: zwasm run examples/wat/17_data_string.wat --invoke length
;; Output: 6
(module
  (memory (export "memory") 1)

  ;; "Hello!" stored at offset 0 via data section.
  (data (i32.const 0) "Hello!")

  ;; Return the byte at position i in the string.
  (func (export "char_at") (param $i i32) (result i32)
    (i32.load8_u (local.get $i)))

  ;; Return the length of the string (hardcoded).
  (func (export "length") (result i32)
    (i32.const 6)))
