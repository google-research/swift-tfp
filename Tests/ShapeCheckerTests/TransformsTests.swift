@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class TransformsTests: XCTestCase {
  let s0 = ListExpr.var(ListVar(0))
  let s1 = ListExpr.var(ListVar(1))
  let d0 = IntExpr.var(IntVar(0))
  let d1 = IntExpr.var(IntVar(1))
  let d2 = IntExpr.var(IntVar(2))
  let b0 = BoolExpr.var(BoolVar(0))
  let b1 = BoolExpr.var(BoolVar(1))
  let b2 = BoolExpr.var(BoolVar(2))
  let b3 = BoolExpr.var(BoolVar(3))

  func testResolveEqualities() {
    XCTAssertEqual(resolveEqualities([
      .expr(.listEq(s0, s1), .asserted, .unknown),
      .expr(.listEq(s1, .literal([nil])), .asserted, .unknown),
      .expr(.intGt(d1, 2), .asserted, .unknown),
      .expr(.intEq(d0, d1), .asserted, .unknown),
    ], strength: .everything), [
      .expr(.listEq(s0, .literal([nil])), .asserted, .unknown),
      .expr(.intGt(d0, 2), .asserted, .unknown),
    ])
    XCTAssertEqual(resolveEqualities([
      .expr(.listEq(s0, s1), .asserted, .unknown),
      .expr(.listEq(s1, .literal([nil])), .asserted, .unknown),
      .expr(.intGt(d2, 2), .asserted, .unknown),
      .expr(.intEq(d0, d1), .asserted, .unknown),
      .expr(.intEq(d1, d2), .implied, .unknown),
    ], strength: .all(of: [.shape, .implied])), [
      .expr(.listEq(s0, .literal([nil])), .asserted, .unknown),
      .expr(.intGt(d1, 2), .asserted, .unknown),
      .expr(.intEq(d0, d1), .asserted, .unknown),
    ])
    XCTAssertEqual(resolveEqualities([
      .expr(.listEq(s0, s1), .asserted, .unknown),
      .expr(.listEq(s1, .literal([nil])), .asserted, .unknown),
      .expr(.intGt(d1, .literal(2)), .asserted, .unknown),
      .expr(.intEq(d0, d1), .asserted, .unknown),
    ], strength: .shape), [
      .expr(.listEq(s0, .literal([nil])), .asserted, .unknown),
      .expr(.intGt(d1, .literal(2)), .asserted, .unknown),
      .expr(.intEq(d0, d1), .asserted, .unknown),
    ])
  }

  func testInlineBoolVars() {
    XCTAssertEqual(inlineBoolVars([
      .expr(b0, .asserted, .unknown),
      .expr(.boolEq(b0, .intGt(d0, .literal(2))), .asserted, .unknown),
    ]), [
      .expr(.intGt(d0, .literal(2)), .asserted, .unknown),
    ])
    // Not perfect, but good enough for now
    XCTAssertEqual(inlineBoolVars([
      .expr(b1, .asserted, .unknown),
      .expr(.boolEq(b1, b0), .asserted, .unknown),
      .expr(.boolEq(b0, .intGt(d0, .literal(4))), .asserted, .unknown),
    ]), [
      .expr(b0, .asserted, .unknown),
      .expr(.boolEq(b0, .intGt(d0, .literal(4))), .asserted, .unknown),
    ])
    let hard: [Constraint] = [
      .expr(.boolEq(b0, b1), .asserted, .unknown),
      .expr(.boolEq(b0, .intGt(d0, .literal(4))), .asserted, .unknown),
      .expr(b1, .asserted, .unknown),
    ]
    XCTAssertEqual(inlineBoolVars(hard), hard)
  }

  func testSimplify() {
    XCTAssertEqual(simplify(.add(2, 4)), 6)
    XCTAssertEqual(simplify(.add(d1, 0)), d1)
    XCTAssertEqual(simplify(.add(0, d1)), d1)
    XCTAssertEqual(simplify(.sub(6, 2)), 4)
    XCTAssertEqual(simplify(.mul(6, 2)), 12)
    XCTAssertEqual(simplify(.div(5, 2)), 2)
    XCTAssertEqual(simplify(.element(0, of: .literal([d0]))), d0)
    XCTAssertEqual(simplify(.element(-2, of: .literal([d0, nil]))), d0)
    XCTAssertEqual(simplify(.broadcast(.literal([4, 5]), .literal([8, 4, 1]))),
                   .literal([8, 4, 5]))
    XCTAssertEqual(simplify(.broadcast(.literal([4, nil]), .literal([8, 4, 5]))),
                   .literal([8, 4, 5]))
    XCTAssertEqual(simplify(.broadcast(.literal([4, nil]), .literal([8, 4, nil]))),
                   .literal([8, 4, nil]))
  }

  func testDeduplicate() {
    XCTAssertEqual(deduplicate([
      .expr(.intEq(.element(1, of: s0), 2), .asserted, .unknown),
      .expr(.intEq(.element(0, of: s0), 4), .asserted, .unknown),
      .expr(.intEq(.element(1, of: s0), 2), .asserted, .unknown),
      .expr(.listEq(s0, .literal([nil, 2])), .asserted, .unknown),
      .expr(.intEq(.element(1, of: s0), 2), .asserted, .unknown),
      .expr(.listEq(s0, .literal([nil, 2])), .asserted, .unknown),
    ]), [
      .expr(.intEq(.element(1, of: s0), 2), .asserted, .unknown),
      .expr(.intEq(.element(0, of: s0), 4), .asserted, .unknown),
      .expr(.listEq(s0, .literal([nil, 2])), .asserted, .unknown),
    ])
  }

  func testInline() {
    // If we read the expressions in order then we cannot remove the second one
    let nonInlinable: [Constraint] = [
      .expr(.intGt(d0, d1), .asserted, .unknown),
      .expr(.intEq(d0, 2), .asserted, .unknown),
    ]
    XCTAssertEqual(inline(nonInlinable), nonInlinable)

    XCTAssertEqual(inline([
      .expr(.intEq(d0, .add(d1, d2)), .asserted, .unknown),
      .expr(.intEq(d0, 2), .asserted, .unknown),
    ]), [
      .expr(.intEq(.add(d1, d2), 2), .asserted, .unknown),
    ])

    XCTAssertEqual(inline([
      .expr(.intEq(d0, .add(d1, d2)), .asserted, .unknown),
      .expr(.intEq(d1, .sub(d0, 2)), .asserted, .unknown),
      .expr(.intEq(d0, 2), .asserted, .unknown),
    ]), [
      .expr(.intEq(d1, .sub(.add(d1, d2), 2)), .asserted, .unknown),
      .expr(.intEq(.add(d1, d2), 2), .asserted, .unknown),
    ])

    XCTAssertEqual(inline([
      .expr(.intEq(d0, .add(2, 3)), .asserted, .unknown),
      .expr(.intEq(d1, .mul(d0, d0)), .asserted, .unknown),
      .expr(.intEq(d2, .sub(d1, 5)), .asserted, .unknown),
      .expr(.intEq(.element(0, of: s0), d2), .asserted, .unknown)
    ]), [
      .expr(.intEq(.element(0, of: s0), 20), .asserted, .unknown),
    ])
  }

  static var allTests = [
    ("testResolveEqualities", testResolveEqualities),
    ("testInlineBoolVars", testInlineBoolVars),
    ("testSimplify", testSimplify),
    ("testDeduplicate", testDeduplicate),
    ("testInline", testInline),
  ]
}


