# Tensors Fitting Perfectly

> "It’s the relief of finding ease where you expected struggle." ~[The Atlantic](https://www.theatlantic.com/health/archive/2015/08/the-existential-satisfaction-of-things-fitting-perfectly-into-other-things/401213/)

There are moments when the planets align and different objects [fit perfectly with each other](https://thingsfittingperfectlyintothings.tumblr.com/).
While this amazing phenomenon has been observed in the physical world [numerous times](https://www.reddit.com/r/Perfectfit/), few people have stopped to think how to make writing numerical programs feel just as good.
We have, and this is how Tensors Fitting Perfectly got started.

_TFP is a static analyzer for Swift programs that tries to detect tensor shape mismatches before you even attempt to run them._ Note that TFP is not a type system, meaning that it does not try to prove that your program is correct. It only tries to prove that your program _is incorrect_, and will report errors only if it's sure that shape errors are guaranteed to occur.

**This project is highly experimental and may unexpectedly change at any time**.

## How does it work?

Good question!
TFP will invoke the Swift compiler to lower your Swift code down to [SIL](https://github.com/apple/swift/blob/master/docs/SIL.rst) (Swift intermediate representation), and will use it to scan your code for `assert`ions that pertain to shapes of tensors.
Note that this step is a form of abstract interpretation, and is not guaranteed to actually recover all of those --- it is very much an approximation.
Each one that it manages to understand gets added to a system of logical constraints that have to be satisfied if your program is to be correct.
Note that those constraints will be propagated through e.g. function calls, so invariants discovered in called functions will be considered invariants of their caller too.
Then, it will carefully query an [SMT solver](https://en.wikipedia.org/wiki/Satisfiability_modulo_theories) to verify whether the program looks correct, or whether there is an execution path that causes a shape failure.

The general idea is that the standard library should contain a number of assertions that both establish the shape semantics of the code, as well as verify some of the preconditions that need to be satisfied. Take matrix multiplication as an example:

```swift
func matmul(_ x: Tensor<Float>, _ y: Tensor<Float>) -> Tensor<Float> {
  let (n, mx) = x.shape2d
  let (my, k) = y.shape2d
  assert(mx == my)
  let r = TensorFlow.matmul(x, y)
  assert(r.shape == [n, k])
  return r
}
```

Once you use `matmul` (and similar library functions) in your program, TFP will be able to recover the relations that connect shapes of tensor values at different points and will try to verify them.
Adding more assertions to your code (at a level higher than libraries) is beneficial, because:
1. It will let TFP verify that what you believe is consistent with what the lower layer has specified in the form of assertions.
2. Improve the quality of verification in case parts of the program could not be understood.

**tl;dr** Instead of encoding your shape contracts in comments or `print`ing shapes to figure out what's happening, encode your thoughts and beliefs as `assert`ions. Those have the benefit of being a machine-checked documentation (in debug mode only!), and (more importantly in this context) they will also make it more likely for the tool to find issues in your programs.

## Notable limitations

Most of those will be lifted at some point in the future, but they will require extra work.

- Currently only the `Tensor` type from the `TensorFlow` module is recognized as a multidimensional array.
- Limited to a single file only (in particular there's no support for verification accross modules).

## Recognized constraints

Here are a few examples of expressions that you could `assert` and have them be recognized by TFP.

```swift
x.rank == 2
x.rank == y.rank
x.shape == y.shape
x.shape[0] == y.shape[1]
x.shape[0] == 5
x.shape[0] == (y.shape[1] - z.shape[2] + 1) / 2
x.shape == [y.shape[0], 4]
```

Note that it's not the case that a full expression has to appear within the `assert` call. Those three `assert`s are actually equivalent from the point of view of TFP:

```swift
// 1.
assert(x.shape[0] == y.shape[1] + 2)

// 2.
let newShape = y.shape[1] + 2
assert(x.shape[0] == newShape)

// 3.
func getNewShape<T>(_ y: Tensor<T>) -> Int {
    return y.shape[1] + 2
}
let cond = x.shape[0] == getNewShape(y)
assert(cond)
```

#### (Semi-)Formal grammar of supported expressions

```
ShapeExpr ::= <variable>
            | [IntExpr, ..., IntExpr]
            // This is supported, but requires some hacky workarounds for now.
            | broadcast(ShapeExpr, ShapeExpr)

IntExpr   ::= <variable>
            | <literal>
            | ShapeExpr.rank
            | ShapeExpr[<constant>]
            | IntExpr + IntExpr
            | IntExpr - IntExpr
            | IntExpr * IntExpr
            | IntExpr / IntExpr

BoolExpr  ::= true
            | false
            | <variable>
            | IntExpr == IntExpr
            | IntExpr > IntExpr
            | IntExpr >= IntExpr
            | IntExpr < IntExpr
            | IntExpr <= IntExpr
            | ShapeExpr == ShapeExpr
```

## How to use

Note that the tool requires you to install the Z3 SMT solver before you try to run it.
It can be obtained from `brew` (as `z3`) or from `apt` (`libz3-dev`).

To analyze a file `example.swift` execute `swift run doesitfit example.swift`.
You can find some examples to play with in the `Examples/` directory.

We understand if you don't feel like doing it just yet, so we'll also walk you through a basic case.
Assume that `example.swift` contains the following:
```swift
import TensorFlow

func randn(_ shape: TensorShape) -> Tensor<Float> {
  let result = Tensor<Float>(randomNormal: shape)
  assert(result.shape == shape)
  return result
}

func matmul(_ x: Tensor<Float>, _ y: Tensor<Float>) -> Tensor<Float> {
  assert(x.rank == 2)
  assert(y.rank == 2)
  assert(x.shape[1] == y.shape[0])
  let r = TensorFlow.matmul(x, y)
	assert(r.shape == [x.shape[0], y.shape[1]])
  return r
}

func f() -> Tensor<Float> {
  let x = randn([2, 3])
  return matmul(x, x)
}
```

the output you'll see will be similar to this:
```
In $s4main1f10TensorFlow0B0VySfGyF:
❌ Something doesn't fit!
  - 3 = 2
      Asserted at small.swift:12
            |   assert(y.rank == 2)
         12 |   assert(x.shape[1] == y.shape[0])
            |   let r = TensorFlow.matmul(x, y)
```

Each line starting with "$s" is actually a mangled name of a Swift function in your module, so e.g. `$s4main1f10TensorFlow0B0VySfGyF` really means `main.f() -> TensorFlow.Tensor<Swift.Float>`.
In the future those will get demangled before we display them, but for now you can try piping the output through `swift-demangle` (if you have it installed).
What follows is a message which either tells you that TFP doesn't see any issue (assuming that this function would get executed), or a list of assertions that shows that any attempt to execute it will cause a shape mismatch.

If the assert is actually in a function invoked from the analyzed one, it might be helpful to use the `--stacks` flag to see where the assert originates from.
If you want a very detailed view you can try adding a `--signatures` flag to the invocation, but they will usually get extremely verbose and hard to read, even in very simply examples.
