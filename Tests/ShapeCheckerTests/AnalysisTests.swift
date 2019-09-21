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

  func eraseStacks(_ constraints: [Constraint]) -> [Constraint] {
    return constraints.map {
      switch $0 {
      case let .expr(expr, origin, _): return .expr(expr, origin, .top)
      }
    }
  }

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
      XCTAssertEqual(eraseStacks(normalize(f)), eraseStacks(normalize(transpose)))

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

  func testCallStacks() {
      let code = """
      func eq4(_ x: Int) {
        assert(x == 4)
      }

      @_silgen_name("f")
      func f() {
        eq4(5)
      }
      """
      withSIL(forSource: code) { module, silPath in
        let analyzer = Analyzer()
        analyzer.analyze(module)
        let f = normalize(instantiate(constraintsOf: "f", inside: analyzer.environment))
        guard case let .expr(_, _, .frame(.file(swiftPath, line: _), caller: _)) = f.first else {
          return XCTFail("Failed to get the Swift file path")
        }
        let topFrame = CallStack.frame(.file(swiftPath, line: 8), caller: .top)
        XCTAssertEqual(f, [
          .expr(.intEq(d0, 5), .implied, topFrame),
          .expr(.intEq(d0, 4), .asserted, .frame(.file(swiftPath, line: 3), caller: topFrame)),
        ])
      }
  }

  func testChainedBlocks() {
    let source =  """
      @_silgen_name("f") func f(x: Tensor<Float>) {
        assert(x.shape[0] == 2)
      }
    """
    withSIL(forSource: source) { module, _ in
      guard let f = module.functions.first(where: { $0.name == "f" }) else {
        return XCTFail("Failed to find the function")
      }
      guard let bb0 = f.blocks.only else {
        return XCTFail("Expected f to have exactly one block")
      }
      let bb1Arguments = bb0.arguments.map{ Argument($0.valueName + "__", $0.type) }
      f.blocks.insert(
        Block("bb1", bb1Arguments, [],
              TerminatorDef(.br("bb0", bb1Arguments.map{ Operand($0.valueName, $0.type) }), nil)),
        at: 0)
      let analyzer = Analyzer()
      analyzer.analyze(module)
      let constraints = normalize(instantiate(constraintsOf: "f", inside: analyzer.environment))
      XCTAssertEqual(constraints.compactMap{ $0.boolExpr }, [
        .intEq(.element(0, of: s0), 2)
      ])
    }
  }

  static var allTests = [
    ("testAnalysisThroughCalls", testAnalysisThroughCalls),
    ("testCustomPredicate", testCustomPredicate),
    ("testFactory", testFactory),
    ("testTuples", testTuples),
    ("testStruct", testStruct),
    ("testChainedBlocks", testChainedBlocks),
  ]
}
