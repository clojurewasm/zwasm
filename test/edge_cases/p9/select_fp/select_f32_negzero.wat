;; D-115 d-39 probe: untyped `select` (0x1B) on f32 operands.
;; Wasm spec §3.3.2.2 / §4.4.4 — select picks val1 if cond≠0 else
;; val2. Lower (`src/ir/lower.zig:219`) emits `.select` with
;; `extra=0`; pre-d-39 arm64/x86_64 emit defaulted `extra=0` to
;; the GPR-class i32 dispatch (CSEL Wd / CMOVNE q-form), reading
;; val1/val2 from the GPR spill slot rather than the FP slot
;; they actually occupy.
;;
;; Test selects -0.0 with cond=1 ⇒ result must be -0.0
;; (bits = 0x80000000 = -2147483648 as signed i32).
;; Pre-d-39: returns 0 (or garbage upper bits zero-extended) on
;; both arches because val1 was loaded as W-form GPR from the
;; wrong spill slot.
(module
  (func (export "test") (result i32)
    (i32.reinterpret_f32
      (select
        (f32.const -0x1p-149) ;; smallest negative f32 subnormal: bit 0x80000001
        (f32.const 0x1p-149)  ;; smallest positive f32 subnormal: bit 0x00000001
        (i32.const 1)))))
