;; Minimal component exercising the core-TABLE index space (E2 engine prereq,
;; ADR-0175): a core instance exports a table, and an `alias core export` lifts
;; it into the component-level core-table index space — the shape wit-bindgen's
;; $fixup-args uses to re-export the shim's $imports table.
(component
  (core module $m
    (table (export "tbl") 1 funcref)
    (func (export "f")))
  (core instance $mi (instantiate $m))
  (alias core export $mi "tbl" (core table $t))
)
