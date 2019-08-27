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
      (.intEq(.literal(1),
              .add(.mul(.element(1, of: s1), .literal(2)),
                   .div(.sub(.element(0, of: s0), .literal(3)), .literal(4)))),
       "(= 1 (+ (* (s1 1) 2) (div (- (s0 0) 3) 4)))"),
      (.intGt(.literal(1), .literal(2)), "(> 1 2)"),
      (.intGe(.literal(1), .literal(2)), "(>= 1 2)"),
      (.not(.intGt(.literal(1), .literal(2))), "(not (> 1 2))"),
    ]
    for (expr, expectedDescription) in examples {
      XCTAssertEqual(expr.solverAST.description, expectedDescription)
    }
  }

  func testNonNegativeShapes() {
    // x.shape[0] + 1 == 0 should be unsatisfiable
    assertUnsat(verify([
      .expr(.intEq(.add(.element(0, of: s0), .literal(1)), .literal(0)))
    ]))
    // Same if we hide the dependency transitively
    assertUnsat(verify([
      .expr(.intEq(.element(0, of: s0), .sub(.element(0, of: s1), .literal(1)))),
      .expr(.intEq(.element(0, of: s1), .literal(0)))
    ]))
  }

  static var allTests = [
    ("testExprTranslation", testExprTranslation),
  ]
}

