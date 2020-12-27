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

import libz3

struct Decl<T> {}

class Z3Context {
  var ctx: Z3_context
  let intSort: Z3_sort
  let boolSort: Z3_sort
  lazy var `true`: Z3Expr<Bool> = Z3Expr(self, Z3_mk_true(ctx))
  lazy var `false`: Z3Expr<Bool> = Z3Expr(self, Z3_mk_false(ctx))

  init() {
    var config: Z3_config = Z3_mk_config()
    defer { Z3_del_config(config) }
    self.ctx = Z3_mk_context(config)
    self.intSort = Z3_mk_int_sort(ctx)
    self.boolSort = Z3_mk_bool_sort(ctx)
  }

  deinit {
    Z3_del_context(ctx)
  }

  func makeSolver() -> Z3Solver {
    return Z3Solver(self)
  }

  func make(intVariable name: String) -> Z3Expr<Int> {
    return Z3Expr(self, Z3_mk_const(ctx, Z3_mk_string_symbol(ctx, name), intSort))
  }

  func make(listVariable name: String) -> Z3Expr<[Int]> {
    let nameSymbol = Z3_mk_string_symbol(ctx, name)
    let funcDecl = Z3_mk_func_decl(ctx, nameSymbol, 1, [intSort], intSort)
    return Z3Expr(self, Z3_func_decl_to_ast(ctx, funcDecl))
  }

  func make(boolVariable name: String) -> Z3Expr<Bool> {
    return Z3Expr(self, Z3_mk_const(ctx, Z3_mk_string_symbol(ctx, name), boolSort))
  }

  func literal(_ value: Int) -> Z3Expr<Int> {
    return Z3Expr(self, Z3_mk_int64(ctx, Int64(value), intSort))
  }

  static let `default` = Z3Context()
}


class Z3Solver: CustomStringConvertible {
  var ctx: Z3Context
  var solver: Z3_solver
  let nextTrackVarName = count(from: 0) .>> { "tr\($0)" }

  var description: String {
    guard let nonNull = Z3_solver_to_string(ctx.ctx, solver) else { return "<NULL SOLVER?>" }
    return String(utf8String: nonNull) ?? "<SOLVER>"
  }

  init(_ ctx: Z3Context) {
    self.ctx = ctx
    self.solver = Z3_mk_solver(ctx.ctx)
    Z3_solver_inc_ref(ctx.ctx, self.solver)
  }

  deinit {
    Z3_solver_dec_ref(self.ctx.ctx, self.solver)
  }

  func assert(_ expr: Z3Expr<Bool>) {
    Z3_solver_assert(ctx.ctx, solver, expr.ast)
  }

  func assertAndTrack(_ expr: Z3Expr<Bool>) -> String {
    let trackingVarName = nextTrackVarName()
    Z3_solver_assert_and_track(ctx.ctx, solver, expr.ast, ctx.make(boolVariable: trackingVarName).ast)
    return trackingVarName
  }

  func check() -> Bool? {
    switch Z3_solver_check(ctx.ctx, solver) {
    case Z3_L_FALSE: return false
    case Z3_L_UNDEF: return nil
    case Z3_L_TRUE: return true
    default: fatalError("Z3 sovler returned an unexpected value!")
    }
  }

  func getModel() -> Z3Model? {
    guard let model = Z3_solver_get_model(ctx.ctx, solver) else { return nil }
    Z3_model_inc_ref(ctx.ctx, model)
    return Z3Model(ctx, model)
  }

  func getProof() -> Z3Expr<Void>? {
    guard let proof = Z3_solver_get_proof(ctx.ctx, solver) else { return nil }
    return Z3Expr(ctx, proof)
  }

  func getUnsatCore() -> [String]? {
    guard let assumptions = Z3_solver_get_unsat_core(ctx.ctx, solver) else { return nil }
    var assumptionNames: [String] = []
    for i in 0..<Z3_ast_vector_size(ctx.ctx, assumptions) {
      guard let assumption = Z3_ast_vector_get(ctx.ctx, assumptions, i) else { return nil }
      // FIXME: Figure out a better way to extract assumption names
      assumptionNames.append(Z3Expr<Bool>(ctx, assumption).description)
    }
    return assumptionNames
  }

  func temporaryScope(_ f: () throws -> ()) rethrows {
    Z3_solver_push(ctx.ctx, solver)
    defer { Z3_solver_pop(ctx.ctx, solver, 1) }
    try f()
  }
}

class Z3Model: CustomStringConvertible {
  var ctx: Z3Context
  var model: Z3_model
  var description: String {
    guard let nonNull = Z3_model_to_string(ctx.ctx, model) else { return "<NULL MODEL?>" }
    return String(utf8String: nonNull) ?? "<MODEL>"
  }

  init(_ ctx: Z3Context, _ model: Z3_model) {
    self.ctx = ctx
    self.model = model
  }

  func getInterpretation(of expr: Z3Expr<Decl<Int>>) -> Int? {
    let decl = Z3_to_func_decl(ctx.ctx, expr.ast)
    guard let interpretation = Z3_model_get_const_interp(ctx.ctx, model, decl) else {
      return nil
    }
    var result: Int64 = 0
    guard Z3_get_numeral_int64(ctx.ctx, interpretation, &result) != 0 else {
      fatalError("Interpretation does not fit into an int64")
    }
    return Int(result)
  }

  deinit {
    Z3_model_dec_ref(ctx.ctx, model)
  }
}

// NB: We use automatic ref-counting for ASTs provided by Z3
struct Z3Expr<T>: CustomStringConvertible {
  var ctx: Z3Context
  var ast: Z3_ast

  var description: String {
    guard let nonNull = Z3_ast_to_string(ctx.ctx, ast) else { return "<NULL AST?>" }
    return String(utf8String: nonNull) ?? "<AST>"
  }

  init(_ ctx: Z3Context, _ ast: Z3_ast) {
    self.ctx = ctx
    self.ast = ast
  }
}


func not(_ expr: Z3Expr<Bool>) -> Z3Expr<Bool> {
  return Z3Expr<Bool>(expr.ctx, Z3_mk_not(expr.ctx.ctx, expr.ast))
}

func binaryOp<A, B, C>(_ a: Z3Expr<A>,
                       _ b: Z3Expr<B>,
                       _ cstr: (Z3_context?, UInt32, UnsafePointer<Z3_ast?>?) -> Z3_ast?) -> Z3Expr<C> {
  return Z3Expr<C>(a.ctx, cstr(a.ctx.ctx, 2, [a.ast, b.ast])!)
}

func binaryOp<A, B, C>(_ a: Z3Expr<A>,
                       _ b: Z3Expr<B>,
                       _ cstr: (Z3_context?, Z3_ast?, Z3_ast?) -> Z3_ast?) -> Z3Expr<C> {
  return Z3Expr<C>(a.ctx, cstr(a.ctx.ctx, a.ast, b.ast)!)
}

func +(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Int> {
  return binaryOp(a, b, Z3_mk_add)
}

func -(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Int> {
  return binaryOp(a, b, Z3_mk_sub)
}

func *(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Int> {
  return binaryOp(a, b, Z3_mk_mul)
}

func /(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Int> {
  return binaryOp(a, b, Z3_mk_div)
}

func ==(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Bool> {
  return binaryOp(a, b, Z3_mk_eq)
}

func ==(_ a: Z3Expr<Bool>, _ b: Z3Expr<Bool>) -> Z3Expr<Bool> {
  return binaryOp(a, b, Z3_mk_eq)
}

func !=(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Bool> {
  return !(a == b)
}

func >(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Bool> {
  return binaryOp(a, b, Z3_mk_gt)
}

func >=(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Bool> {
  return binaryOp(a, b, Z3_mk_ge)
}

func <(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Bool> {
  return binaryOp(a, b, Z3_mk_lt)
}

func <=(_ a: Z3Expr<Int>, _ b: Z3Expr<Int>) -> Z3Expr<Bool> {
  return binaryOp(a, b, Z3_mk_le)
}

prefix func !(_ a: Z3Expr<Bool>) -> Z3Expr<Bool> {
  return Z3Expr(a.ctx, Z3_mk_not(a.ctx.ctx, a.ast))
}

func &&(_ a: Z3Expr<Bool>, _ b: Z3Expr<Bool>) -> Z3Expr<Bool> {
  return Z3Expr(a.ctx, Z3_mk_and(a.ctx.ctx, 2, [a.ast, b.ast]))
}

func ||(_ a: Z3Expr<Bool>, _ b: Z3Expr<Bool>) -> Z3Expr<Bool> {
  return Z3Expr(a.ctx, Z3_mk_or(a.ctx.ctx, 2, [a.ast, b.ast]))
}

func implies(_ a: Z3Expr<Bool>, _ b: Z3Expr<Bool>) -> Z3Expr<Bool> {
  return binaryOp(a, b, Z3_mk_implies)
}

func ite<T>(_ cond: Z3Expr<Bool>, _ t: Z3Expr<T>, _ f: Z3Expr<T>) -> Z3Expr<T> {
  return Z3Expr(cond.ctx, Z3_mk_ite(cond.ctx.ctx, cond.ast, t.ast, f.ast))
}

extension Z3Expr where T == [Int] {
  func call(_ arg: Z3Expr<Int>) -> Z3Expr<Int> {
    return Z3Expr<Int>(ctx, Z3_mk_app(ctx.ctx, Z3_to_func_decl(ctx.ctx, ast), 1, [arg.ast]))
  }
}

func forall(_ f: (Z3Expr<Int>) -> Z3Expr<Bool>) -> Z3Expr<Bool> {
  let context = Z3Context.default
  let ctx = context.ctx
  let intSort = Z3_mk_int_sort(ctx)
  let arg = Z3Expr<Int>(context, Z3_mk_bound(ctx, 0, intSort))
  return Z3Expr(context,
                Z3_mk_forall(ctx,
                             /*weight=*/0,
                             /*num_patterns=*/0, /*patterns=*/nil,
                             /*num_decls=*/1, /*sorts=*/[intSort],
                             /*decl_names=*/[Z3_mk_string_symbol(ctx, "dim")],
                             /*body=*/f(arg).ast))
}

func declFor<T>(_ v: Z3Expr<T>) -> Z3Expr<Decl<T>> {
  // NB: Variables are represented as function applications
  assert(Z3_get_ast_kind(v.ctx.ctx, v.ast) == Z3_ast_kind(rawValue: 1))
  let app = Z3_to_app(v.ctx.ctx, v.ast)
  return Z3Expr(v.ctx, Z3_get_app_decl(v.ctx.ctx, app))
}
