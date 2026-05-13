;; D-093 (d-26) / D-108 discharge — f32 global.get/set. Pre-d-26
;; path: emitGlobalGet's `f32 =>` arm returned `Error.UnsupportedOp`.
;; d-26 routes f32 globals through V-class on arm64 (S-form LDR/STR)
;; and XMM-class on x86_64 (MOVSS, F3 prefix).
;;
;; Roundtrip with f32.eq → i32:1 on success.
(module
  (global $g (mut f32) (f32.const 0))
  (func (export "test") (result i32)
    (f32.const 3.5)
    (global.set $g)
    (f32.eq (global.get $g) (f32.const 3.5))))
