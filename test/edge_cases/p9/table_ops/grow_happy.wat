;; Wasm spec §4.4.13 (table.grow) — default `table_grow_fn`
;; rejects growth (returns -1 per Wasm 2.0 §4.4.10.1 host-
;; refuses semantics). The standalone runner uses the default
;; callout, so this fixture asserts the host-rejection
;; observable: table.grow returns -1, table.size stays at the
;; declared minimum (= 2).
(module
  (table 2 funcref)
  (func (export "test") (result i32)
    (drop (table.grow 0 (ref.null func) (i32.const 3)))
    table.size 0))
