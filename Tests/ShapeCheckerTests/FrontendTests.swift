@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class FrontendTests: XCTestCase {

  func testFrontendConstraints() {
    withSIL(forSource: transposeCode) { module in
      guard let block = getOnlyBlock(fromFunctionCalled: "transpose", module) else { return }
      let constraints = gatherConstraints(block: block)
      guard constraints.count == 5 else {
        return XCTFail("Expected to find exactly 5 constraints")
      }
      guard case .value(.equals(.rank(of: _), .int(2))) = constraints[0] else {
        return XCTFail("First constraint looks incorrect: \(constraints[0])")
      }
      guard case let .apply(methodName, _, _) = constraints[1] else {
        return XCTFail("Second constraint should be an apply constraint: \(constraints[1])")
      }
      guard methodName.contains("transposed") else {
        return XCTFail("Called method should contain 'transposed' within its name")
      }
      guard case .value(.equals(.rank(of: _), .int(2))) = constraints[2] else {
        return XCTFail("Third constraint looks incorrect: \(constraints[2])")
      }
      guard case .value(.equals(.dim(0, of: _), .dim(1, of: _))) = constraints[3] else {
        return XCTFail("Fourth constraint looks incorrect: \(constraints[3])")
      }
      guard case .value(.equals(.dim(1, of: _), .dim(0, of: _))) = constraints[4] else {
        return XCTFail("Fifth constraint looks incorrect: \(constraints[4])")
      }
    }
  }

  static var allTests = [
    ("testFrontendConstraints", testFrontendConstraints),
  ]
}
