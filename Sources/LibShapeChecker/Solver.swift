enum SolverResult {
  case sat
  case unknown
  case unsat([BoolExpr]?)
}

func verify(_ constraints: [Constraint]) -> SolverResult {
  let solver = Z3Context.default.makeSolver()
  var shapeVars = Set<Var>()
  var trackers: [String: BoolExpr] = [:]

  for constraint in constraints {
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


extension IntExpr {
  var solverAST: Z3Expr<Int> {
    switch self {
    case let .literal(value):
      return Z3Context.default.literal(value)
    case let .length(of: list):
      switch list {
      case let .var(v):
        return Z3Context.default.make(intVariable: "\(v)_rank")
      }
    case let .element(offset, of: list):
      switch list {
      case let .var(v):
        let listVar = Z3Context.default.make(listVariable: "\(v)")
        return listVar.call(Z3Context.default.literal(offset))
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
    case .listEq(_, _):
      // FIXME: <sigh> Z3 does not allow us to say (= s0 s1), so we
      //        will either need to insert something akin to
      //        (forall ((x Int)) (= (lhs x) (rhs x))), but that
      //        may be slow, so we might just need to preprocess the
      //        function equalities e.g. at instantiation time, and simply
      //        use a single variable for all of them...
      fatalError("Shape equality is not implemented yet!")
    }
  }
}

extension ListExpr {
  var solverAST: Z3Expr<[Int]> {
    switch self {
    case let .var(v):
      return Z3Context.default.make(listVariable: "\(v)")
    }
  }
}
