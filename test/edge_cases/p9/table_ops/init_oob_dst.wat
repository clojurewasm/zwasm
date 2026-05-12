;; Wasm spec §4.4.16 (table.init) — dst+n > tables[x].len → trap.
(module
  (table 3 funcref)
  (elem funcref (ref.func 0))
  (func $f0)
  (func (export "test") (result i32)
    i32.const 3          ;; dst at boundary
    i32.const 0
    i32.const 1
    table.init 0 0
    i32.const 0))
