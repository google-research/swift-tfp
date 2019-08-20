# ShapeChecker

Static analysis for tensor shapes in S4TF programs

## (Temporary) Restrictions

- Limited to a single file only
- Only analyzes functions with a single basic block
- Constraints are only propagated through function calls when the callee is defined before the caller
- The use of `assert` statements would violate the "single basic block" rule, so for now, please paste the following code into your file (can be at the very bottom), and use `check` instead:

```swift
@_silgen_name("check") @inline(never)
func check(_ cond: Bool) { if !cond { fatalError() } }
```

## Recognized constraints

```swift
x.rank == 2
// NB: No x.rank == y.rank yet. It's a TODO
x.shape == y.shape
x.shape[0] == y.shape[1]
x.shape[0] == 5
// NB: No x.shape == [y.shape[0], 4] yet because it's a bit hard
//     to do in the frontend (array literals are filled through pointers).
```

## How to use

The tool is not super user-friendly at the moment, so there are a few manual steps you will have to perform.
I'm assuming that you have a file `example.swift` that you want to analyze.

1. Make sure you defined `check` as told in the _Restrictions_ section.
2. Run `swiftc -emit-sil -o example.sil example.swift`
3. Run `swift run ShapeChecker example.sil`

For example, if `example.swift` contains the following:
```swift
@_silgen_name("matmul") @inline(never)
func matmul(_ x: Tensor<Float>, _ y: Tensor<Float>) -> Tensor<Float> {
  check(x.rank == 2)
  check(y.rank == 2)
  check(x.shape[1] == y.shape[0])
  let r = TensorFlow.matmul(x, y)
  check(r.rank == 2)
  check(r.shape[0] == x.shape[0])
  check(r.shape[1] == y.shape[1])
  return r
}

@_silgen_name("transpose") @inline(never)
func transpose(_ x: Tensor<Float>) -> Tensor<Float> {
  check(x.rank == 2)
  let r = x.transposed()
  check(r.rank == 2)
  check(r.shape[0] == x.shape[1])
  check(r.shape[1] == x.shape[0])
  return r
}

@_silgen_name("verify")
func verify(x : Tensor<Float>) -> Tensor<Float> {
  check(x.shape[0] == 2)
  check(x.shape[1] == 3)
  let a = matmul(x, x)
  return transpose(a)
}

@_silgen_name("check") @inline(never)
func check(_ cond: Bool) { if !cond { fatalError() } }
```

you should see an output similar to this:
```
...

matmul
[s1 = [d1, d2],
 s2 = [d3, d4],
 d2 = d3,
 s3 = [d5, d6],
 d5 = d1,
 d6 = d4] => (s1, s2) -> s3
Constraint check passed!

transpose
[s1 = [d1, d2], s2 = [d3, d4], d3 = d2, d4 = d1] => (s1) -> s2
Constraint check passed!

verify
[s1[0] = d1,
 d1 = 2,
 s1[1] = d2,
 d2 = 3,
 s1 = [d3, d4],
 s1 = [d5, d6],
 d4 = d5,
 s2 = [d7, d8],
 d7 = d3,
 d8 = d6,
 s2 = [d9, d10],
 s3 = [d11, d12],
 d11 = d10,
 d12 = d9] => (s1) -> s3
Found a shape error: dimensionSizeMismatch(prev: 3, now: 2)
```

What you see here is a shape signature of the matmul function.
The first part of the output is a list of shape constraints that are necessary for its correctness, and the `(s1, s2) -> s3` part describes that the variables `s1` and `s2` correspond to the shapes of two arguments, while `s3` corresponds to the output shape.

> Tip: All shape variables have an `s` prefix, and all dimension variables have the `d` prefix.
