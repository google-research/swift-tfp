@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class AnalysisTests: XCTestCase {
  let s0 = ListExpr.var(ListVar(0))
  let s1 = ListExpr.var(ListVar(1))
  let d0 = IntExpr.var(IntVar(0))
  let d1 = IntExpr.var(IntVar(1))

  func testSingleFunctionAnalysis() {
    withSIL(forSource: transposeCode) { module in
      let analyzer = Analyzer()
      analyzer.analyze(module: module)
      guard let summary = analyzer.environment["transpose"] else {
        return XCTFail("Failed to find a summary for 'transpose'")
      }
      XCTAssertEqual(summary.prettyDescription, """
      [s0.rank == 2,
       s1 = $s10TensorFlow0A0V10transposedACyxGyF(s0),
       s1.rank == 2,
       s1.rank > 0,
       s0.rank > 1,
       s1.shape[0] == s0.shape[1],
       s1.rank > 1,
       s0.rank > 0,
       s1.shape[1] == s0.shape[0]] => (s0) -> s1
      """)
    }
  }

  func alphaNormalize(_ constraints: [Constraint]) -> [Constraint] {
    var rename = DefaultDict<Var, Var>(withDefault: makeVariableGenerator())
    return constraints.map{ substitute($0, using: { rename[$0].expr }) }
  }

  func normalize(_ constraints: [Constraint]) -> [Constraint] {
    return alphaNormalize(simplify(constraints))
  }

  func testInstantiateNoop() {
    withSIL(forSource: transposeCode) { module in
      let analyzer = Analyzer()
      analyzer.analyze(module: module)
      guard let summary = analyzer.environment["transpose"] else {
        return XCTFail("Failed to recover the summary for transpose")
      }
      let exprConstraints = summary.constraints.filter {
        if case .expr(_) = $0 { return true } else { return false }
      }
      let instance = instantiate(constraintsOf: "transpose",
                                 inside: analyzer.environment)
      XCTAssertEqual(normalize(exprConstraints), normalize(instance))
    }
  }

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
      check(x.shape[0] == 3)
      check(pred(x.shape))
    }
    """
    withSIL(forSource: code) { module in
      let analyzer = Analyzer()
      analyzer.analyze(module: module)
      let f = instantiate(constraintsOf: "f", inside: analyzer.environment)
      XCTAssertTrue(normalize(f).contains(
        .expr(.boolEq(.var(BoolVar(1)), .intEq(.element(0, of: s0), .literal(2))))
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

  static var allTests = [
    ("testSingleFunctionAnalysis", testSingleFunctionAnalysis),
    ("testInstantiateNoop", testInstantiateNoop),
    ("testAnalysisThroughCalls", testAnalysisThroughCalls),
    ("testCustomPredicate", testCustomPredicate),
  ]
}

