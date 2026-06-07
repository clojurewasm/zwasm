(module
  (memory (export "memory") 1)

  ;; Bump allocator backing cabi_realloc.
  ;; Region [0,1024) reserved: [0,8) = return area (ptr,len), [8,1024) scratch.
  ;; Allocation cursor starts at 1024.
  (global $next (mut i32) (i32.const 1024))

  ;; cabi_realloc(old_ptr, old_size, align, new_size) -> ptr
  ;; Minimal: ignore old_ptr/old_size, bump-allocate new_size (align to `align`).
  (func $cabi_realloc (export "cabi_realloc")
    (param $old_ptr i32) (param $old_size i32) (param $align i32) (param $new_size i32)
    (result i32)
    (local $ptr i32)
    (local $mask i32)
    ;; align cursor up to `align`
    (local.set $mask (i32.sub (local.get $align) (i32.const 1)))
    (global.set $next
      (i32.and
        (i32.add (global.get $next) (local.get $mask))
        (i32.xor (local.get $mask) (i32.const -1))))
    (local.set $ptr (global.get $next))
    (global.set $next (i32.add (global.get $next) (local.get $new_size)))
    (local.get $ptr))

  ;; Lowered greet: (name_ptr, name_len) -> i32 (ptr to [out_ptr, out_len] return area).
  ;; Returns a transformed string: "Hello, " ++ name ++ "!"
  ;; We build the result into freshly allocated memory via cabi_realloc.
  (func $greet (export "greet")
    (param $name_ptr i32) (param $name_len i32) (result i32)
    (local $out_ptr i32)
    (local $out_len i32)
    (local $i i32)
    ;; out_len = 7 ("Hello, ") + name_len + 1 ("!")
    (local.set $out_len (i32.add (local.get $name_len) (i32.const 8)))
    ;; allocate out_ptr = cabi_realloc(0, 0, 1, out_len)
    (local.set $out_ptr
      (call $cabi_realloc (i32.const 0) (i32.const 0) (i32.const 1) (local.get $out_len)))
    ;; write "Hello, " (7 bytes): H e l l o , space = 72 101 108 108 111 44 32
    (i32.store8 (i32.add (local.get $out_ptr) (i32.const 0)) (i32.const 72))
    (i32.store8 (i32.add (local.get $out_ptr) (i32.const 1)) (i32.const 101))
    (i32.store8 (i32.add (local.get $out_ptr) (i32.const 2)) (i32.const 108))
    (i32.store8 (i32.add (local.get $out_ptr) (i32.const 3)) (i32.const 108))
    (i32.store8 (i32.add (local.get $out_ptr) (i32.const 4)) (i32.const 111))
    (i32.store8 (i32.add (local.get $out_ptr) (i32.const 5)) (i32.const 44))
    (i32.store8 (i32.add (local.get $out_ptr) (i32.const 6)) (i32.const 32))
    ;; copy name bytes
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $name_len)))
        (i32.store8
          (i32.add (i32.add (local.get $out_ptr) (i32.const 7)) (local.get $i))
          (i32.load8_u (i32.add (local.get $name_ptr) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; write "!" at end
    (i32.store8
      (i32.add (i32.add (local.get $out_ptr) (i32.const 7)) (local.get $name_len))
      (i32.const 33))
    ;; store return area at [0]: out_ptr, out_len
    (i32.store (i32.const 0) (local.get $out_ptr))
    (i32.store (i32.const 4) (local.get $out_len))
    (i32.const 0))

  ;; cabi_post_greet(ret_area_ptr) -> () : nothing to free (bump allocator).
  (func $cabi_post_greet (export "cabi_post_greet") (param $ptr i32))
)
