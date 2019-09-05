import TensorFlow

////////////////////////////////////////////////////////////////////////////////
// Broadcasting
////////////////////////////////////////////////////////////////////////////////

// NB: _silgen_name is important to get this function recognized as a builtin
@_silgen_name("broadcast")
func broadcast(_ ar: TensorShape, _ br: TensorShape) -> TensorShape {
  var a = ar
  var b = br
  if a.count < b.count {
    swap(&a, &b)
  }
  var result: [Int] = []
  for (ai, bi) in zip(a.dimensions, b.dimensions) {
    assert(ai == bi)
    result.append(ai)
  }
  result += a.dimensions[b.count...]
  return TensorShape(result)
}

////////////////////////////////////////////////////////////////////////////////
// Utilities
////////////////////////////////////////////////////////////////////////////////

// Analysis through computed properties is supported, and those allow
// us to make the shape checks below much more succint.
extension Tensor {
  var shape1d: Int {
    assert(rank == 1)
    return (shape[0])
  }

  var shape2d: (Int, Int) {
    assert(rank == 2)
    return (shape[0], shape[1])
  }

  var shape4d: (Int, Int, Int, Int) {
    assert(rank == 4)
    return (shape[0], shape[1], shape[2], shape[3])
  }
}

////////////////////////////////////////////////////////////////////////////////
// Operators
//
// We cannot really override the builtin operators, so we define checked
// versions that contain the assertions
////////////////////////////////////////////////////////////////////////////////

infix operator .+: AdditionPrecedence

func .+<T: Numeric>(_ a: Tensor<T>, _ b: Tensor<T>) -> Tensor<T> {
  let r = a + b
  assert(r.shape == broadcast(a.shape, b.shape))
  return r
}

////////////////////////////////////////////////////////////////////////////////
// Tensor factories
////////////////////////////////////////////////////////////////////////////////

func randn(_ shape: TensorShape) -> Tensor<Float> {
  let result = Tensor<Float>(randomNormal: shape)
  assert(result.shape == shape)
  return result
}

////////////////////////////////////////////////////////////////////////////////
// Operators
////////////////////////////////////////////////////////////////////////////////

func validWindowShape(_ input: Tensor<Float>, kernelSize: (Int, Int), stride: (Int, Int), outputs: Int) -> TensorShape {
  let (iN, iH, iW, _) = input.shape4d
  return [iN, (iH - kernelSize.0) / stride.0 + 1, (iW - kernelSize.1) / stride.1 + 1, outputs]
}

func conv2d(_ input: Tensor<Float>, _ weight: Tensor<Float>, _ bias: Tensor<Float>, stride: (Int, Int) = (1, 1)) -> Tensor<Float> {
  // input: [N, H, W, C], weight: [kH, kW, iF, oF]
  let (_, iH, iW, iC) = input.shape4d
  let (kH, kW, iF, oF) = weight.shape4d
  let bF = bias.shape1d
  assert(bF == oF)
  assert(iC == iF)
  assert(iH >= kH)
  assert(iW >= kW)
  let cresult = TensorFlow.conv2D(input, filter: weight, strides: (1, 1, 1, 1), padding: .valid, dilations: (1, 1, 1, 1))
  let result = cresult + bias.reshaped(to: [1, bF, 1, 1])
  assert(result.shape == validWindowShape(input, kernelSize: (kH, kW), stride: stride, outputs: oF))
  return result
}

func max_pool2d(_ input: Tensor<Float>, kernelSize: (Int, Int), stride: (Int, Int)) -> Tensor<Float> {
  let result = TensorFlow.maxPool2D(input,
                                    filterSize: (1, kernelSize.0, kernelSize.1, 1),
                                    strides: (1, stride.0, stride.1, 1),
                                    padding: .valid)
  assert(result.shape == validWindowShape(input, kernelSize: kernelSize, stride: stride, outputs: input.shape[3]))
  return result
}

func reshape(_ x: Tensor<Float>, _ s: TensorShape) -> Tensor<Float> {
  let r = x.reshaped(to: s)
  assert(r.shape == s)
  return r
}

func matmul(_ x: Tensor<Float>, _ y: Tensor<Float>) -> Tensor<Float> {
  let (n, mx) = x.shape2d
  let (my, k) = y.shape2d
  assert(mx == my)
  let r = TensorFlow.matmul(x, y)
  assert(r.shape == [n, k])
  return r
}

func relu(_ x: Tensor<Float>) -> Tensor<Float> {
  let r = TensorFlow.relu(x)
  assert(r.shape == x.shape)
  return r
}

func dropout(_ input: Tensor<Float>, _ p: Double) -> Tensor<Float> {
  let result = input + 0
  assert(result.shape == input.shape)
  return result
}

func dense(_ input: Tensor<Float>, _ weight: Tensor<Float>, _ bias: Tensor<Float>) -> Tensor<Float> {
  return matmul(input, weight) .+ bias
}

////////////////////////////////////////////////////////////////////////////////
// Parameter constructors
////////////////////////////////////////////////////////////////////////////////

func conv2dInit(inputs: Int, outputs: Int, kernelSize: (Int, Int)) -> (Tensor<Float>, Tensor<Float>) {
  return (randn([kernelSize.0, kernelSize.1, inputs, outputs]), randn([outputs]))
}

func denseInit(inputs: Int, outputs: Int) -> (Tensor<Float>, Tensor<Float>) {
  return (randn([inputs, outputs]), randn([outputs]))
}

////////////////////////////////////////////////////////////////////////////////
// Model implementation
////////////////////////////////////////////////////////////////////////////////

func model(_ input: Tensor<Float>,
           _ w1: Tensor<Float>, _ b1: Tensor<Float>,
           _ w2: Tensor<Float>, _ b2: Tensor<Float>,
           _ wd1: Tensor<Float>, _ bd1: Tensor<Float>,
           _ wd2: Tensor<Float>, _ bd2: Tensor<Float>) -> Tensor<Float> {
  let c1 = relu(conv2d(input, w1, b1))
  let p1 = max_pool2d(c1, kernelSize: (2, 2), stride: (2, 2))
  let c2 = relu(conv2d(p1, w2, b2))
  let p2 = max_pool2d(c2, kernelSize: (2, 2), stride: (2, 2))
  let d0 = reshape(p2, [p2.shape[0], p2.shape[1] * p2.shape[2] * p2.shape[3]])
  let d1 = dropout(dense(d0, wd1, bd1), 0.4)
  let d2 = dense(d1, wd2, bd2)
  return d2
}

// TODO: Make this into a proper training loop
func main(_ input: Tensor<Float>) -> Tensor<Float> {
  let (_, iH, iW, iC) = input.shape4d
  assert(iC == 1)
  assert(iH == 28)
  assert(iW == 28)

  let (w1, b1) = conv2dInit(inputs: 1, outputs: 32, kernelSize: (5, 5))
  let (w2, b2) = conv2dInit(inputs: 32, outputs: 64, kernelSize: (5, 5))
  let (wd1, bd1) = denseInit(inputs: 1024, outputs: 1024)
  let (wd2, bd2) = denseInit(inputs: 1024, outputs: 10)

  return model(input,
               w1, b1,
               w2, b2,
               wd1, bd1,
               wd2, bd2)
}
