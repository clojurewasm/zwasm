;; Wasm spec §4.4.16 (table.init) — src+n > seg.len → trap.
;; Element segment has 1 entry; src=0 n=2 → src+n=2 > 1 → trap.
(module
  (table 3 funcref)
  (elem funcref (ref.func 0))
  (func $f0)
  (func (export "test") (result i32)
    i32.const 0
    i32.const 0
    i32.const 2          ;; n > seg.len
    table.init 0 0
    i32.const 0))
