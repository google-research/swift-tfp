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

@testable import LibTFP
import SIL
import XCTest

@available(macOS 10.13, *)
final class IntegrationTests: XCTestCase {

  func testMatmulSingleArg() {
    let code = """
    @_silgen_name("f") func f(x: Tensor<Float>) -> Tensor<Float> {
      assert(x.shape[0] == 2)
      assert(x.shape[1] == 3)
      return matmul(x, x)
    }
    """
    withSIL(forSource: matmulCode + code) { module, _ in
      let analyzer = Analyzer()
      analyzer.analyze(module)

      let constraints = instantiate(constraintsOf: "f", inside: analyzer.environment)
      guard !constraints.isEmpty else {
        return XCTFail("Failed to instantiate constraints for 'f'")
      }

      assertUnsat(verify(constraints))
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
      let constraints = instantiate(constraintsOf: "f", inside: analyzer.environment)
      assertUnsat(verify(constraints))
    }
  }

  func testFactory() {
    let code = """
    @_silgen_name("f")
    func f() {
      let x = randn([2, 3])
      assert(x.shape[0] == 3)
    }
    """
    withSIL(forSource: randnCode + code) { module, _ in
      let analyzer = Analyzer()
      analyzer.analyze(module)
      let constraints = instantiate(constraintsOf: "f", inside: analyzer.environment)
      assertUnsat(verify(constraints))
    }
  }

  func testStruct() {
    let code = """
    struct Matmul {
      let w: Tensor<Float>

      func callAsFunction(_ input: Tensor<Float>) -> Tensor<Float> {
        return matmul(input, w)
      }
    }

    func makeMatmul(inputs: Int, outputs: Int) -> Matmul {
      return Matmul(w: randn([inputs, outputs]))
    }

    @_silgen_name("f")
    func f() -> Tensor<Float> {
      let x = randn([2, 3])
      let layer = makeMatmul(inputs: 10, outputs: 20)
      return layer(x)
    }
    """
    withSIL(forSource: randnCode + matmulCode + code) { module, silPath in
      let analyzer = Analyzer()
      try withAST(forSILPath: silPath, analyzer.analyze)
      analyzer.analyze(module)
      let constraints = instantiate(constraintsOf: "f", inside: analyzer.environment)
      assertUnsat(verify(constraints))
    }
  }

  func assertVerificationResult(_ code: String, _ check: (SolverResult) -> Void) {
    withSIL(forSource: code) { module, silPath in
      let analyzer = Analyzer()
      analyzer.analyze(module)
      let constraints = instantiate(constraintsOf: "f", inside: analyzer.environment)
      check(verify(constraints))
    }
  }

  func assertRejected(_ code: String, file: StaticString = #file, line: UInt = #line) {
    assertVerificationResult(code, { assertUnsat($0, file: file, line: line) })
  }

  func assertAccepted(_ code: String, file: StaticString = #file, line: UInt = #line) {
    assertVerificationResult(code, { assertSat($0, file: file, line: line) })
  }

  func testPathExploration() {
    let code = """
    @_silgen_name("f")
    func f(_ x: Tensor<Float>) {
      if x.shape[0] == 2 {
        assert(x.shape[0] == 3)
      }
    }
    """
    assertRejected(code)
  }

  func testAssertAfterIf() {
    let code = """
    @_silgen_name("f")
    func f(_ x: Tensor<Float>, _ cond: Bool) {
      if CONDITION {
        assert(x.shape[1] == 3)
      } else {
        assert(x.shape[0] == 4)
        assert(x.shape[1] == 8)
      }
      assert(x.shape[0] == 2)
    }
    """
    assertRejected(code.replacingOccurrences(of: "CONDITION", with: "cond"))
    // NB: The assert after the if effectively causes the else branch to be dead, so
    //     we shouldn't emit an error in this case.
    assertAccepted(code.replacingOccurrences(of: "CONDITION", with: "x.shape[0] == 2"))
  }


  static var allTests = [
    ("testMatmulSingleArg", testMatmulSingleArg),
    ("testCustomPredicate", testCustomPredicate),
    ("testFactory", testFactory),
    ("testStruct", testStruct),
    ("testPathExploration", testPathExploration),
    ("testAssertAfterIf", testAssertAfterIf),
  ]
}

