struct Point { x : Int; y : Int }
struct Span { lo : Point; hi : Point }
struct Boxed { inner : Point; tag : Int }
enum Tree { Leaf(Int); Pair(Tree, Tree); Wide(Int, Int, Int) }
fn choose(k : Int) -> Point { if k % 2 == 0 { { x: k, y: k + 1 } } else { { x: k * 2, y: k - 1 } } }
fn span(k : Int) -> Span { { lo: choose(k), hi: choose(k + 3) } }
fn area(s : Span) -> Int { (s.hi.x - s.lo.x) * (s.hi.y - s.lo.y) }
fn wrap(k : Int) -> Boxed { { inner: choose(k), tag: k * 3 } }
fn build(d : Int, v : Int) -> Tree { if d == 0 { Leaf(v) } else if d == 2 { Wide(v, v + 1, v + 2) } else { Pair(build(d - 1, v * 2), build(d - 1, v * 2 + 1)) } }
fn total(t : Tree) -> Int { match t { Leaf(v) => v; Wide(a, b, c) => a + b + c; Pair(l, r) => total(l) + total(r) } }
fn half(k : Int) -> Int? { if k % 2 == 0 { Some(k / 2) } else { None } }
fn tally(k : Int) -> Int { if k == 0 { 0 } else { (match half(k) { None => 1; Some(v) => v }) + tally(k - 1) } }
fn minmax(k : Int) -> (Int, Int) { if k < 5 { (k, 5) } else { (5, k) } }
fn spread(k : Int) -> Int { let (a, b) = minmax(k); b - a }
pub fn compute() -> Int {
  let geom = area(span(4)) + area(span(7)) + area(span(12))
  let trees = total(build(4, 1)) + total(build(5, 2))
  let opts = tally(9) + tally(14)
  let pairs = spread(2) + spread(11)
  let boxes = wrap(5).tag + wrap(6).inner.x
  geom + trees + opts + pairs + boxes
}
fn main { ignore(compute()) }
