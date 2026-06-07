;; D-306 proof fixture — identical to wasi_p2_hello.wat EXCEPT the core-level
;; import/export names are deliberately renamed to opaque "p0"/"p1"/"p2" (vs the
;; conventional get-stdout/write/drop-os). The component-level WASI interfaces
;; (wasi:cli/stdout, wasi:io/streams) are UNCHANGED. If this still prints
;; "hello\n", the host selected each trampoline by its COMPONENT interface
;; (classified wiring), NOT by the core module's import name.
(component
  (import "wasi:io/error@0.2.0" (instance $io-error
    (export "error" (type (sub resource)))))
  (alias export $io-error "error" (type $error))

  (import "wasi:io/streams@0.2.0" (instance $io-streams
    (alias outer 1 $error (type $error-in))
    (export "error" (type $error-ex (eq $error-in)))
    (export "output-stream" (type $output-stream (sub resource)))
    (type $stream-error-def (variant (case "last-operation-failed" (own $error-ex)) (case "closed")))
    (export "stream-error" (type $stream-error (eq $stream-error-def)))
    (type $borrow-os (borrow $output-stream))
    (type $list-u8 (list u8))
    (export "[method]output-stream.blocking-write-and-flush"
      (func (param "self" $borrow-os) (param "contents" $list-u8) (result (result (error $stream-error)))))))
  (alias export $io-streams "output-stream" (type $output-stream))

  (import "wasi:cli/stdout@0.2.0" (instance $cli-stdout
    (alias outer 1 $output-stream (type $os-out))
    (export "output-stream" (type (eq $os-out)))
    (type $own-os (own $os-out))
    (export "get-stdout" (func (result $own-os)))))

  (core func $get-stdout
    (canon lower (func $cli-stdout "get-stdout")))
  (core module $libc (memory (export "memory") 1))
  (core instance $libc (instantiate $libc))
  (core func $write
    (canon lower (func $io-streams "[method]output-stream.blocking-write-and-flush")
      (memory $libc "memory")))
  (core func $drop-os
    (canon resource.drop $output-stream))

  ;; core module — imports under OPAQUE names p0/p1/p2 (not get-stdout/write/drop-os).
  (core module $M
    (import "io" "p0" (func $get-stdout (result i32)))
    (import "io" "p1" (func $write (param i32 i32 i32 i32)))
    (import "io" "p2" (func $drop-os (param i32)))
    (import "libc" "memory" (memory 1))
    (data (i32.const 16) "hello\n")
    (func (export "run") (result i32)
      (local $stream i32)
      (local.set $stream (call $get-stdout))
      (call $write (local.get $stream) (i32.const 16) (i32.const 6) (i32.const 128))
      (call $drop-os (local.get $stream))
      (i32.const 0)))

  (core instance $deps-io (export "p0" (func $get-stdout))
                          (export "p1" (func $write))
                          (export "p2" (func $drop-os)))
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
