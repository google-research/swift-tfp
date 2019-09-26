// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SIL
import XCTest
import Foundation
import LibTFP

@available(macOS 10.13, *)
extension XCTestCase {
  func withTemporaryFile(_ f: (URL) -> ()) {
    do {
      try LibTFP.withTemporaryFile(f)
    } catch {
      return XCTFail("Failed to create temporary directory")
    }
  }

  func withSIL(forFile: String, _ f: (Module, URL) throws -> ()) {
    do {
      try LibTFP.withSIL(forFile: forFile) { module, silPath in
        do {
          try f(module, silPath)
        } catch {
          return XCTFail("An error has been thrown: \(error)")
        }
      }
    } catch {
      return XCTFail("Failed to retrieve SIL for \(forFile)")
    }
  }

  func withSIL(forSource code: String, _ f: (Module, URL) throws -> ()) {
    let preamble = """
    import TensorFlow

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
