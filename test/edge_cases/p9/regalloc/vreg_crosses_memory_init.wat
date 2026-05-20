;; ADR-0077 boundary fixture — vreg-crosses-memory.init (stress
;; axis #3: register pressure). Sibling of vreg_crosses_table_fill,
;; this one exercises the op_memory.zig handler.
;;
;; memory.init reads from a passive data segment into linear
;; memory; needs a passive `(data)` declaration. n = 0 keeps it a
;; runtime no-op while still exercising the emit clobber.
;;
;; Spec expectation: 42.
(module
  (memory 1)
  (data "")
  (func (export "test") (result i32)
    (i32.const 42)            ;; V0 — must survive memory.init
    (i32.const 0)              ;; dst
    (i32.const 0)              ;; src
    (i32.const 0)              ;; n
    (memory.init 0)))
