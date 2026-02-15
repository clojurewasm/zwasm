;; GC allocation benchmark: linked list construction + traversal.
;; Allocates N nodes (struct.new), each holding an integer and a ref to the next.
;; Then walks the list summing all values.
;; Tests: GC allocation throughput, reference traversal, collection pressure.
;;
;; Usage: --invoke gc_bench 100000   (allocate 100K nodes)

(module
  ;; Node type: (value: i32, next: ref null $node)
  (type $node (struct (field $val i32) (field $next (ref null $node))))

  ;; Build a linked list of N nodes, then walk it summing values.
  ;; Returns the sum (for correctness check).
  (func (export "gc_bench") (param $n i32) (result i32)
    (local $head (ref null $node))
    (local $i i32)
    (local $sum i32)
    (local $cur (ref null $node))

    ;; Phase 1: Build linked list of N nodes
    ;; Each node holds value i and points to previous head
    (local.set $i (i32.const 0))
    (block $build_done
      (loop $build
        (br_if $build_done (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $head
          (struct.new $node (local.get $i) (local.get $head)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $build)
      )
    )

    ;; Phase 2: Walk the list and sum all values
    (local.set $cur (local.get $head))
    (local.set $sum (i32.const 0))
    (block $walk_done
      (loop $walk
        (br_if $walk_done (ref.is_null (local.get $cur)))
        (local.set $sum (i32.add (local.get $sum)
          (struct.get $node $val (local.get $cur))))
        (local.set $cur (struct.get $node $next (local.get $cur)))
        (br $walk)
      )
    )

    (local.get $sum)
  )
)
