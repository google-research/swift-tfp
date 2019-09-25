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

@testable import LibShapeChecker
import XCTest
import SIL

let transposeCode = """

@_silgen_name("transpose") @inline(never)
func transpose(_ x: Tensor<Float>) -> Tensor<Float> {
  assert(x.rank == 2)
  let r = x.transposed()
  assert(r.rank == 2)
  assert(r.shape[0] == x.shape[1])
  assert(r.shape[1] == x.shape[0])
  return r
}

"""

let matmulCode = """

@_silgen_name("matmul") @inline(never)
func matmul(_ x: Tensor<Float>, _ y: Tensor<Float>) -> Tensor<Float> {
  assert(x.rank == 2)
  assert(y.rank == 2)
  assert(x.shape[1] == y.shape[0])
  let r = TensorFlow.matmul(x, y)
  assert(r.rank == 2)
  assert(r.shape[0] == x.shape[0])
  assert(r.shape[1] == y.shape[1])
  return r
}

"""

let randnCode = """

func randn(_ shape: TensorShape) -> Tensor<Float> {
  let result = Tensor<Float>(randomNormal: shape)
  assert(result.shape == shape)
  return result
}

"""

extension XCTestCase {
  func getFunction(called name: String, _ module: Module) -> Function? {
    guard let f = module.functions.first(where: { $0.name == name }) else {
      XCTFail("Couldn't find a function called \(name)")
      return nil
    }
    return f
  }

  func getOnlyBlock(_ function: Function) -> Block? {
    if function.blocks.count == 1 {
      return function.blocks[0]
    } else {
      XCTFail("Expected function to have a single block!")
      return nil
    }
  }

  func getOnlyBlock(fromFunctionCalled name: String, _ module: Module) -> Block? {
    guard let f = getFunction(called: name, module) else { return nil }
    return getOnlyBlock(f)
  }
}

func assertUnsat(_ result: SolverResult, file: StaticString = #file, line: UInt = #line) {
  guard case .unsat(_) = result else {
    return XCTFail("Expected unsat, got: \(result)!", file: file, line: line)
  }
}

func assertSat(_ result: SolverResult, file: StaticString = #file, line: UInt = #line) {
  guard case .sat = result else {
    return XCTFail("Expected sat, got: \(result)!", file: file, line: line)
  }
}

extension Constraint {
  var exprWithoutCond: BoolExpr? {
    guard case let .expr(expr, assuming: .true, _, _) = self else { return nil }
    return expr
  }
}

extension RawConstraint {
  var exprWithoutCond: BoolExpr? {
    guard case let .expr(expr, assuming: .true, _, _) = self else { return nil }
    return expr
  }
}

struct ExprAndAssumption: Equatable {
  var expr: BoolExpr
  var assuming: BoolExpr

  init(_ expr: BoolExpr, assuming: BoolExpr) {
    self.expr = expr
    self.assuming = assuming
  }
}

extension Constraint {
  var unpackExprs: ExprAndAssumption {
    switch self {
    case let .expr(expr, assuming: cond, _, _): return ExprAndAssumption(expr, assuming: cond)
    }
  }
}
