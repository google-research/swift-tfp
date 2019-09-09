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
      (.intEq(1, 2), "(= 1 2)"),
      (.intEq(.length(of: s0), 2), "(= s0_rank 2)"),
      (.intGt(.length(of: s0), 2), "(> s0_rank 2)"),
      (.intEq(.element(1, of: s0), .element(2, of: s1)), "(= (s0 (- s0_rank 2)) (s1 (- s1_rank 3)))"),
      (.intEq(1,
              .add(.mul(.element(1, of: s1), 2),
                   .div(.sub(.element(0, of: s0), 3), 4))),
       "(= 1 (+ (* (s1 (- s1_rank 2)) 2) (div (- (s0 (- s0_rank 1)) 3) 4)))"),
      (.intGt(1, 2), "(> 1 2)"),
      (.intGe(1, 2), "(>= 1 2)"),
      (.intLt(1, 2), "(< 1 2)"),
      (.intLe(1, 2), "(<= 1 2)"),
    ]
    for (expr, expectedDescription) in examples {
      let assertions = denote(expr)
      XCTAssertEqual(assertions.last?.description, expectedDescription)
    }
  }

  func testNonNegativeShapes() {
    // x.shape[0] + 1 == 0 should be unsatisfiable
    assertUnsat(verify([
      .expr(.intEq(.add(.element(0, of: s0), 1), 0), .unknown),
    ]))
    // Same if we hide the dependency transitively
    assertUnsat(verify([
      .expr(.intEq(.element(0, of: s0), .sub(.element(0, of: s1), 1)), .unknown),
      .expr(.intEq(.element(0, of: s1), 0), .unknown),
    ]))
  }

  func testLists() {
    // Rank error
    assertUnsat(verify([
      .expr(.listEq(s0, .literal([nil, nil])), .unknown),
      .expr(.listEq(s0, .literal([1])), .unknown),
    ]))
    assertUnsat(verify([
      .expr(.listEq(.literal([nil]), .literal([nil, nil])), .unknown),
    ]))
    // Those imply x.shape[1] == x.shape[1] + 2
    assertUnsat(verify([
      .expr(.listEq(s0, .literal([nil, .add(.element(1, of: s0), 2)])), .unknown),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s0, s1), .unknown),
      .expr(.listEq(s1, s2), .unknown),
      .expr(.listEq(s0, .literal([nil, .add(.element(1, of: s2), 1)])), .unknown),
    ]))
    assertUnsat(verify([
      .expr(.listEq(.literal([.add(.element(1, of: s2), 1)]), .literal([.element(1, of: s2)])), .unknown),
    ]))
    assertUnsat(verify([
      .expr(.intGt(.length(of: .literal([nil])), 2), .unknown),
      .expr(.intEq(.element(2, of: .literal([nil])), 1), .unknown),
    ]))
  }

  func testBroadcast() {
    assertUnsat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1)), .unknown),
      .expr(.intEq(.element(-1, of: s0), 2), .unknown),
      .expr(.intEq(.element(-1, of: s1), 3), .unknown),
    ]))
    assertSat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1)), .unknown),
      .expr(.intEq(.element(-1, of: s0), 1), .unknown),
      .expr(.intEq(.element(-1, of: s1), 3), .unknown),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1)), .unknown),
      .expr(.intEq(.element(-1, of: s1), 3), .unknown),
      .expr(.intEq(.element(-1, of: s2), 4), .unknown),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s1, .broadcast(s0, .literal([2, nil, 1]))), .unknown),
      .expr(.intEq(.element(-3, of: s0), 3), .unknown),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s1, .broadcast(s0, .literal([2, nil, 1]))), .unknown),
      .expr(.intEq(.element(-3, of: s1), 3), .unknown),
    ]))
    assertSat(verify([
      .expr(.listEq(s1, .broadcast(s0, .literal([2, nil, 1]))), .unknown),
      .expr(.intEq(.element(-1, of: s0), 3), .unknown),
    ]))
    assertSat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1)), .unknown),
      .expr(.intEq(.element(0, of: s0), 2), .unknown),
      .expr(.intEq(.element(0, of: s1), 3), .unknown),
    ]))
    assertUnsat(verify([
      .expr(.listEq(s2, .broadcast(s0, s1)), .unknown),
      .expr(.intEq(.element(0, of: s0), 2), .unknown),
      .expr(.intEq(.element(0, of: s1), 3), .unknown),
      .expr(.intEq(.length(of: s0), 2), .unknown),
      .expr(.intEq(.length(of: s1), 2), .unknown),
    ]))
  }

  func testBroadcastRank() {
    assertUnsat(verify([
      .expr(.listEq(s2, .broadcast(.literal([2, 3]), .literal([nil]))), .unknown),
      .expr(.intEq(.length(of: s2), 3), .unknown),
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

