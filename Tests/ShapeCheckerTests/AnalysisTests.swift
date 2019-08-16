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
      [s1[0] = d1,
       s1[1] = d2,
       s1 = [d1, d2],
       s2[0] = d3,
       s2[1] = d4,
       s2 = [d3, d4],
       d3 = d2,
       d4 = d1] => (s1) -> s2
      """)
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
      guard let summary = analyzer.environment["f"] else {
        return XCTFail("Failed to find a summary for 'f'")
      }
      guard let transposeSummary = analyzer.environment["transpose"] else {
        return XCTFail("Failed to find a summary for 'transpose'")
      }
      XCTAssert(!summary.constraints.isEmpty)
      XCTAssertEqual(summary.constraints.count, transposeSummary.constraints.count)
    }
  }

  static var allTests = [
    ("testSingleFunctionAnalysis", testSingleFunctionAnalysis),
  ]
}

