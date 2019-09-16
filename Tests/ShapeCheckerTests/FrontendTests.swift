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
    let asserts: [(String, BoolExpr)] = [
      ("x.rank == 2", .intEq(.length(of: xVar), 2)),
      ("x.rank == y.rank", .intEq(.length(of: xVar), .length(of: yVar))),
      ("x.rank == y.rank + 4", .intEq(.length(of: xVar), .add(.length(of: yVar), .literal(4)))),
      ("x.shape == y.shape", .listEq(xVar, yVar)),
      ("x.shape[1] == y.shape[2]", .intEq(.element(1, of: xVar), .element(2, of: yVar))),
      ("x.shape[0] == y.shape[0] + y.shape[1] * y.shape[2] / y.shape[3]",
       .intEq(.element(0, of: xVar), .add(
         .element(0, of: yVar),
         .div(
           .mul(.element(1, of: yVar), .element(2, of: yVar)),
           .element(3, of: yVar))
       ))),
      ("x.shape[0] > y.shape[0]", .intGt(.element(0, of: xVar), .element(0, of: yVar))),
      ("x.shape[0] >= y.shape[0]", .intGe(.element(0, of: xVar), .element(0, of: yVar))),
      ("x.shape[0] < y.shape[0]", .intLt(.element(0, of: xVar), .element(0, of: yVar))),
      ("x.shape[0] <= y.shape[0]", .intLe(.element(0, of: xVar), .element(0, of: yVar))),
      ("x.shape == y.shape", .listEq(xVar, yVar)),
      ("x.shape == [1, 2 + y.shape[0], i]",
       .listEq(xVar, .literal([1, .add(2, .element(0, of: yVar)), iVar]))),
    ]
    for (cond, expectedExpr) in asserts {
      withSIL(forSource: makeCheck(cond)) { module, _ in
        for function in module.functions {
          if function.blocks.count != 1 { continue }
          let block = function.blocks[0]
          let operatorDefs = normalizeArrayLiterals(block.operatorDefs)
          guard let summary = abstract(Block(block.identifier, block.arguments, operatorDefs, block.terminatorDef),
                                       inside: [:]) else { continue }
          if .bool(expectedExpr) == summary.retExpr {
            return
          }
        }
        XCTFail("Failed to find \(expectedExpr)")
      }
    }
  }

  static var allTests = [
    ("testAssertRecovery", testAssertRecovery),
  ]
}
