;; D-093 (d-33) / D-104 part 2 — reftype codegen plumbing.
;;
;; Exercises the reftype-class codegen paths landed in d-33:
;;
;;   - parse: `readValType` accepts 0x70 / 0x6F (d-32).
;;   - emit (arm64 + x86_64): `local.{get,set,tee}` reftype shares
;;     the i64 X-form / R64 8-byte slot path (D-093 d-33).
;;   - op_globals.{get,set}: reftype routes through emitI64Global*
;;     on both archs (d-33).
;;
;; Per Wasm §4.5.3.1 reftype locals are zero-initialised to the
;; null reftype value; the v2 codegen materialises this as the
;; all-zero 8-byte slot (same as `ref.null t`'s lowering — see
;; arm64/emit.zig and x86_64/emit.zig `.ref.null` arms).
;;
;; Expected result: 1 AND 1 = i32:1.
(module
  (func (export "test") (result i32)
    (local funcref)
    (local externref)
    (i32.and
      (ref.is_null (local.get 0))
      (ref.is_null (local.get 1)))))
