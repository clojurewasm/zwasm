;; Wasm spec §4.4.16 (table.init) — n=0 at the OOB boundary is
;; a no-op even after elem.drop (spec-defined).
(module
  (table 3 funcref)
  (elem funcref (ref.func 0))
  (func $f0)
  (func (export "test") (result i32)
    elem.drop 0
    i32.const 3
    i32.const 0
    i32.const 0
    table.init 0 0
    i32.const 99))
