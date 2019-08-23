@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class IntegrationTests: XCTestCase {

  func testMatmulSingleArg() {
    let code = """
    @_silgen_name("f") func f(x: Tensor<Float>) -> Tensor<Float> {
      check(x.shape[0] == 2)
      check(x.shape[1] == 3)
      return matmul(x, x)
    }
    """
    withSIL(forSource: matmulCode + code) { module in
      let analyzer = Analyzer()
      analyzer.analyze(module: module)

      let constraints = instantiate(constraintsOf: "f", inside: analyzer.environment)
      guard !constraints.isEmpty else {
        return XCTFail("Failed to instantiate constraints for 'f'")
      }

      XCTAssertEqual(verify(constraints), false)
    }
  }

  static var allTests = [
    ("testMatmulSingleArg", testMatmulSingleArg),
  ]
}

