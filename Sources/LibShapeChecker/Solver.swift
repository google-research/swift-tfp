enum SolverResult {
  case sat
  case unknown
  case unsat([BoolExpr]?)
}

let optimize = simplify >>> inlineBoolVars >>> simplify

func verify(_ constraints: [Constraint]) -> SolverResult {
  let solver = Z3Context.default.makeSolver()
  var shapeVars = Set<ListVar>()
  var trackers: [String: BoolExpr] = [:]

  for constraint in optimize(constraints) {
    switch constraint {
    case let .expr(expr):
      trackers[solver.assertAndTrack(expr.solverAST)] = expr
      // Perform a no-op substitution that has a side effect of gathering
      // all variables appearing in a formula.
      let _ = substitute(expr, using: {
        if case let .list(v) = $0 {
          shapeVars.insert(v)
        }
        return nil
      })
    case .call(_, _, _):
      break
    }
  }
  // Additionally assert that all shapes are non-negative
  let zero = Z3Context.default.literal(0)
  for v in shapeVars {
    solver.assert(forall { v.solverAST.call($0) >= zero })
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
// Z3 translation

fileprivate var nextIntVariable = count(from: 0) .>> String.init .>> Z3Context.default.make(intVariable:)

extension ListVar {
  var solverAST: Z3Expr<[Int]> { Z3Context.default.make(listVariable: description) }
}

extension IntVar {
  var solverAST: Z3Expr<Int> { Z3Context.default.make(intVariable: description) }
}

extension BoolVar {
  var solverAST: Z3Expr<Bool> { Z3Context.default.make(boolVariable: description) }
}

extension IntExpr {
  var solverAST: Z3Expr<Int> {
    switch self {
    case let .var(v):
      return v.solverAST
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
      // NB: Negative offsets are not supported yet, so we treat them as "any value"
      //     so that they're never involved in a contradiction.
      guard offset >= 0 else { return nextIntVariable() }
      switch list {
      case let .var(v):
        return v.solverAST.call(Z3Context.default.literal(offset))
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
    case let .var(v):
      return v.solverAST
    case let .and(subexprs):
      return z3and(subexprs.map{ $0.solverAST })
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
    case let .listEq(lhs, rhs):
      switch (lhs, rhs) {
      case let (.var(lhsVar), .var(rhsVar)):
        return forall { lhsVar.solverAST.call($0) == rhsVar.solverAST.call($0) }
      case let (.literal(exprs), .var(v)): fallthrough
      case let (.var(v), .literal(exprs)):
        let lengthConstraint = BoolExpr.intEq(.length(of: .var(v)), .literal(exprs.count))
        let elementConstraints = exprs.enumerated().compactMap {
          (offset: Int, maybeExpr: IntExpr?) -> BoolExpr? in
          guard let expr = maybeExpr else { return nil }
          return .intEq(.element(offset, of: .var(v)), expr)
        }
        return BoolExpr.and([lengthConstraint] + elementConstraints).solverAST
      case let (.literal(lhsExprs), .literal(rhsExprs)):
        let lengthConstraint = BoolExpr.intEq(.literal(lhsExprs.count), .literal(rhsExprs.count))
        let elementConstraints = zip(lhsExprs, rhsExprs).compactMap {
          (maybeExprs: (IntExpr?, IntExpr?)) -> BoolExpr? in
          switch (maybeExprs.0, maybeExprs.1) {
          case let (.some(lhsExpr), .some(rhsExpr)):
            return .intEq(lhsExpr, rhsExpr)
          case let (.some(expr), .none): fallthrough
          case let (.none, .some(expr)):
            // FIXME: This is a bit overzealous, because we don't do any verification
            //        to determine whether the assertions are statements about lists
            //        of integers (where having negative elements is fine) or shapes.
            return .intGe(expr, .literal(0))
          case (.none, .none):
            return nil
          }
        }
        return BoolExpr.and([lengthConstraint] + elementConstraints).solverAST
      }
    case let .boolEq(lhs, rhs):
      return lhs.solverAST == rhs.solverAST
    }
  }
}

// NB: No instance for ListExpr.solverAST, because there's no way to
//     instantiate the AST for literals without significant side effects.
