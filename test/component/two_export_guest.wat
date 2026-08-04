;; Identity per scalar type. The point is not the guest — it is that a value
;; leaves Clojure, crosses the canonical ABI twice, and comes back, so
;; doc/design/0012's mapping is checked rather than asserted.
(module
  ;; Aggregates arrive already lowered into our memory by the host, so echoing
  ;; one means handing back the same (ptr, len) — no copy. What it does need is
  ;; the two things doc/design/0007 named: an exported memory and cabi_realloc.
  (memory (export "memory") 1)
  ;; A bump allocator over one page that never frees: fine for one-shot
  ;; assertions, and it runs out after roughly 1500 string calls. Any
  ;; "instantiate once, call many" benchmark of the aggregate rows needs a real
  ;; allocator here, not a cljwit.host bug report.
  (global $next (mut i32) (i32.const 112))
  (func (export "cabi_realloc")
        (param $old i32) (param $old-sz i32) (param $align i32) (param $new-sz i32)
        (result i32)
    (local $p i32)
    (local.set $p (i32.and (i32.add (global.get $next)
                                    (i32.sub (local.get $align) (i32.const 1)))
                           (i32.xor (i32.sub (local.get $align) (i32.const 1))
                                    (i32.const -1))))
    (global.set $next (i32.add (local.get $p) (local.get $new-sz)))
    (local.get $p))

  ;; A result wider than one core value comes back through a pointer the callee
  ;; returns; here that is the fixed eight bytes at 0.
  (func (export "echo-string") (param $ptr i32) (param $len i32) (result i32)
    (i32.store (i32.const 0) (local.get $ptr))
    (i32.store (i32.const 4) (local.get $len))
    (i32.const 0))

  ;; enum is a discriminant and needs no memory.
  (func (export "echo-colour") (param $v i32) (result i32) (local.get $v))

  ;; option<u32> flattens to (discriminant, payload); the result is two core
  ;; values, so it comes back through a pointer. Its area is the eight bytes
  ;; at 8, kept clear of echo-string's at 0.
  (func (export "echo-option-u32") (param $disc i32) (param $val i32) (result i32)
    (i32.store (i32.const 8) (local.get $disc))
    (i32.store (i32.const 12) (local.get $val))
    (i32.const 8))

  ;; option<option<u32>> flattens to three core values; its return area is the
  ;; twelve bytes at 16.
  (func (export "echo-option-option-u32")
        (param $d0 i32) (param $d1 i32) (param $v i32) (result i32)
    (i32.store (i32.const 16) (local.get $d0))
    (i32.store (i32.const 20) (local.get $d1))
    (i32.store (i32.const 24) (local.get $v))
    (i32.const 16))

  ;; result<u32, string> flattens to a discriminant plus the join of the two
  ;; payloads: (disc, u32-or-ptr, unused-or-len). Its return area is the twelve
  ;; bytes at 32.
  (func (export "echo-result")
        (param $disc i32) (param $a i32) (param $b i32) (result i32)
    (i32.store (i32.const 32) (local.get $disc))
    (i32.store (i32.const 36) (local.get $a))
    (i32.store (i32.const 40) (local.get $b))
    (i32.const 32))

  ;; A variant flattens to a discriminant plus the join of its payloads; the
  ;; join of f64 and u32 is one i64 slot. Return area: the sixteen bytes at 48.
  (func (export "echo-shape") (param $disc i32) (param $p i64) (result i32)
    (i32.store (i32.const 48) (local.get $disc))
    (i64.store (i32.const 56) (local.get $p))
    (i32.const 48))

  ;; A list arrives as (ptr, len) already in our memory, like a string.
  ;; Return area: the eight bytes at 64.
  (func (export "echo-list-u32") (param $ptr i32) (param $len i32) (result i32)
    (i32.store (i32.const 64) (local.get $ptr))
    (i32.store (i32.const 68) (local.get $len))
    (i32.const 64))

  ;; A record flattens to its fields; the return area holds them in canonical
  ;; layout — u32 at 0, then the string's (ptr, len). Twelve bytes at 80.
  (func (export "echo-pair") (param $n i32) (param $ptr i32) (param $len i32) (result i32)
    (i32.store (i32.const 80) (local.get $n))
    (i32.store (i32.const 84) (local.get $ptr))
    (i32.store (i32.const 88) (local.get $len))
    (i32.const 80))

  ;; Up to 32 flags flatten to one i32 bitfield.
  (func (export "echo-perms") (param $bits i32) (result i32)
    (local.get $bits))

  ;; A tuple flattens like a record and returns through a retptr: u32 at 0,
  ;; then the string's (ptr, len). Twelve bytes at 96.
  (func (export "echo-tuple") (param $n i32) (param $ptr i32) (param $len i32) (result i32)
    (i32.store (i32.const 96) (local.get $n))
    (i32.store (i32.const 100) (local.get $ptr))
    (i32.store (i32.const 104) (local.get $len))
    (i32.const 96))

  (func (export "echo-bool") (param $v i32) (result i32) (local.get $v))
  (func (export "echo-s32") (param $v i32) (result i32) (local.get $v))
  (func (export "echo-u64") (param $v i64) (result i64) (local.get $v))
  (func (export "echo-f32") (param $v f32) (result f32) (local.get $v))
  (func (export "echo-f64") (param $v f64) (result f64) (local.get $v))
  (func (export "echo-char") (param $v i32) (result i32) (local.get $v)))
