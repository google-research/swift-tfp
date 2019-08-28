# ShapeChecker

Static analysis for tensor shapes in S4TF programs

## (Temporary) Restrictions

- Limited to a single file only
- Only analyzes functions with a single basic block
- The use of `assert` statements would violate the "single basic block" rule, so for now, please paste the following code into your file (can be at the very bottom), and use `check` instead:

```swift
@_silgen_name("check") @inline(never)
func check(_ cond: Bool) { if !cond { fatalError() } }
```

## Recognized constraints

Here are a few examples:
```swift
x.rank == 2
x.rank == y.rank
x.shape == y.shape
x.shape[0] == y.shape[1]
x.shape[0] == 5
x.shape[0] == (y.shape[1] - z.shape[2] + 1) / 2
x.shape == [y.shape[0], 4]
```

_TODO: Write down the exact grammar_

## How to use

To analyze a file `example.swift` execute `swift run ShapeChecker example.swift`.
Don't forget to define `check` as mentioned in the _Restrictions_ section.

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
[s0.rank == 2,
 s1.rank == 2,
 s0.rank > 1,
 s1.rank > 0,
 s0.shape[1] == s1.shape[0],
 $s10TensorFlow6matmul_10transposed_AcA0A0VyxGAF_SbAFSbtSjRzAA0aB6ScalarRzlFfA0_(),
 $s10TensorFlow6matmul_10transposed_AcA0A0VyxGAF_SbAFSbtSjRzAA0aB6ScalarRzlFfA2_(),
 s2 = $s10TensorFlow6matmul_10transposed_AcA0A0VyxGAF_SbAFSbtSjRzAA0aB6ScalarRzlF(s0, *, s1, *),
 s2.rank == 2,
 s2.rank > 0,
 s0.rank > 0,
 s2.shape[0] == s0.shape[0],
 s2.rank > 1,
 s1.rank > 1,
 s2.shape[1] == s1.shape[1]] => (s0, s1) -> s2
✅ Constraints are satisfiable!

transpose
[s0.rank == 2,
 s1 = $s10TensorFlow0A0V10transposedACyxGyF(s0),
 s1.rank == 2,
 s1.rank > 0,
 s0.rank > 1,
 s1.shape[0] == s0.shape[1],
 s1.rank > 1,
 s0.rank > 0,
 s1.shape[1] == s0.shape[0]] => (s0) -> s1
✅ Constraints are satisfiable!

verify
[s0.rank > 0,
 s0.shape[0] == 2,
 s0.rank > 1,
 s0.shape[1] == 3,
 s1 = matmul(s0, s0),
 s2 = transpose(s1)] => (s0) -> s2
❌ Found a contradiction!
```

What you see here is a shape signature of the matmul function.
The first part of the output is a list of shape constraints that are necessary for its correctness, and the `(s1, s2) -> s3` part describes that the variables `s1` and `s2` correspond to the shapes of two arguments, while `s3` corresponds to the output shape.
