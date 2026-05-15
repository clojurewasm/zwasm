;; Wasm spec §4.4.13 (table.grow) — declared `(table 0 4
;; externref)` has min=0 max=4. Successive grows: 2 (→ 2),
;; 1 (→ 3), 2 (→ -1, would overflow max). Final return is
;; the rejected grow's sentinel (= -1 = 0xffffffff = u32 max).
(module
  (table $t 0 4 externref)
  (func (export "test") (result i32)
    (drop (table.grow $t (ref.null extern) (i32.const 2)))
    (drop (table.grow $t (ref.null extern) (i32.const 1)))
    (table.grow $t (ref.null extern) (i32.const 2))))
