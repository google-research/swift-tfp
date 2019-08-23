@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class AnalysisTests: XCTestCase {
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
      XCTAssertEqual(exprConstraints,
                     instantiate(constraintsOf: "transpose", inside: analyzer.environment))
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
      XCTAssertEqual(instantiate(constraintsOf: "f", inside: analyzer.environment),
                     instantiate(constraintsOf: "transpose", inside: analyzer.environment))
    }
  }

  static var allTests = [
    ("testSingleFunctionAnalysis", testSingleFunctionAnalysis),
    ("testInstantiateNoop", testInstantiateNoop),
    ("testAnalysisThroughCalls", testAnalysisThroughCalls),
  ]
}

