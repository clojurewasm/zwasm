;; Wasm spec §4.4.13 (table.grow) — happy path. A no-max `(table 2 funcref)`
;; grows by 3 to size 5: table.grow returns the old size (2, dropped) and
;; table.size then reads 5. Under the JIT this exercises D-501's synthesized
;; grow cap for a no-max table (`max(min*2, 1024)`); the interpreter grows
;; unbounded. Growth REJECTION (grow past a bound → -1) is covered by the
;; sibling grow_max_cap.wat. (Pre-D-501 the JIT's default table_grow_fn
;; rejected any no-max grow, so this fixture used to assert size = 2.)
(module
  (table 2 funcref)
  (func (export "test") (result i32)
    (drop (table.grow 0 (ref.null func) (i32.const 3)))
    table.size 0))
