;; WASI Preview 2 component that calls wasi:cli/exit.exit(err) → host exit code 1.
;; Exercises the cli_exit trampoline (Phase D3): the P2 exit(status: result) free
;; func lowers to a core (param i32) discriminant (0=ok, 1=err) and forwards to P1
;; proc_exit, trapping the guest (noreturn) with host.exit_code set. No memory /
;; return area needed — the simplest D3 free-func vertical slice.
(component
  (import "wasi:cli/exit@0.2.0" (instance $cli-exit
    (export "exit" (func (param "status" (result))))))

  (core func $exit (canon lower (func $cli-exit "exit")))

  (core module $M
    (import "io" "exit" (func $exit (param i32)))
    (func (export "run") (result i32)
      (call $exit (i32.const 1))   ;; status = err (discriminant 1) → exit code 1
      (i32.const 0)))              ;; unreached: exit traps (noreturn)

  (core instance $deps-io (export "exit" (func $exit)))
  (core instance $m (instantiate $M (with "io" (instance $deps-io))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
