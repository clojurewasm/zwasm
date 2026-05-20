;; ADR-0077 boundary fixture — vreg-crosses-table.copy (stress
;; axis #3: register pressure). Sibling of vreg_crosses_table_fill;
;; same shape with `table.copy` substituted for `table.fill`.
;;
;; table.copy reserves the same {0..4} slot set per
;; op_scratch_reservation_table; n = 0 keeps it a runtime no-op
;; while still exercising the emit-time clobber.
;;
;; Spec expectation: 42.
(module
  (table 1 funcref)
  (func (export "test") (result i32)
    (i32.const 42)            ;; V0 — must survive table.copy
    (i32.const 0)              ;; dst
    (i32.const 0)              ;; src
    (i32.const 0)              ;; n
    (table.copy 0 0)))
