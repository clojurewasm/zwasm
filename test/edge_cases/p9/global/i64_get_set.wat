;; D-093 (d-26) / D-108 discharge — i64 global.get/set on both
;; archs. Pre-d-26 path: emitGlobalGet's `i64 =>` arm returned
;; `Error.UnsupportedOp`. d-26 adds X-form LDR/STR (arm64) and
;; REX.W MOV [base+disp32] (x86_64) for the 8-byte slot.
;;
;; Roundtrip: store a non-trivial i64 (with both halves non-zero
;; to catch 32-bit-truncating regressions), reload, compare. The
;; edge runner takes i32 results, so we eq → i32:1 on success.
(module
  (global $g (mut i64) (i64.const 0))
  (func (export "test") (result i32)
    (i64.const 0x0123456789ABCDEF)
    (global.set $g)
    (i64.eq (global.get $g) (i64.const 0x0123456789ABCDEF))))
