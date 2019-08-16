import SIL
import XCTest
import Foundation

extension FileManager {
  func makeTemporaryFile() -> URL? {
    let tmpDir: URL
    if #available(macOS 10.12, *) {
      tmpDir = self.temporaryDirectory
    } else {
      tmpDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
    }
    let dirPath = tmpDir.appendingPathComponent("test.XXXXXX.swift")
    return dirPath.withUnsafeFileSystemRepresentation { maybePath in
      guard let path = maybePath else { return nil }
      var mutablePath = Array(repeating: Int8(0), count: Int(PATH_MAX))
      mutablePath.withUnsafeMutableBytes { mutablePathBufferPtr in
        mutablePathBufferPtr.baseAddress!.copyMemory(
          from: path, byteCount: Int(strlen(path)) + 1)
      }
      guard mkstemps(&mutablePath, Int32(".swift".count)) != -1 else { return nil }
      return URL(
        fileURLWithFileSystemRepresentation: mutablePath, isDirectory: false, relativeTo: nil)
    }
  }
}

@available(macOS 10.13, *)
extension XCTestCase {
  func withTemporaryFile(f: (URL) -> ()) {
    guard let tmp = FileManager.default.makeTemporaryFile() else {
      return XCTFail("Failed to create temporary directory")
    }
    defer { try? FileManager.default.removeItem(atPath: tmp.path) }
    f(tmp)
  }

  func withSIL(forFile: String, _ f: (Module) -> ()) {
    withTemporaryFile { tempFile in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["swiftc", "-emit-sil", "-o", tempFile.path, forFile]
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        return XCTFail("Failed to execute swiftc!")
      }
      do {
        let module = try Module.parse(fromSILPath: tempFile.path)
        f(module)
      } catch {
        return XCTFail("Failed to parse the SIL!")
      }
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
