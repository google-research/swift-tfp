
func verify(_ constraints: [Constraint]) -> Bool? {
  let solver = Z3Context.default.makeSolver()
  for constraint in constraints {
    switch constraint {
    case let .expr(expr):
      solver.assert(expr.solverAST)
    case .call(_, _, _):
      break
    }
  }
  return solver.check()
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
        return listVar(Z3Context.default.literal(offset))
      }
    case let .add(lhs, rhs):
      return lhs.solverAST + rhs.solverAST
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
    case let .listEq(lhs, rhs):
      return lhs.solverAST == rhs.solverAST
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
