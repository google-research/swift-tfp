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

      guard let signature = analyzer.environment["f"] else {
        return XCTFail("Couldn't find a signature for f!")
      }

      var model = Model()
      do {
        try model.restrict(with: signature.constraints)
      } catch Inconsistency.dimensionSizeMismatch(prev: 3, now: 2) {
        return
      } catch {
        return XCTFail("Found a wrong inconsistency: \(error)")
      }
      XCTFail("Expected the model to be inconsistent")
    }
  }


  static var allTests = [
    ("testMatmulSingleArg", testMatmulSingleArg),
  ]
}

