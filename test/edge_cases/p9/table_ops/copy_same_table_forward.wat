;; Wasm spec §4.4.15 (table.copy) — same table, dst <= src, forward
;; copy. After copy, slot 0 reads back as null (was null pre-copy
;; from slot 2 of an empty funcref table).
(module
  (table 5 funcref)
  (func (export "test") (result i32)
    i32.const 0          ;; dst
    i32.const 2          ;; src
    i32.const 3          ;; n
    table.copy 0 0       ;; same-table, dst <= src → forward path
    i32.const 0
    table.get 0
    ref.is_null))
