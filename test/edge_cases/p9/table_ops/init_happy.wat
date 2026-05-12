;; Wasm spec §4.4.16 (table.init) — copy 2 entries from passive
;; element segment 0 into table 0 at slot 1. Verify slot 1 reads
;; back as non-null (the segment stores funcref to f0).
(module
  (table 3 funcref)
  (elem funcref (ref.func 0))
  (func $f0)
  (func (export "test") (result i32)
    i32.const 1          ;; dst
    i32.const 0          ;; src
    i32.const 1          ;; n
    table.init 0 0       ;; elemidx=0, tableidx=0
    i32.const 1
    table.get 0
    ref.is_null))
