;; D-093 (d-26) / D-108 discharge — f64 global.get/set on both
;; archs. The triggering fixture from upstream
;; `call_indirect.wast:as-global.set-value` exercises this exact
;; shape (call_indirect→f64→global.set→global.get→return f64).
;; Pre-d-26 path: emitGlobalGet's `f64 =>` arm returned
;; `Error.UnsupportedOp`. d-26 routes via D-form LDR/STR (arm64)
;; and MOVSD with F2 prefix (x86_64).
;;
;; Roundtrip with f64.eq → i32:1 on success.
(module
  (global $g (mut f64) (f64.const 0))
  (func (export "test") (result i32)
    (f64.const 1.5)
    (global.set $g)
    (f64.eq (global.get $g) (f64.const 1.5))))
