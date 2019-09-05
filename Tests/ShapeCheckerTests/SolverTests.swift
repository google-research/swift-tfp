@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class Z3Tests: XCTestCase {
  let s0 = ListExpr.var(ListVar(0))
  let s1 = ListExpr.var(ListVar(1))
  let s2 = ListExpr.var(ListVar(2))

  func testExprTranslation() {
    let examples: [(BoolExpr, String)] = [
      (.intEq(.literal(1), .literal(2)), "(= 1 2)"),
      (.intEq(.length(of: s0), .literal(2)), "(= s0_rank 2)"),
      (.intGt(.length(of: s0), .literal(2)), "(> s0_rank 2)"),
      (.intEq(.element(1, of: s0), .element(2, of: s1)), "(= (s0 (- s0_rank 2)) (s1 (- s1_rank 3)))"),
      (.intEq(.literal(1),
              .add(.mul(.element(1, of: s1), .literal(2)),
                   .div(.sub(.element(0, of: s0), .literal(3)), .literal(4)))),
       "(= 1 (+ (* (s1 (- s1_rank 2)) 2) (div (- (s0 (- s0_rank 1)) 3) 4)))"),
      (.intGt(.literal(1), .literal(2)), "(> 1 2)"),
      (.intGe(.literal(1), .literal(2)), "(>= 1 2)"),
      (.intLt(.literal(1), .literal(2)), "(< 1 2)"),
      (.intLe(.literal(1), .literal(2)), "(<= 1 2)"),
    ]
    for (expr, expectedDescription) in examples {
      let assertions = denote(expr)
      XCTAssertEqual(assertions.last?.description, expectedDescription)
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

  func testBroadcast() {
    assertUnsat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1))),
      .expr(.intEq(.element(-1, of: s0), .literal(2))),
      .expr(.intEq(.element(-1, of: s1), .literal(3))),
    ]))
    assertSat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1))),
      .expr(.intEq(.element(-1, of: s0), .literal(1))),
      .expr(.intEq(.element(-1, of: s1), .literal(3))),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1))),
      .expr(.intEq(.element(-1, of: s1), .literal(3))),
      .expr(.intEq(.element(-1, of: s2), .literal(4))),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s1, .broadcast(s0, .literal([.literal(2), nil, .literal(1)])))),
      .expr(.intEq(.element(-3, of: s0), .literal(3))),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s1, .broadcast(s0, .literal([.literal(2), nil, .literal(1)])))),
      .expr(.intEq(.element(-3, of: s1), .literal(3))),
    ]))
    assertSat(verify([
      .expr(.listEq(s1, .broadcast(s0, .literal([.literal(2), nil, .literal(1)])))),
      .expr(.intEq(.element(-1, of: s0), .literal(3))),
    ]))
    assertSat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1))),
      .expr(.intEq(.element(0, of: s0), .literal(2))),
      .expr(.intEq(.element(0, of: s1), .literal(3))),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1))),
      .expr(.intEq(.element(0, of: s0), .literal(2))),
      .expr(.intEq(.element(0, of: s1), .literal(3))),
      .expr(.intEq(.length(of: s0), .literal(2))),
      .expr(.intEq(.length(of: s1), .literal(2))),
    ]))
  }

  func testBroadcastRank() {
    assertUnsat(verify([
      .expr(.listEq(s2, .broadcast(.literal([.literal(2), .literal(3)]), .literal([nil])))),
      .expr(.intEq(.length(of: s2), .literal(3)))
    ]))
  }

  static var allTests = [
    ("testExprTranslation", testExprTranslation),
    ("testNonNegativeShapes", testNonNegativeShapes),
    ("testLists", testLists),
    ("testBroadcast", testBroadcast),
    ("testBroadcastRank", testBroadcastRank),
  ]
}

