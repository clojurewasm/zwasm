;; ADR-0077 boundary fixture — vreg-crosses-table.fill (stress
;; axis #3: register pressure / dispatch shape).
;;
;; The function pushes a sentinel i32 (V0 = 42) BEFORE invoking
;; `table.fill`, leaving V0 on the stack across the bulk handler.
;; V0's live range strictly crosses the table.fill PC, so the
;; regalloc fence (arm64/abi.zig::op_scratch_reservation_table[.
;; @"table.fill"] = {0..4}) must skip slots X9..X13 when assigning
;; V0. Without the fence, V0 lands at slot 0 = X9, gets clobbered
;; mid-emit by the funcptrs load, and the function returns garbage
;; instead of 42.
;;
;; n = 0 makes table.fill a runtime no-op (bounds check passes,
;; loop body doesn't execute), but the emit handler still clobbers
;; X9..X13 in its prologue — so the fence is exercised regardless
;; of dynamic n.
;;
;; Spec expectation: 42.
;; Pre-ADR-0077 (fence disabled): would return garbage (the
;; funcptrs pointer value derived from the runtime table desc).
(module
  (table 1 funcref)
  (func (export "test") (result i32)
    (i32.const 42)            ;; V0 — must survive table.fill
    (i32.const 0)              ;; dst
    (ref.null func)            ;; val
    (i32.const 0)              ;; n (no-op runtime, but emit still clobbers)
    (table.fill 0)))
