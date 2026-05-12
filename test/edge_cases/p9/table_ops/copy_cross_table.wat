;; Wasm spec §4.4.15 (table.copy) — cross-table copy. Two tables;
;; copy 3 entries from table 1 into table 0. Verify slot 0 reads
;; back as null. Different tables → forward-only emit path.
(module
  (table 5 funcref)
  (table 5 funcref)
  (func (export "test") (result i32)
    i32.const 0          ;; dst
    i32.const 0          ;; src
    i32.const 3          ;; n
    table.copy 0 1       ;; cross-table
    i32.const 1
    table.get 0
    ref.is_null))
