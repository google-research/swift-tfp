@testable import LibShapeChecker
import XCTest
import SIL

let transposeCode = """

@_silgen_name("transpose") @inline(never)
func transpose(_ x: Tensor<Float>) -> Tensor<Float> {
  check(x.rank == 2)
  let r = x.transposed()
  check(r.rank == 2)
  check(r.shape[0] == x.shape[1])
  check(r.shape[1] == x.shape[0])
  return r
}

"""

let matmulCode = """

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

"""

extension XCTestCase {
  func getFunction(called name: String, _ module: Module) -> Function? {
    guard let f = module.functions.first(where: { $0.name == name }) else {
      XCTFail("Couldn't find a function called \(name)")
      return nil
    }
    return f
  }

  func getOnlyBlock(_ function: Function) -> Block? {
    if function.blocks.count == 1 {
      return function.blocks[0]
    } else {
      XCTFail("Expected function to have a single block!")
      return nil
    }
  }

  func getOnlyBlock(fromFunctionCalled name: String, _ module: Module) -> Block? {
    guard let f = getFunction(called: name, module) else { return nil }
    return getOnlyBlock(f)
  }
}

func assertUnsat(_ result: SolverResult) {
  guard case .unsat(_) = result else {
    return XCTFail("Expected unsat, got: \(result)!")
  }
}
