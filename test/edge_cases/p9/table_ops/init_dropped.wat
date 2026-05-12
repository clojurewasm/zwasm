;; Wasm spec §4.4.16 (table.init) — after elem.drop the segment
;; is treated as length 0; any n > 0 traps.
(module
  (table 3 funcref)
  (elem funcref (ref.func 0))
  (func $f0)
  (func (export "test") (result i32)
    elem.drop 0
    i32.const 0
    i32.const 0
    i32.const 1
    table.init 0 0
    i32.const 0))
