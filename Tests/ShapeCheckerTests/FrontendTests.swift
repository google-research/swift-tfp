@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class FrontendTests: XCTestCase {

  func testFrontendConstraints() {
    withSIL(forSource: transposeCode) { module in
      guard let block = getOnlyBlock(fromFunctionCalled: "transpose", module) else { return }
      guard let summary = abstract(block) else {
          return XCTFail("Failed to abstract a block")
      }
      let constraints = summary.constraints
      guard constraints.count == 9 else {
        return XCTFail("Expected to find exactly 5 constraints")
      }
      guard case .expr(.intEq(.length(of: _), .literal(2))) = constraints[0] else {
        return XCTFail("First constraint looks incorrect: \(constraints[0])")
      }
      guard case let .call(methodName, _, _) = constraints[1] else {
        return XCTFail("Second constraint should be an apply constraint: \(constraints[1])")
      }
      guard methodName.contains("transposed") else {
        return XCTFail("Called method should contain 'transposed' within its name")
      }
      guard case .expr(.intEq(.length(of: _), .literal(2))) = constraints[2] else {
        return XCTFail("Third constraint looks incorrect: \(constraints[2])")
      }
      guard case .expr(.intGt(.length(of: _), .literal(0))) = constraints[3] else {
        return XCTFail("Fourth constraint looks incorrect: \(constraints[3])")
      }
      guard case .expr(.intGt(.length(of: _), .literal(1))) = constraints[4] else {
        return XCTFail("Fifth constraint looks incorrect: \(constraints[4])")
      }
      guard case .expr(.intEq(.element(0, of: _), .element(1, of: _))) = constraints[5] else {
        return XCTFail("Sixth constraint looks incorrect: \(constraints[5])")
      }
      guard case .expr(.intGt(.length(of: _), .literal(1))) = constraints[6] else {
        return XCTFail("Seventh constraint looks incorrect: \(constraints[6])")
      }
      guard case .expr(.intGt(.length(of: _), .literal(0))) = constraints[7] else {
        return XCTFail("Eighth constraint looks incorrect: \(constraints[7])")
      }
      guard case .expr(.intEq(.element(1, of: _), .element(0, of: _))) = constraints[8] else {
        return XCTFail("Ninth constraint looks incorrect: \(constraints[8])")
      }
    }
  }

  func testAssertRecovery() {
    func makeCheck(_ cond: String) -> String {
      return """
        @_silgen_name("f") func f(x: Tensor<Float>, y: Tensor<Float>, z: Tensor<Float>) {
          check(\(cond))
        }
      """
    }
    let xVar = ListExpr.var(Var(0))
    let yVar = ListExpr.var(Var(1))
    let asserts: [(String, [BoolExpr])] = [
      ("x.rank == 2", [.intEq(.length(of: xVar), .literal(2))]),
      ("x.rank == y.rank", [.intEq(.length(of: xVar), .length(of: yVar))]),
      // For some reason libSIL fails when arithmetic is present
      //("x.rank == y.rank + 4", [.intEq(.length(of: xVar), .add(.length(of: yVar), .literal(4)))]),
      ("x.shape == y.shape", [.listEq(xVar, yVar)]),
      ("x.shape[1] == y.shape[2]", [
        .intGt(.length(of: xVar), .literal(1)),
        .intGt(.length(of: yVar), .literal(2)),
        .intEq(.element(1, of: xVar), .element(2, of: yVar))
      ]),
      // TODO: Tests with shape arithmetic
    ]
    for (cond, expectedExprs) in asserts {
      withSIL(forSource: makeCheck(cond)) { module in
        guard let block = getOnlyBlock(fromFunctionCalled: "f", module) else {
          return XCTFail("Couldn't retrieve the block")
        }
        guard let summary = abstract(block) else {
          return XCTFail("Failed to recover the summary for: \(cond)")
        }
        let exprs = summary.constraints.map { (_ c: Constraint) -> BoolExpr in
          switch c {
          case let .expr(expr): return expr
          case .call(_, _, _): fatalError("Didn't expect to see call constraints")
          }
        }
        XCTAssertEqual(exprs, expectedExprs)
      }
    }
  }



  static var allTests = [
    ("testFrontendConstraints", testFrontendConstraints),
  ]
}
