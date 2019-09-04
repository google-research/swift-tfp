# ShapeChecker

Static analysis for tensor shapes in S4TF programs

## (Temporary) Restrictions

- Limited to a single file only
- Only analyzes functions with a single basic block

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
x.shape == broadcast(y.shape, z.shape) *
```

The full grammar can be found in `Sources/LibShapeChecker/Constraint.swift`.

_* The use of broadcasting requires one to define a custom `broadcast` function_
**TODO: Show how to do this**

## How to use

To analyze a file `example.swift` execute `swift run ShapeChecker example.swift`.

For example, if `example.swift` contains the following:
```swift
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
  assert(r.rank == 2)
  assert(r.shape[0] == x.shape[0])
  assert(r.shape[1] == y.shape[1])
  return r
}

func verify() -> Tensor<Float> {
  let x = randn([2, 3])
  return matmul(x, x)
}
```

you should see an output similar to this:
```
$s4main5randny10TensorFlow0C0VySfGAC0C5ShapeVF
✅ Constraints are satisfiable!

$s4main5randny10TensorFlow0C0VySfGAC0C5ShapeVFSbyXEfu_
✅ Constraints are satisfiable!

$s4main6matmuly10TensorFlow0C0VySfGAF_AFtF
✅ Constraints are satisfiable!

$s4main6matmuly10TensorFlow0C0VySfGAF_AFtFSbyXEfu0_
✅ Constraints are satisfiable!

$s4main6matmuly10TensorFlow0C0VySfGAF_AFtFSbyXEfu1_
✅ Constraints are satisfiable!

$s4main6matmuly10TensorFlow0C0VySfGAF_AFtFSbyXEfu2_
✅ Constraints are satisfiable!

$s4main6matmuly10TensorFlow0C0VySfGAF_AFtFSbyXEfu3_
✅ Constraints are satisfiable!

$s4main6matmuly10TensorFlow0C0VySfGAF_AFtFSbyXEfu4_
✅ Constraints are satisfiable!

$s4main6matmuly10TensorFlow0C0VySfGAF_AFtFSbyXEfu_
✅ Constraints are satisfiable!

$s4main6verify10TensorFlow0C0VySfGyF
❌ Derived a contradiction from:
  - s4 = [2, 3]
  - s4.shape[1] = s4.shape[0]
```

What you see here is that the tool has found a contradiction in the shape equations.
Each entry corresponds to a top-level function (note that Swift generates a few of those on its own) and unfortunately for now their names are displayed as mangled Swift symbols.
The output can be improved by piping it through `swift-demangle` (e.g. that changes `$s4main6verify10TensorFlow0C0VySfGyF` to `main.verify() -> TensorFlow.Tensor<Swift.Float>`).

If you want a very detailed view you can try adding a `--signatures` flag to the invocation, but they will usually get extremely verbose and hard to read, even in examples as simple as this one.
