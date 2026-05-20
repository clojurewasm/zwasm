;; ADR-0077 boundary fixture — vreg-crosses-table.init (stress
;; axis #3: register pressure). Sibling of vreg_crosses_table_fill.
;;
;; table.init reads from a passive elem segment into a table; needs
;; an `(elem)` declaration in the module. n = 0 keeps the runtime
;; behaviour a no-op while still exercising the emit clobber.
;;
;; Spec expectation: 42.
(module
  (table 1 funcref)
  (elem (i32.const 0) func)
  (func (export "test") (result i32)
    (i32.const 42)            ;; V0 — must survive table.init
    (i32.const 0)              ;; dst
    (i32.const 0)              ;; src
    (i32.const 0)              ;; n
    (table.init 0 0)))
