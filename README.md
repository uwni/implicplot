# Implicplot

Draw any implicit relation `f(x, y) op g(x, y)` using interval arithmetic.
A Zig 0.16 rewrite of the JavaScript implementation in [`../src`](../src).

```console
$ zig build -Doptimize=ReleaseFast
$ ./zig-out/bin/implicit-plot "sin(x^2 + y^2) = cos(x*y)"
sin(x^2 + y^2) = cos(x*y)
  1024 x 1024 px over x in [-10, 10], y in [-10, 10]
  wrote plot.png
  69544 of 1048576 pixels lit in 24.1ms
```

`zig build run -- --help` lists the options: image size, ranges, output path,
sub-pixel refinement depth, worker count, and ASCII output.

## How it works

A box of the plane is either entirely in the solution set, entirely out of it,
or undecided. Interval arithmetic answers that question soundly: evaluate the
relation with intervals instead of numbers and the result *encloses* every value
`f` takes on the box. A quadtree subdivides the undecided boxes until they are
one pixel, then a little further.

```text
  text  --parse-->  Program (flat DAG)  --eval-->  Interval / Real
                             |                          |
                             +--------- Relation --------+
                                            |
                                        plot.render  -->  Raster  -->  PNG / ASCII
```

| file | what it holds |
| --- | --- |
| `interval.zig` | interval arithmetic over `lanes` boxes at a time, plus three-valued logic |
| `real.zig` | the same operations on plain floats, `lanes` points at a time |
| `expr.zig` | the flat topologically-ordered node array, and the hash-consing builder |
| `parse.zig` | `"sin(x^2+y^2) = cos(x*y)"` to a `Relation` |
| `eval.zig` | one evaluator, generic over the arithmetic domain |
| `relation.zig` | `f op 0`, and the two questions the plotter asks about a box |
| `raster.zig` | 1 bit per pixel, byte-aligned rows |
| `png.zig` | indexed 1-bit PNG encoder |
| `plot.zig` | the quadtree, in pixel-index space, run in parallel |

Three decisions carry most of the design:

**Every relation is `f(x, y) op 0`.** For an interval, `[a,b] - [c,d]` contains
zero exactly when `[a,b]` and `[c,d]` overlap, so the difference decides the
relation as precisely as comparing the sides - and the verdict, the definedness
test and the continuity test then all come out of a single evaluation.

**The program is a DAG evaluated by one forward loop.** Operands precede their
parents, so `for (nodes) |n| values[i] = ...` computes each node exactly once and
shares repeated subexpressions for free.

**Boxes are integer pixel rectangles.** Splitting is integer arithmetic and
painting is an exact fill, so cells always line up with pixels regardless of the
image size.

Both the interval and the real domain are SIMD batches, so the plotter decides a
whole quadtree split, or all four corners of a box, in one vector pass. Below
`plot.render` nothing allocates: a plot's only heap traffic is the raster and one
scratch buffer per worker.

## As a Typst plugin

```sh
zig build wasm          # -> typst/implicit_plot.wasm
typst compile typst/manual.typ
```

```typst
#import "plot.typ" as ip
#let f = ip.sub(
  ip.sin(ip.add(ip.pow(ip.x, 2), ip.pow(ip.y, 2))),
  ip.cos(ip.mul(ip.x, ip.y)),
)

#let pixels = ip.plot(f, rel: "eq", size: (8, 8), x: (-1, 1), y: (-1, 1))
#let chains = ip.contour(f, n: 60, x: (-8, 8), y: (-8, 8))
```

Two questions, two answers, and neither is an image:

* **`plot`** asks which pixels the curve may touch and returns **one byte per
  pixel**, row-major from the top - an 8 by 8 plot is a 64-byte array of 0 and
  1. It subdivides adaptively, it is rigorous, and it handles inequalities, so
  it resolves a curve finer than its own pixels and fills regions.
* **`contour`** asks where the curve is and returns **polylines**: arrays of
  `(x, y)`, closed curves repeating their first point, plus a count of cells
  whose topology is not guaranteed. Use it when you need a stroke.

`contour` is the algorithm of
[Plantinga & Vegter, *Isotopic Approximation of Implicit Curves and Surfaces*, SGP 2004](https://pure.rug.nl/ws/files/2952308/2004ProcGeomProcPlantinga.pdf),
not marching squares on a grid. A grid has no way to know it is too coarse:
where the curve turns faster than the spacing it connects samples that are not
consecutive along the curve, and no post-processing detects it. The paper's
stopping rule does know. A cell is finished when the interval enclosure of `F`
over it excludes zero, or when `<grad F, grad F> > 0` over it - the gradient
turns by less than a right angle, so `F` is monotone in x or in y, so the curve
is a single arc there with no loop and no second branch. Under that condition
the output is proved *isotopic* to the true curve.

Both clauses are things this project already had: interval arithmetic for the
first, and `dual.zig` - forward-mode differentiation as another arithmetic
domain, which `eval.Evaluator` runs without a line of change - for the second.

The tree is adaptive in the way that matters: `n` is how finely the curve is
resolved, not a grid walked everywhere. A circle in a large empty view costs one
evaluation per empty cell and comes back as 61 points; empty space is never
refined.

Where it stops short, it says so. `grad F` vanishes at a self-intersection, so
neither clause can ever hold there - the paper assumes zero is a regular value.
Those cells are counted in `uncertain` rather than passed off as correct.
Tracing a *raster* instead would not help and is not a substitute: it follows
the outline of the band of lit pixels, which on a 60 by 60 circle is twelve
staircase fragments where tracing the field gives one loop.

### Wire format

The plugin speaks the
[wasm minimal protocol](https://github.com/typst-community/wasm-minimal-protocol)
and takes a relation as a *postfix opcode stream*: one opcode byte per
instruction, followed by its immediate operand, each instruction pushing one
value. `sin(x^2 + y^2) - cos(x*y)` is

```text
x  powi 2  y  powi 2  add  sin  x  y  mul  cos  sub
```

| opcode | | immediate | stack |
| --- | --- | --- | --- |
| `constant` | 0 | f64, 8 bytes LE | push |
| `x`, `y` | 1, 2 | - | push |
| `neg` .. `atan` | 3 .. 13 | - | pop 1, push 1 |
| `powi` | 14 | i32, 4 bytes LE | pop 1, push 1 |
| `add` .. `div` | 15 .. 18 | - | pop 2, push 1 |

Postfix is not a third representation of an expression - it *is* the node array
of `expr.zig` read out in order, so decoding is a single pass with no tree to
build and the topological invariant holds by construction.

Every call also takes 43 little-endian bytes of options: relation opcode
(`eq` 0, `lt` 1, `le` 2, `gt` 3, `ge` 4), width and height as `u32`, the four
range bounds as `f64`, a depth byte (`plot`: sub-pixel
refinement; `contour`: extra refinement below the requested resolution, default
2), and one final byte only
`contour` reads: the uncertain-cell policy, 0 to keep arcs apart, 1 to contract
each uncertain cluster to a junction. The curve has values in those cells - they
sit on the curve - but the gradient vanishes there, so how the arcs connect is
not computable; the byte is the caller saying which reading their relation
warrants (a factorable relation genuinely crosses; a near miss does not).

`opcodes()` returns the whole table as text, generated from the Zig enums, so
`plot.typ` reads the numbers at import time rather than keeping a copy. Nothing
outside `expr.Tag` and `interval.Op` assigns an operator a number.

## Differences from the JavaScript original

* **Rigorous.** Every rounding operation inflates its result by an ulp, so the
  computed interval really does contain the exact one. `cos` folds the error of
  its argument reduction into the interval instead of trusting a reduction that
  loses all precision for large arguments.
* **`f < 0` is decided false as soon as `lo >= 0`**, not only when `lo > 0`. The
  strict test left any box whose bound landed exactly on the boundary undecided
  forever; `x < 0` over `[-1, 1]` was pathological because of it.
* **`x^2` is a power, not `x * x`.** `[-1,1] * [-1,1]` is `[-1,1]`, but
  `[-1,1]^2` is `[0,1]`, so curves converge in fewer subdivisions.
* **Interval *sets* are gone.** They existed to notice, via their cardinality,
  that a division had crossed a pole. That fact is now a `Decoration` on the
  value - the lattice from IEEE 1788-2015, whose propagation rule is a single
  `min` - the hull is kept instead of the union, which is still a sound
  enclosure, and evaluation no longer allocates.
* **Sub-pixel refinement is depth-limited** rather than cut off at an absolute
  width of `1e-5` that had nothing to do with the plot's scale.
