;; Wasm 3.0 GC: ref.cast to a CONCRETE type index ≥ 64 (D-453). 65 struct
;; types so type index 64 needs a 2-byte SLEB128 heap-type immediate
;; (indices 0..63 fit one byte; ≥ 64 is multi-byte). The byte-wide decoder
;; (validator opRefTest/opRefCast + lower.zig + the runtime/JIT type-test)
;; read exactly ONE byte and left a continuation byte to be mis-read as the
;; next opcode — desyncing the decoder for any index ≥ 64. Fixed by decoding
;; the full SLEB and threading the u32 heap-type (encoded: idx ≥ 64 tagged
;; with bit31) through IR / interp / JIT.
;;
;; `test`: struct.new $64 (field = 99) → widen to (ref eq) → ref.cast back to
;; the concrete (ref 64) → struct.get $64 0 → 99. Exercises the idx-64 cast.
;;
;; Stress axes (test_discipline.md §1): GC concrete-type cast × multi-byte
;; SLEB heap-type immediate (validator + lower + runtime decoder boundary at
;; index 64). Returns the struct field = 99.
;;
;; Provenance: private/notes/d453_refcast_idx64_repro.wat, made runnable
;; (mirrors canonical_eq_call_arg.wat's exported `test (result i32)`).
(module
  (type (;0;) (struct (field i32)))
  (type (;1;) (struct (field i32)))
  (type (;2;) (struct (field i32)))
  (type (;3;) (struct (field i32)))
  (type (;4;) (struct (field i32)))
  (type (;5;) (struct (field i32)))
  (type (;6;) (struct (field i32)))
  (type (;7;) (struct (field i32)))
  (type (;8;) (struct (field i32)))
  (type (;9;) (struct (field i32)))
  (type (;10;) (struct (field i32)))
  (type (;11;) (struct (field i32)))
  (type (;12;) (struct (field i32)))
  (type (;13;) (struct (field i32)))
  (type (;14;) (struct (field i32)))
  (type (;15;) (struct (field i32)))
  (type (;16;) (struct (field i32)))
  (type (;17;) (struct (field i32)))
  (type (;18;) (struct (field i32)))
  (type (;19;) (struct (field i32)))
  (type (;20;) (struct (field i32)))
  (type (;21;) (struct (field i32)))
  (type (;22;) (struct (field i32)))
  (type (;23;) (struct (field i32)))
  (type (;24;) (struct (field i32)))
  (type (;25;) (struct (field i32)))
  (type (;26;) (struct (field i32)))
  (type (;27;) (struct (field i32)))
  (type (;28;) (struct (field i32)))
  (type (;29;) (struct (field i32)))
  (type (;30;) (struct (field i32)))
  (type (;31;) (struct (field i32)))
  (type (;32;) (struct (field i32)))
  (type (;33;) (struct (field i32)))
  (type (;34;) (struct (field i32)))
  (type (;35;) (struct (field i32)))
  (type (;36;) (struct (field i32)))
  (type (;37;) (struct (field i32)))
  (type (;38;) (struct (field i32)))
  (type (;39;) (struct (field i32)))
  (type (;40;) (struct (field i32)))
  (type (;41;) (struct (field i32)))
  (type (;42;) (struct (field i32)))
  (type (;43;) (struct (field i32)))
  (type (;44;) (struct (field i32)))
  (type (;45;) (struct (field i32)))
  (type (;46;) (struct (field i32)))
  (type (;47;) (struct (field i32)))
  (type (;48;) (struct (field i32)))
  (type (;49;) (struct (field i32)))
  (type (;50;) (struct (field i32)))
  (type (;51;) (struct (field i32)))
  (type (;52;) (struct (field i32)))
  (type (;53;) (struct (field i32)))
  (type (;54;) (struct (field i32)))
  (type (;55;) (struct (field i32)))
  (type (;56;) (struct (field i32)))
  (type (;57;) (struct (field i32)))
  (type (;58;) (struct (field i32)))
  (type (;59;) (struct (field i32)))
  (type (;60;) (struct (field i32)))
  (type (;61;) (struct (field i32)))
  (type (;62;) (struct (field i32)))
  (type (;63;) (struct (field i32)))
  (type (;64;) (struct (field i32)))
  (func (export "test") (result i32)
    (local (ref null eq))
    i32.const 99
    struct.new 64
    local.set 0
    local.get 0
    ref.cast (ref 64)
    struct.get 64 0))
