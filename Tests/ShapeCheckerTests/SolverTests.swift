@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class Z3Tests: XCTestCase {
  let s0 = ListExpr.var(Var(0))
  let s1 = ListExpr.var(Var(1))

  func testExprTranslation() {
    let examples: [(BoolExpr, String)] = [
      (.intEq(.literal(1), .literal(2)), "(= 1 2)"),
      (.intEq(.length(of: s0), .literal(2)), "(= s0_rank 2)"),
      (.intGt(.length(of: s0), .literal(2)), "(> s0_rank 2)"),
      (.intEq(.element(1, of: s0), .element(2, of: s1)), "(= (s0 1) (s1 2))"),
    ]
    for (expr, expectedDescription) in examples {
      XCTAssertEqual(expr.solverAST.description, expectedDescription)
    }
  }

  static var allTests = [
    ("testExprTranslation", testExprTranslation),
  ]
}

