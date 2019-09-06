@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class FrontendTests: XCTestCase {
  func testAssertRecovery() {
    func makeCheck(_ cond: String) -> String {
      return """
        @_silgen_name("f") func f(x: Tensor<Float>, y: Tensor<Float>, i: Int) {
          assert(\(cond))
        }
      """
    }
    let xVar = ListExpr.var(ListVar(0))
    let yVar = ListExpr.var(ListVar(1))
    let iVar = IntExpr.var(IntVar(2))
    let xyNotScalar: [BoolExpr] = [
      .intGt(.length(of: xVar), .literal(0)),
      .intGt(.length(of: yVar), .literal(0)),
    ]
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
      ("x.shape[0] == y.shape[0] + y.shape[1] * y.shape[2] / y.shape[3]", [
        .intGt(.length(of: xVar), .literal(0)),
        .intGt(.length(of: yVar), .literal(0)),
        .intGt(.length(of: yVar), .literal(1)),
        .intGt(.length(of: yVar), .literal(2)),
        .intGt(.length(of: yVar), .literal(3)),
        .intEq(.element(0, of: xVar), .add(
          .element(0, of: yVar),
          .div(
            .mul(.element(1, of: yVar), .element(2, of: yVar)),
            .element(3, of: yVar))
        )),
      ]),
      ("x.shape[0] > y.shape[0]",
       xyNotScalar + [.intGt(.element(0, of: xVar), .element(0, of: yVar))]),
      ("x.shape[0] >= y.shape[0]",
       xyNotScalar + [.intGe(.element(0, of: xVar), .element(0, of: yVar))]),
      ("x.shape[0] < y.shape[0]",
       xyNotScalar + [.intLt(.element(0, of: xVar), .element(0, of: yVar))]),
      ("x.shape[0] <= y.shape[0]",
       xyNotScalar + [.intLe(.element(0, of: xVar), .element(0, of: yVar))]),
      ("x.shape == y.shape", [.listEq(xVar, yVar)]),
      ("x.shape == [1, 2 + y.shape[0], i]", [
        .intGt(.length(of: yVar), .literal(0)),
        .listEq(xVar, .literal([.literal(1), .add(.literal(2), .element(0, of: yVar)), iVar]))
      ])
    ]
    for (cond, expectedExprs) in asserts {
      withSIL(forSource: makeCheck(cond)) { module, _ in
        var remaining = expectedExprs
        for function in module.functions {
          if function.blocks.count != 1 { continue }
          let block = function.blocks[0]
          let instrDefs = normalizeArrayLiterals(block.instructionDefs)
          guard let summary = abstract(Block(block.identifier, block.arguments, instrDefs), inside: [:]) else { continue }
          remaining = remaining.filter { summary.constraints.contains(.expr($0)) }
        }
        if !remaining.isEmpty {
          XCTFail("Failed to find the following constraints: \(remaining)")
        }
      }
    }
  }

  static var allTests = [
    ("testAssertRecovery", testAssertRecovery),
  ]
}
