;; GC binary tree benchmark: recursive tree construction.
;; Builds a complete binary tree of depth D, then counts nodes.
;; Tests: recursive allocation, deep object graphs, mark-and-sweep with many refs.
;;
;; Usage: --invoke gc_tree_bench 20   (depth=20 → 2^21-1 = ~2M nodes)

(module
  ;; Tree node: (value: i32, left: ref null $tree, right: ref null $tree)
  (type $tree (struct
    (field $val i32)
    (field $left (ref null $tree))
    (field $right (ref null $tree))))

  ;; Recursively build a complete binary tree of given depth.
  (func $build (param $depth i32) (result (ref $tree))
    (if (result (ref $tree)) (i32.le_s (local.get $depth) (i32.const 0))
      (then
        (struct.new $tree (i32.const 1) (ref.null $tree) (ref.null $tree)))
      (else
        (struct.new $tree
          (i32.const 0)
          (call $build (i32.sub (local.get $depth) (i32.const 1)))
          (call $build (i32.sub (local.get $depth) (i32.const 1)))))))

  ;; Count nodes in a tree.
  (func $count (param $node (ref null $tree)) (result i32)
    (if (result i32) (ref.is_null (local.get $node))
      (then (i32.const 0))
      (else
        (i32.add (i32.const 1)
          (i32.add
            (call $count (struct.get $tree $left (local.get $node)))
            (call $count (struct.get $tree $right (local.get $node))))))))

  ;; Build tree of depth D and return node count.
  (func (export "gc_tree_bench") (param $depth i32) (result i32)
    (call $count (call $build (local.get $depth))))
)
