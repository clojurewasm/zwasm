;; Extended constant expressions (Wasm 3.0).
;; Globals can use i32.add/i32.mul in their init expressions.
;;
;; Run: zwasm run --invoke get_offset examples/wat/26_extended_const.wat
;; Output: 1024
;; Run: zwasm run --invoke get_table_size examples/wat/26_extended_const.wat
;; Output: 400
(module
  ;; Base address computed at instantiation time.
  (global $base i32 (i32.const 256))

  ;; Offset = base * 4 (extended const: i32.mul in init).
  (global $offset i32
    (i32.mul (i32.const 256) (i32.const 4)))

  ;; Table size = 20 * 20 (extended const: i32.mul in init).
  (global $table_size i32
    (i32.mul (i32.const 20) (i32.const 20)))

  (func (export "get_offset") (result i32)
    (global.get $offset))

  (func (export "get_table_size") (result i32)
    (global.get $table_size))

  (func (export "get_base") (result i32)
    (global.get $base)))
