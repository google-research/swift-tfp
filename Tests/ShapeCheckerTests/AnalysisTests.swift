@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class AnalysisTests: XCTestCase {
  let s0 = ListExpr.var(ListVar(0))
  let s1 = ListExpr.var(ListVar(1))
  let d0 = IntExpr.var(IntVar(0))
  let d1 = IntExpr.var(IntVar(1))
  let d2 = IntExpr.var(IntVar(2))
  let b0 = BoolExpr.var(BoolVar(0))
  let b1 = BoolExpr.var(BoolVar(1))
  let b2 = BoolExpr.var(BoolVar(2))
  let b3 = BoolExpr.var(BoolVar(3))

  func alphaNormalize(_ constraints: [Constraint]) -> [Constraint] {
    var rename = DefaultDict<Var, Var>(withDefault: makeVariableGenerator())
    return constraints.map{ substitute($0, using: { rename[$0].expr }) }
  }

  lazy var normalize = simplify >>> inlineBoolVars >>> simplify >>> self.alphaNormalize

  func testAnalysisThroughCalls() {
    let callTransposeCode = """
    @_silgen_name("f")
    func f(x: Tensor<Float>) -> Tensor<Float> {
      return transpose(x) + 2
    }
    """
    withSIL(forSource: transposeCode + callTransposeCode) { module in
      let analyzer = Analyzer()
      analyzer.analyze(module: module)
      let f = instantiate(constraintsOf: "f",
                          inside: analyzer.environment)
      let transpose = instantiate(constraintsOf: "transpose",
                                  inside: analyzer.environment)
      XCTAssertEqual(normalize(f), normalize(transpose))

    }
  }

  func testCustomPredicate() {
    let code = """
    func pred(_ x : TensorShape) -> Bool {
      return x[0] == 2
    }

    @_silgen_name("f")
    func f(_ x: Tensor<Float>) {
      assert(x.shape[0] == 3)
      assert(pred(x.shape))
    }
    """
    withSIL(forSource: code) { module in
      let analyzer = Analyzer()
      analyzer.analyze(module: module)
      let f = instantiate(constraintsOf: "f", inside: analyzer.environment)
      XCTAssertTrue(normalize(f).contains(
        .expr(.intEq(.element(0, of: s0), .literal(2)))
      ))
    }
  }

  func testFactory() {
    let code = """
    @_silgen_name("f")
    func f() {
      let _ = randn([2, 3])
    }
    """
    withSIL(forSource: randnCode + code) { module in
      let analyzer = Analyzer()
      analyzer.analyze(module: module)
      let f = instantiate(constraintsOf: "f", inside: analyzer.environment)
      XCTAssertTrue(normalize(f).contains(
        .expr(.listEq(s0, .literal([.literal(2), .literal(3)])))
      ))
    }
  }

  func testTuples() {
    let code = """
    func swizzle(_ x: (Int, Int)) -> (Int, Int) {
     return (x.1, x.0)
    }

    @_silgen_name("f")
    func f(_ x: Tensor<Float>) {
      let a = x.shape[0]
      let b = x.shape[1]
      let (b2, a2) = swizzle((a, b))
      assert(a == b2)
      assert(a2 == b)
    }
    """
    withSIL(forSource: randnCode + code) { module in
      let analyzer = Analyzer()
      analyzer.analyze(module: module)
      let f = normalize(instantiate(constraintsOf: "f", inside: analyzer.environment))
      XCTAssertTrue(f.contains(.expr(.intEq(d0, .element(0, of: s1)))))
      XCTAssertTrue(f.contains(.expr(.intEq(d0, .element(1, of: s1)))))
      XCTAssertTrue(f.contains(.expr(.intEq(d2, .element(0, of: s1)))))
      XCTAssertTrue(f.contains(.expr(.intEq(d2, .element(1, of: s1)))))
    }
  }

  func testSimplify() {
    XCTAssertEqual(simplify([
      .expr(.listEq(s0, s1)),
      .expr(.listEq(s1, .literal([nil]))),
      .expr(.intGt(d1, .literal(2))),
      .expr(.intEq(d0, d1)),
    ]), [
      .expr(.listEq(s0, .literal([nil]))),
      .expr(.intGt(d0, .literal(2))),
    ])
  }

  func testInlineBoolVars() {
    XCTAssertEqual(inlineBoolVars([
      .expr(b0),
      .expr(.boolEq(b0, .intGt(d0, .literal(2)))),
    ]), [
      .expr(.intGt(d0, .literal(2))),
    ])
    // Not perfect, but good enough for now
    XCTAssertEqual(inlineBoolVars([
      .expr(b1),
      .expr(.boolEq(b1, b0)),
      .expr(.boolEq(b0, .intGt(d0, .literal(4)))),
    ]), [
      .expr(b0),
      .expr(.boolEq(b0, .intGt(d0, .literal(4)))),
    ])
    let hard: [Constraint] = [
      .expr(.boolEq(b0, b1)),
      .expr(.boolEq(b0, .intGt(d0, .literal(4)))),
      .expr(b1),
    ]
    XCTAssertEqual(inlineBoolVars(hard), hard)
  }

  static var allTests = [
    ("testAnalysisThroughCalls", testAnalysisThroughCalls),
    ("testCustomPredicate", testCustomPredicate),
  ]
}

