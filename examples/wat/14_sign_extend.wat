;; Sign extension operations (Wasm 2.0).
;; NOTE: The CLI displays i32 results as unsigned u64.
;;
;; Run: zwasm run examples/wat/14_sign_extend.wat --invoke extend8 255
;; Output: 4294967295 (= -1 as i32, sign-extended from 0xFF)
;; Run: zwasm run examples/wat/14_sign_extend.wat --invoke extend8 127
;; Output: 127
;; Run: zwasm run examples/wat/14_sign_extend.wat --invoke extend16 65535
;; Output: 4294967295 (= -1 as i32, sign-extended from 0xFFFF)
(module
  ;; Sign-extend from 8 bits: treats low byte as signed.
  ;; 255 (0xFF) → -1 (0xFFFFFFFF), 127 (0x7F) → 127.
  (func (export "extend8") (param $x i32) (result i32)
    (i32.extend8_s (local.get $x)))

  ;; Sign-extend from 16 bits: treats low 2 bytes as signed.
  ;; 65535 (0xFFFF) → -1 (0xFFFFFFFF), 32767 → 32767.
  (func (export "extend16") (param $x i32) (result i32)
    (i32.extend16_s (local.get $x))))
