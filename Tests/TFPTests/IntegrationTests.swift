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

  func testPathExploration() {
    let code = """
    @_silgen_name("f")
    func f(_ x: Tensor<Float>) {
      if x.shape[0] == 2 {
        assert(x.shape[0] == 3)
      }
    }
    """
    withSIL(forSource: code) { module, silPath in
      let analyzer = Analyzer()
      analyzer.analyze(module)
      let constraints = instantiate(constraintsOf: "f", inside: analyzer.environment)
      assertUnsat(verify(constraints))
    }
  }


  static var allTests = [
    ("testMatmulSingleArg", testMatmulSingleArg),
    ("testCustomPredicate", testCustomPredicate),
    ("testFactory", testFactory),
    ("testStruct", testStruct),
    ("testPathExploration", testPathExploration),
  ]
}

