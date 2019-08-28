import SIL
import XCTest
import Foundation
import LibShapeChecker

@available(macOS 10.13, *)
extension XCTestCase {
  func withTemporaryFile(_ f: (URL) -> ()) {
    do {
      try LibShapeChecker.withTemporaryFile(f)
    } catch {
      return XCTFail("Failed to create temporary directory")
    }
  }

  func withSIL(forFile: String, _ f: (Module) -> ()) {
    do {
      try LibShapeChecker.withSIL(forFile: forFile, f)
    } catch {
      return XCTFail("Failed to retrieve SIL for \(forFile)")
    }
  }

  func withSIL(forSource code: String, _ f: (Module) -> ()) {
    let preamble = """
    import TensorFlow

    @_silgen_name("check") @inline(never) func check(_ cond: Bool) {}

    """
    withTemporaryFile { tempFile in
      let fullCode = preamble + code
      do {
        try fullCode.write(to: tempFile, atomically: false, encoding: .utf8)
        withSIL(forFile: tempFile.path, f)
      } catch {
        return XCTFail("Failed to write the source to a temporary file!")
      }
    }
  }
}
