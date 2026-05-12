;; Wasm spec §4.4.15 (table.copy) — dst+n > tables[x].len traps.
;; 3-entry table; dst=1 n=3 → 1+3=4 > 3 → trap.
(module
  (table 3 funcref)
  (func (export "test") (result i32)
    i32.const 1
    i32.const 0
    i32.const 3
    table.copy 0 0
    i32.const 0))
