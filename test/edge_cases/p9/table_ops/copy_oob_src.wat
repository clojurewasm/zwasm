;; Wasm spec §4.4.15 (table.copy) — src+n > tables[y].len traps.
;; Two tables; src table has 2 entries, src=1 n=2 → src+n=3 > 2 → trap.
(module
  (table 5 funcref)
  (table 2 funcref)
  (func (export "test") (result i32)
    i32.const 0
    i32.const 1
    i32.const 2
    table.copy 0 1
    i32.const 0))
