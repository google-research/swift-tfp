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

  let normalize = { resolveEqualities($0, strength: .everything) } >>>
                  inlineBoolVars >>>
                  { resolveEqualities($0, strength: .everything) } >>>
                  alphaNormalize

  func testAnalysisThroughCalls() {
    let callTransposeCode = """
    @_silgen_name("f")
    func f(x: Tensor<Float>) -> Tensor<Float> {
      return transpose(x) + 2
    }
    """
    withSIL(forSource: transposeCode + callTransposeCode) { module, _ in
      let analyzer = Analyzer()
      analyzer.analyze(module)
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
    withSIL(forSource: code) { module, _ in
      let analyzer = Analyzer()
      analyzer.analyze(module)
      let f = instantiate(constraintsOf: "f", inside: analyzer.environment)
      XCTAssertTrue(normalize(f).compactMap{ $0.boolExpr }.contains(
        .intEq(.element(0, of: s0), 2)
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
    withSIL(forSource: randnCode + code) { module, _ in
      let analyzer = Analyzer()
      analyzer.analyze(module)
      let f = instantiate(constraintsOf: "f", inside: analyzer.environment)
      XCTAssertTrue(normalize(f).compactMap{ $0.boolExpr }.contains(
        .listEq(s0, .literal([2, 3]))
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
    withSIL(forSource: randnCode + code) { module, _ in
      let analyzer = Analyzer()
      analyzer.analyze(module)
      let f = normalize(instantiate(constraintsOf: "f", inside: analyzer.environment)).compactMap{ $0.boolExpr }
      XCTAssertTrue(f.contains(.intEq(d0, .element(0, of: s1))))
      XCTAssertTrue(f.contains(.intEq(d0, .element(1, of: s1))))
      XCTAssertTrue(f.contains(.intEq(d2, .element(0, of: s1))))
      XCTAssertTrue(f.contains(.intEq(d2, .element(1, of: s1))))
    }
  }

  func testStruct() {
    let code = """
    struct Conv {
      var weight: Tensor<Float>
      var bias: Tensor<Float>
      var computedProperty: Int { 4 }
    }
    """
    withSIL(forSource: code) { module, silPath in
      let analyzer = Analyzer()
      try withAST(forSILPath: silPath, analyzer.analyze)
      let tensorType = Type.specializedType(.namedType("Tensor"), [.namedType("Float")])
      guard let convFields = analyzer.typeEnvironment["Conv"] else {
        return XCTFail("Failed to find the Conv struct def!")
      }
      guard convFields.count == 2,
            convFields[0].name == "weight",
            convFields[0].type == tensorType,
            convFields[1].name == "bias",
            convFields[1].type == tensorType else {
        return XCTFail("Struct definition has been recovered incorrectly!")
      }
    }
  }


  static var allTests = [
    ("testAnalysisThroughCalls", testAnalysisThroughCalls),
    ("testCustomPredicate", testCustomPredicate),
    ("testFactory", testFactory),
    ("testTuples", testTuples),
    ("testStruct", testStruct),
  ]
}
