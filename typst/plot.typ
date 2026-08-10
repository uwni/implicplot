// Implicit relation plotting for Typst, backed by the Zig plugin.
//
// The plugin takes a relation as a postfix stream of opcodes and returns one
// byte per pixel, row-major from the top: an 8 by 8 plot is 64 bytes of 0 or 1.
// What to draw with that is the document's business.
//
//   #import "plot.typ" as ip
//   #let f = ip.sub(
//     ip.sin(ip.add(ip.pow(ip.x, 2), ip.pow(ip.y, 2))),
//     ip.cos(ip.mul(ip.x, ip.y)),
//   )
//   #let pixels = ip.plot(f, rel: "eq", size: (64, 64), x: (-6, 6), y: (-6, 6))
//
// Import it namespaced, as above: this module exports `x`, `y`, `sin`, `cos`
// and friends, and a glob import would shadow those names inside math mode.
//
// Doc comments follow the conventions of the `tidy` package; the API reference
// in manual.typ is generated from them.

#let _plugin = plugin("./implicit_plot.wasm")

// The opcode numbers are read from the plugin rather than written here, so
// there is exactly one place in the whole project where an operator gets a
// number, and it is the Zig enum.
#let _table = {
  let ops = (:)
  let rels = (:)
  for line in str(_plugin.opcodes()).split("\n") {
    let f = line.split(" ")
    if f.len() == 5 and f.at(0) == "op" {
      ops.insert(f.at(1), (code: int(f.at(2)), arity: int(f.at(3)), immediate: int(f.at(4))))
    } else if f.len() == 3 and f.at(0) == "rel" {
      rels.insert(f.at(1), int(f.at(2)))
    }
  }
  (ops: ops, rels: rels)
}

/// The relation names @plot accepts, read from the plugin itself.
/// -> array
#let relations = _table.rels.keys()

// -- encoding -----------------------------------------------------------------

// IEEE-754 binary64, little-endian, as eight integers.
//
// Note `cbor.encode` is *not* an alternative here: it emits the shortest
// lossless form, so a float comes back as two, four or eight bytes depending on
// its value.
#let _f64-bytes(value) = {
  let v = float(value)
  // False for NaN as well as for the infinities, so one test covers both.
  assert(calc.abs(v) < 1.7976931348623157e308, message: "a constant must be finite, got " + repr(v))
  array(float.to-bytes(v, endian: "little"))
}

#let _int-bytes(v, size) = array(int.to-bytes(int(v), endian: "little", size: size))

// The 43-byte options header. Both plugin calls take the same one, so it is
// built in one place rather than once per entry point. The final byte is
// `contour`'s uncertain-cell policy; `plot` ignores it.
#let _options(rel, width, height, x, y, depth, join) = {
  assert(width > 0 and height > 0, message: "the grid must be at least 1 by 1")
  assert(x.at(0) < x.at(1), message: "the x range must be increasing")
  assert(y.at(0) < y.at(1), message: "the y range must be increasing")
  let out = (rel,)
  out += _int-bytes(width, 4)
  out += _int-bytes(height, 4)
  out += _f64-bytes(x.at(0))
  out += _f64-bytes(x.at(1))
  out += _f64-bytes(y.at(0))
  out += _f64-bytes(y.at(1))
  out.push(depth)
  out.push(join)
  bytes(out)
}

// Postfix: operands first, then the opcode and its immediate. That order is
// also the order the plugin stores nodes in, so decoding is a single pass.
#let _emit(node) = {
  assert(
    type(node) == dictionary and "op" in node,
    message: "expected an expression, got " + repr(node),
  )
  let info = _table.ops.at(node.op, default: none)
  assert(info != none, message: "unknown operator: " + node.op)
  assert(
    node.args.len() == info.arity,
    message: node.op + " takes " + str(info.arity) + " operands, got " + str(node.args.len()),
  )

  let out = ()
  for argument in node.args { out += _emit(argument) }
  out.push(info.code)
  if node.op == "constant" { out += _f64-bytes(node.value) }
  if node.op == "powi" { out += _int-bytes(node.exponent, 4) }
  out
}

// -- building expressions -----------------------------------------------------

/// The variable $x$, as an expression leaf.
/// -> dictionary
#let x = (op: "x", args: ())

/// The variable $y$, as an expression leaf.
/// -> dictionary
#let y = (op: "y", args: ())

/// A numeric literal, as an expression leaf.
/// -> dictionary
#let num(
  /// The value; anything `float` accepts.
  /// -> int | float
  value,
) = (op: "constant", args: (), value: float(value))

/// `base` raised to an integer power.
///
/// A power is not repeated multiplication here: the plotter encloses
/// $[-1,1]^2$ as $[0,1]$, where $[-1,1] dot [-1,1]$ can only manage $[-1,1]$,
/// so `pow(x, 2)` converges in fewer subdivisions than `mul(x, x)`.
/// -> dictionary
#let pow(
  /// The expression to raise.
  /// -> dictionary
  base,
  /// The exponent. May be negative; `pow(e, -1)` is `1/e`.
  /// -> int
  exponent,
) = (op: "powi", args: (base,), exponent: int(exponent))

#let _unary(name) = a => (op: name, args: (a,))
#let _binary(name) = (a, b) => (op: name, args: (a, b))

/// `neg(e)`: the negation $-e$. -> function
#let neg = _unary("neg")
/// `abs(e)`: the absolute value $|e|$. -> function
#let abs = _unary("abs")
/// `sin(e)`: the sine of an expression. -> function
#let sin = _unary("sin")
/// `cos(e)`: the cosine of an expression. -> function
#let cos = _unary("cos")
/// `tan(e)`: the tangent of an expression. Poles are handled honestly:
/// @contour refuses to trace across them. -> function
#let tan = _unary("tan")
/// `exp(e)`: the natural exponential $e^e$. -> function
#let exp = _unary("exp")
/// `sqrt(e)`: the square root, undefined for negative arguments. -> function
#let sqrt = _unary("sqrt")
/// `log(e)`: the natural logarithm, undefined for non-positive arguments.
/// -> function
#let log = _unary("log")
/// `asin(e)`: the inverse sine, defined on $[-1, 1]$. -> function
#let asin = _unary("asin")
/// `acos(e)`: the inverse cosine, defined on $[-1, 1]$. -> function
#let acos = _unary("acos")
/// `atan(e)`: the inverse tangent. -> function
#let atan = _unary("atan")

/// `add(a, b)`: the sum $a + b$. -> function
#let add = _binary("add")
/// `sub(a, b)`: the difference $a - b$. A relation $a = b$ is written
/// `sub(a, b)` with `rel: "eq"`. -> function
#let sub = _binary("sub")
/// `mul(a, b)`: the product $a dot b$. -> function
#let mul = _binary("mul")
/// `div(a, b)`: the quotient $a / b$. Division by an interval containing zero
/// is handled soundly; the pole is never painted or traced through.
/// -> function
#let div = _binary("div")

// The opcode *numbers* live only in the Zig enum, but the names above are
// written twice - once as constructors and once in the plugin. Checking the two
// sets against each other at import time turns that from a coupling into an
// error message: adding an operator in Zig and forgetting it here says so.
#let _constructors = (
  "constant", "x", "y", "powi",
  "neg", "abs", "sin", "cos", "tan", "exp", "sqrt", "log", "asin", "acos", "atan",
  "add", "sub", "mul", "div",
)
#{
  for name in _table.ops.keys() {
    assert(name in _constructors, message: "plot.typ has no constructor for the plugin's `" + name + "`")
  }
  for name in _constructors {
    assert(name in _table.ops, message: "plot.typ defines `" + name + "`, which the plugin does not have")
  }
}

// -- plotting -----------------------------------------------------------------

/// Plot the region satisfying `relation rel 0` and return one byte per pixel,
/// row-major from the top - not an image; the document decides what to draw.
///
/// The plotter subdivides adaptively with interval arithmetic, so a lit pixel
/// means the relation provably or plausibly holds there and an unlit pixel
/// means it provably does not: coverage errs outward, never inward.
///
/// ```example
/// #raw(rows(plot(x, rel: "lt", size: (6, 6), x: (-1, 1), y: (-1, 1)), 6)
///   .map(row => row.map(str).join(" ")).join("\n"))
/// ```
/// -> bytes
#let plot(
  /// The left-hand side $f$ of the relation $f space.thin op space.thin 0$,
  /// built from @x, @y, @num and the operator constructors. A relation
  /// $a = b$ is written `sub(a, b)`.
  /// -> dictionary
  relation,
  /// The comparison against zero: one of @relations.
  /// -> str
  rel: "eq",
  /// Width and height in pixels.
  /// -> array
  size: (64, 64),
  /// The horizontal extent of the plane to cover.
  /// -> array
  x: (-10, 10),
  /// The vertical extent of the plane to cover.
  /// -> array
  y: (-10, 10),
  /// How many times a single undecided pixel may be subdivided before giving
  /// up on proving it.
  /// -> int
  depth: 8,
) = {
  let code = _table.rels.at(rel, default: none)
  assert(code != none, message: "unknown relation: " + rel + ", expected one of " + repr(_table.rels.keys()))

  _plugin.plot(
    bytes(_emit(relation)),
    _options(code, size.at(0), size.at(1), x, y, depth, 0),
  )
}

/// Split a flat plot into rows, top first.
/// -> array
#let rows(
  /// The result of @plot (or any flat sequence).
  /// -> bytes | array
  pixels,
  /// The row width, i.e. the first element of the `size` the plot was made at.
  /// -> int
  width,
) = {
  let all = array(pixels)
  range(0, calc.div-euclid(all.len(), width)).map(r => all.slice(r * width, (r + 1) * width))
}

/// Trace the curve `relation = 0` as polylines, by subdivision with a
/// guaranteed topology (Plantinga & Vegter, SGP 2004; Lin & Yap, DCG 2011).
///
/// Returns a dictionary `(chains, uncertain)`. Each chain is an array of
/// $(x, y)$ pairs in the relation's own coordinates; closed curves repeat
/// their first point, so a chain can be stroked without special-casing.
///
/// `uncertain` counts cells where the curve is singular - a self-intersection,
/// where the gradient vanishes and no subdivision can settle the topology.
/// Zero means the shape is guaranteed correct, not merely plausible.
///
/// @plot answers a different question - which pixels the curve may touch - and
/// tracing that raster is not a substitute: it follows the outline of the band
/// of lit pixels, giving staircase fragments where this gives one path.
///
/// ```example
/// #let c = contour(sub(add(pow(x, 2), pow(y, 2)), num(1)),
///   n: 24, x: (-1.5, 1.5), y: (-1.5, 1.5))
/// The unit circle: #c.chains.len() chain of #c.chains.at(0).len() points,
/// #c.uncertain uncertain cells.
/// ```
/// -> dictionary
#let contour(
  /// The $f$ whose zero set is the curve, built from @x, @y, @num and the
  /// operator constructors. A curve $a = b$ is written `sub(a, b)`.
  /// -> dictionary
  relation,
  /// How finely to resolve the curve. The tree is adaptive: this is the
  /// resolution the curve is resolved *to*, not a grid walked everywhere -
  /// empty regions cost one evaluation each.
  /// -> int
  n: 60,
  /// The horizontal extent of the plane to trace.
  /// -> array
  x: (-10, 10),
  /// The vertical extent of the plane to trace.
  /// -> array
  y: (-10, 10),
  /// How far below `n`'s resolution an unresolved cell may be split before it
  /// is given up as `uncertain`. Each level costs about four times the last,
  /// for shrinking returns: a genuine singularity never resolves however deep
  /// this goes, so raising it mainly tightens the region around singular
  /// points and resolves features finer than `n`.
  /// -> int
  refine: 2,
  /// What to draw inside the cells counted by `uncertain`. The curve has
  /// values there; what cannot be computed is how the arcs connect, so the
  /// choice is the caller's. `"avoid"` keeps the arcs apart - right when a
  /// "crossing" is a near miss. `"join"` contracts each cluster of uncertain
  /// cells to a single junction, giving a true X - right whenever the
  /// relation visibly factors, as `sin(x^2+y^2) = cos(x*y)` does into two
  /// ellipse families.
  /// -> str
  uncertain: "avoid",
) = {
  assert(type(n) == int, message: "n must be an integer")
  assert(type(refine) == int and refine >= 0 and refine <= 10, message: "refine must be 0..10")
  assert(uncertain in ("avoid", "join"), message: "uncertain must be \"avoid\" or \"join\"")

  // The comparison operator is not consulted when tracing; only `f` is.
  let raw = _plugin.contour(
    bytes(_emit(relation)),
    _options(_table.rels.eq, n, n, x, y, refine, if uncertain == "join" { 1 } else { 0 }),
  )
  let count = int.from-bytes(raw.slice(0, 4), endian: "little", signed: false)
  let uncertain = int.from-bytes(raw.slice(4, 8), endian: "little", signed: false)
  let lengths = range(count).map(k => int.from-bytes(
    raw.slice(8 + k * 4, 12 + k * 4),
    endian: "little",
    signed: false,
  ))

  let base = 8 + count * 4
  let point(k) = (
    float.from-bytes(raw.slice(base + k * 16, base + k * 16 + 8), endian: "little"),
    float.from-bytes(raw.slice(base + k * 16 + 8, base + k * 16 + 16), endian: "little"),
  )

  let chains = ()
  let at = 0
  for length in lengths {
    chains.push(range(at, at + length).map(point))
    at += length
  }
  (chains: chains, uncertain: uncertain)
}
