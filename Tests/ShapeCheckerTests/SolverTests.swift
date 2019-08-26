@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class Z3Tests: XCTestCase {
  let s0 = ListExpr.var(Var(0))
  let s1 = ListExpr.var(Var(1))
  let s2 = ListExpr.var(Var(2))

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
      (.intLt(.literal(1), .literal(2)), "(< 1 2)"),
      (.intLe(.literal(1), .literal(2)), "(<= 1 2)"),
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

  func testLists() {
    // Rank error
    assertUnsat(verify([
      .expr(.listEq(s0, .literal([nil, nil]))),
      .expr(.listEq(s0, .literal([.literal(1)]))),
    ]))
    assertUnsat(verify([
      .expr(.listEq(.literal([nil]), .literal([nil, nil]))),
    ]))
    // Those imply x.shape[1] == x.shape[1] + 2
    assertUnsat(verify([
      .expr(.listEq(s0, .literal([nil, .add(.element(1, of: s0), .literal(2))]))),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s0, s1)),
      .expr(.listEq(s1, s2)),
      .expr(.listEq(s0, .literal([nil, .add(.element(1, of: s2), .literal(1))]))),
    ]))
    assertUnsat(verify([
      .expr(.listEq(.literal([.add(.element(1, of: s2), .literal(1))]), .literal([.element(1, of: s2)]))),
    ]))
    assertUnsat(verify([
      .expr(.intGt(.length(of: .literal([nil])), .literal(2))),
      .expr(.intEq(.element(2, of: .literal([nil])), .literal(1))),
    ]))
  }

  static var allTests = [
    ("testExprTranslation", testExprTranslation),
  ]
}

