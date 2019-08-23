
extension Constraint {
  var solverAST: Z3Expr<Bool>? {
    switch self {
    // No environment to resolve the calls
    case .call(_, _, _):
      return nil
    case let .expr(expr):
      return expr.solverAST
    }
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
