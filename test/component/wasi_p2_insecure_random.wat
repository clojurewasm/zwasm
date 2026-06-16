;; WASI Preview 2 component that calls wasi:random/insecure.get-insecure-random-bytes(16),
;; ORs the 16 returned bytes, and exit(0) iff len==16 AND some byte is nonzero, else
;; exit(1). Exercises the random_insecure_get_bytes trampoline. The insecure
;; interface's contract ("pseudo-random, not necessarily cryptographically secure")
;; is over-satisfied by the host's secure fill, so this routes to the same handler
;; as wasi:random/random — proves the insecure import resolves end-to-end.
(component
  (import "wasi:random/insecure@0.2.0" (instance $random
    (export "get-insecure-random-bytes" (func (param "len" u64) (result (list u8))))))
  (import "wasi:cli/exit@0.2.0" (instance $cli-exit
    (export "exit" (func (param "status" (result))))))

  ;; libc: memory + a bump cabi_realloc (the trampoline allocates the list here).
  (core module $libc
    (memory (export "memory") 1)
    (global $bump (mut i32) (i32.const 1024))
    (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32)
      (local $p i32)
      (local.set $p (global.get $bump))
      (global.set $bump (i32.add (global.get $bump) (local.get 3)))
      (local.get $p)))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "cabi_realloc" (core func $cabi_realloc))

  (core func $rand
    (canon lower (func $random "get-insecure-random-bytes") (memory $libc "memory") (realloc $cabi_realloc)))
  (core func $exit (canon lower (func $cli-exit "exit")))

  (core module $M
    (import "io" "rand" (func $rand (param i64 i32)))   ;; (len, retptr)
    (import "io" "exit" (func $exit (param i32)))
    (import "libc" "memory" (memory 1))
    (func (export "run") (result i32)
      (local $ptr i32) (local $len i32) (local $i i32) (local $acc i32)
      (call $rand (i64.const 16) (i32.const 16))        ;; retptr=16: ptr@16, len@20
      (local.set $ptr (i32.load (i32.const 16)))
      (local.set $len (i32.load (i32.const 20)))
      (block $done
        (loop $loop
          (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
          (local.set $acc (i32.or (local.get $acc)
            (i32.load8_u (i32.add (local.get $ptr) (local.get $i)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $loop)))
      (if (i32.and (i32.ne (local.get $acc) (i32.const 0)) (i32.eq (local.get $len) (i32.const 16)))
        (then (call $exit (i32.const 0)))
        (else (call $exit (i32.const 1))))
      (i32.const 0)))

  (core instance $deps-io (export "rand" (func $rand)) (export "exit" (func $exit)))
  (core instance $m (instantiate $M
    (with "io" (instance $deps-io))
    (with "libc" (instance $libc))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
