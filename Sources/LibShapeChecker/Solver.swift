enum SolverResult {
  case sat
  case unknown
  case unsat([BoolExpr]?)
}

func verify(_ constraints: [Constraint]) -> SolverResult {
  let solver = Z3Context.default.makeSolver()
  var shapeVars = Set<Var>()
  var trackers: [String: BoolExpr] = [:]

  for constraint in normalize(constraints) {
    switch constraint {
    case let .expr(expr):
      trackers[solver.assertAndTrack(expr.solverAST)] = expr
      // Perform a no-op substitution that has a side effect of gathering
      // all variables appearing in a formula.
      let _ = substitute(expr, using: { shapeVars.insert($0); return $0 })
    case .call(_, _, _):
      break
    }
  }
  // Additionally assert that all shapes are non-negative
  let zero = Z3Context.default.literal(0)
  for v in shapeVars {
    solver.assert(forall { ListExpr.var(v).solverAST.call($0) >= zero })
  }

  switch solver.check() {
  case .some(true):
    return .sat
  case .none:
    return .unknown
  case .some(false):
    guard let unsatCore = solver.getUnsatCore() else { return .unsat(nil) }
    return .unsat(unsatCore.map{ trackers[$0]! })
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Expression normalization
//
// It is difficult to represent some of the constraints we support in Z3 directly,
// so we destruct some of them into a kind of a normal form. The differences from
// the stock Constraint grammar is that:
// - BoolExpr.listEqual is not allowed (all shapes that are equal get replaced
//   with the same variable instead).
// - ListExpr.literal is not allowed (literals are desugared into a list of
//   dim-wise constraints).

func normalize(_ constraints: [Constraint]) -> [Constraint] {
  return Normalizer().normalize(constraints)
}

fileprivate class Normalizer {
  var equalityClasses = DefaultDict<Var, UnionFind<Var>>{ UnionFind($0) }

  func normalize(_ constraints: [Constraint]) -> [Constraint] {
    let desugared: [Constraint] = constraints.flatMap { (constraint: Constraint) -> [Constraint] in
      switch constraint {
      case let .expr(expr):
        let (newExpr, newConstraints) = normalize(expr)
        return newConstraints + (newExpr != nil ? [.expr(newExpr!)] : [])

      case .call(_, _, _):
        return []
      }
    }

    return desugared.map{ substitute($0, using: { representative(equalityClasses[$0]) }) }
  }

  func normalize(_ e: BoolExpr) -> (BoolExpr?, [Constraint]) {
    switch e {
    // Integer expressions are always in normal forms
    case .intEq(_, _): fallthrough
    case .intGt(_, _): fallthrough
    case .intGe(_, _): fallthrough
    case .intLt(_, _): fallthrough
    case .intLe(_, _): return (e, [])
    // This is the most interesting case, and it's really the one when we have
    // to do most of the work. All because of the simple fact that you can't
    // express function equality without quantifiers in Z3.
    case let .listEq(lhs, rhs):
      switch (lhs, rhs) {
      case let (.var(lhsVar), .var(rhsVar)):
        union(equalityClasses[lhsVar], equalityClasses[rhsVar])
        return (nil, [])
      case let (.literal(exprs), .var(v)): fallthrough
      case let (.var(v), .literal(exprs)):
        let lengthConstraint = [Constraint.expr(.intEq(.length(of: .var(v)), .literal(exprs.count)))]
        let elementConstraints = exprs.enumerated().compactMap {
          (offset: Int, maybeExpr: IntExpr?) -> Constraint? in
          guard let expr = maybeExpr else { return nil }
          return .expr(.intEq(.element(offset, of: .var(v)), expr))
        }
        return (nil, lengthConstraint + elementConstraints)
      case let (.literal(lhsExprs), .literal(rhsExprs)):
        let lengthConstraint = [Constraint.expr(.intEq(.literal(lhsExprs.count), .literal(rhsExprs.count)))]
        let elementConstraints = zip(lhsExprs, rhsExprs).compactMap {
          (maybeExprs: (IntExpr?, IntExpr?)) -> Constraint? in
          switch (maybeExprs.0, maybeExprs.1) {
          case let (.some(lhsExpr), .some(rhsExpr)):
            return .expr(.intEq(lhsExpr, rhsExpr))
          case let (.some(expr), .none): fallthrough
          case let (.none, .some(expr)):
            return .expr(.intGe(expr, .literal(0)))
          case (.none, .none):
            return nil
          }
        }
        return (nil, lengthConstraint + elementConstraints)
      }
    }
  }
}

fileprivate var nextIntVariable = count(from: 0) >>> String.init >>> Z3Context.default.make(intVariable:)

extension IntExpr {
  var solverAST: Z3Expr<Int> {
    switch self {
    case let .literal(value):
      return Z3Context.default.literal(value)
    case let .length(of: list):
      switch list {
      case let .var(v):
        return Z3Context.default.make(intVariable: "\(v)_rank")
      case let .literal(shapeValue):
        return Z3Context.default.literal(shapeValue.count)
      }
    case let .element(offset, of: list):
      guard offset >= 0 else { return nextIntVariable() }
      switch list {
      case let .var(v):
        let listVar = Z3Context.default.make(listVariable: "\(v)")
        return listVar.call(Z3Context.default.literal(offset))
      case let .literal(exprs):
        // NB: Out of bounds accesses will trigger a failure through a different
        //     set of assertions anyway, so no need to check for that here.
        guard offset < exprs.count,
              let expr = exprs[offset] else { return nextIntVariable() }
        return expr.solverAST
      }
    case let .add(lhs, rhs):
      return lhs.solverAST + rhs.solverAST
    case let .sub(lhs, rhs):
      return lhs.solverAST - rhs.solverAST
    case let .mul(lhs, rhs):
      return lhs.solverAST * rhs.solverAST
    case let .div(lhs, rhs):
      return lhs.solverAST / rhs.solverAST
    }
  }
}

extension BoolExpr {
  var solverAST: Z3Expr<Bool> {
    switch self {
    case let .intEq(lhs, rhs):
      return lhs.solverAST == rhs.solverAST
    case let .intGt(lhs, rhs):
      return lhs.solverAST > rhs.solverAST
    case let .intGe(lhs, rhs):
      return lhs.solverAST >= rhs.solverAST
    case let .intLt(lhs, rhs):
      return lhs.solverAST < rhs.solverAST
    case let .intLe(lhs, rhs):
      return lhs.solverAST <= rhs.solverAST
    case .listEq(_, _):
      fatalError(".solverAST should only be accessed on normalized assertions")
    }
  }
}

extension ListExpr {
  var solverAST: Z3Expr<[Int]> {
    switch self {
    case let .var(v):
      return Z3Context.default.make(listVariable: "\(v)")
    case .literal(_):
      fatalError(".solverAST should only be accessed on normalized assertions")
    }
  }
}
