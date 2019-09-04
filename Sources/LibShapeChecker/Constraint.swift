public typealias VarName = Int

public struct ListVar: Hashable {
  let name: VarName
  init(_ name: VarName) { self.name = name }
}

public struct IntVar: Hashable {
  let name: VarName
  init(_ name: VarName) { self.name = name }
}

public struct BoolVar: Hashable {
  let name: VarName
  init(_ name: VarName) { self.name = name }
}

public enum Var: Hashable {
  case int(IntVar)
  case list(ListVar)
  case bool(BoolVar)

  public var expr: Expr {
    switch self {
    case let .int(v): return .int(.var(v))
    case let .list(v): return .list(.var(v))
    case let .bool(v): return .bool(.var(v))
    }
  }
}

public indirect enum IntExpr: Equatable {
  // NB: No variables on this level. All integral qualities are derived from
  //     list expressions for now.
  case `var`(IntVar)
  case literal(Int)
  case length(of: ListExpr)
  // TODO: Accept int expressions instead of literals only?
  // TODO: Handle negative integers
  case element(Int, of: ListExpr)

  case add(IntExpr, IntExpr)
  case sub(IntExpr, IntExpr)
  case mul(IntExpr, IntExpr)
  case div(IntExpr, IntExpr)
}

public indirect enum ListExpr: Equatable {
  case `var`(ListVar)
  case literal([IntExpr?])
  case broadcast(ListExpr, ListExpr)
}

public indirect enum BoolExpr: Equatable {
  case `var`(BoolVar)
  case and([BoolExpr])
  case intEq(IntExpr, IntExpr)
  case intGt(IntExpr, IntExpr)
  case intGe(IntExpr, IntExpr)
  case intLt(IntExpr, IntExpr)
  case intLe(IntExpr, IntExpr)
  case listEq(ListExpr, ListExpr)
  case boolEq(BoolExpr, BoolExpr)
}

public enum Expr: Equatable {
  case int(IntExpr)
  case list(ListExpr)
  case bool(BoolExpr)
}

public enum Constraint: Equatable {
  case expr(BoolExpr)
  case call(_ name: String, _ args: [Expr?], _ result: Expr?)

  var expr: BoolExpr? {
    guard case let .expr(subexpr) = self else { return nil }
    return subexpr
  }
}

func makeVariableGenerator() -> (Var) -> Var {
  let freshName = count(from: 0)
  return { (_ v: Var) -> Var in
    switch v {
    case .int(_): return .int(IntVar(freshName()))
    case .list(_): return .list(ListVar(freshName()))
    case .bool(_): return .bool(BoolVar(freshName()))
    }
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Substitution support

public typealias Substitution = (Var) -> Expr?

public func substitute(_ v: IntVar, using s: Substitution) -> IntExpr {
  guard let result = s(.int(v)) else { return .var(v) }
  guard case let .int(expr) = result else {
    fatalError("Substitution expected to return an IntExpr!")
  }
  return expr
}

public func substitute(_ v: ListVar, using s: Substitution) -> ListExpr {
  guard let result = s(.list(v)) else { return .var(v) }
  guard case let .list(expr) = result else {
    fatalError("Substitution expected to return a ListExpr!")
  }
  return expr
}

public func substitute(_ v: BoolVar, using s: Substitution) -> BoolExpr {
  guard let result = s(.bool(v)) else { return .var(v) }
  guard case let .bool(expr) = result else {
    fatalError("Substitution expected to return a BoolExpr!")
  }
  return expr
}

public func substitute(_ e: IntExpr, using s: Substitution) -> IntExpr {
  switch e {
  case let .var(v):
    return substitute(v, using: s)
  case let .literal(v):
    return .literal(v)
  case let .length(of: expr):
    return .length(of: substitute(expr, using: s))
  case let .element(offset, of: expr):
    return .element(offset, of: substitute(expr, using: s))
  case let .add(lhs, rhs):
    return .add(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .sub(lhs, rhs):
    return .sub(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .mul(lhs, rhs):
    return .mul(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .div(lhs, rhs):
    return .div(substitute(lhs, using: s), substitute(rhs, using: s))
  }
}

public func substitute(_ e: ListExpr, using s: Substitution) -> ListExpr {
  switch e {
  case let .var(v):
    return substitute(v, using: s)
  case let .literal(subexprs):
    return .literal(subexprs.map{ $0.map { substitute($0, using: s) } })
  case let .broadcast(lhs, rhs):
    return .broadcast(substitute(lhs, using: s), substitute(rhs, using: s))
  }
}

public func substitute(_ e: BoolExpr, using s: Substitution) -> BoolExpr {
  switch e {
  case let .var(v):
    return substitute(v, using: s)
  case let .and(subexprs):
    return .and(subexprs.map{ substitute($0, using: s) })
  case let .intEq(lhs, rhs):
    return .intEq(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .intGt(lhs, rhs):
    return .intGt(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .intGe(lhs, rhs):
    return .intGe(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .intLt(lhs, rhs):
    return .intLt(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .intLe(lhs, rhs):
    return .intLe(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .listEq(lhs, rhs):
    return .listEq(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .boolEq(lhs, rhs):
    return .boolEq(substitute(lhs, using: s), substitute(rhs, using: s))
  }
}

public func substitute(_ c: Constraint, using s: Substitution) -> Constraint {
  switch c {
  case let .expr(expr):
    return .expr(substitute(expr, using: s))
  case let .call(name, args, result):
    return .call(name, args.map{ $0.map{ substitute($0, using: s) } }, result.map{ substitute($0, using: s) })
  }
}

public func substitute(_ e: Expr, using s: Substitution) -> Expr {
  switch e {
  case let .int(expr): return .int(substitute(expr, using: s))
  case let .list(expr): return .list(substitute(expr, using: s))
  case let .bool(expr): return .bool(substitute(expr, using: s))
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - CustomStringConvertible instances

extension ListVar: CustomStringConvertible {
  public var description: String { "s\(name)" }
}

extension IntVar: CustomStringConvertible {
  public var description: String { "d\(name)" }
}

extension BoolVar: CustomStringConvertible {
  public var description: String { "b\(name)" }
}

extension Var: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .int(v): return v.description
    case let .list(v): return v.description
    case let .bool(v): return v.description
    }
  }
}

extension IntExpr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .var(v):
      return v.description
    case let .literal(v):
      return String(v)
    case let .length(of: expr):
      return "\(expr).rank"
    case let .element(offset, of: expr):
      return "\(expr).shape[\(offset)]"
    case let .add(lhs, rhs):
      return "(\(lhs) + \(rhs))"
    case let .sub(lhs, rhs):
      return "(\(lhs) - \(rhs))"
    case let .mul(lhs, rhs):
      return "\(lhs) * \(rhs)"
    case let .div(lhs, rhs):
      return "\(lhs) / \(rhs)"
    }
  }
}

extension ListExpr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .var(v):
      return v.description
    case let .literal(subexprs):
      let subexprDesc = subexprs.map{ $0?.description ?? "*" }.joined(separator: ", ")
      return "[\(subexprDesc)]"
    case let .broadcast(lhs, rhs):
      return "broadcast(\(lhs), \(rhs))"
    }
  }
}

extension BoolExpr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .var(v):
      return v.description
    case let .and(subexprs):
      return subexprs.map{ "(\($0.description))" }.joined(separator: " and ")
    case let .intEq(lhs, rhs):
      return "\(lhs) = \(rhs)"
    case let .intGt(lhs, rhs):
      return "\(lhs) > \(rhs)"
    case let .intGe(lhs, rhs):
      return "\(lhs) >= \(rhs)"
    case let .intLt(lhs, rhs):
      return "\(lhs) < \(rhs)"
    case let .intLe(lhs, rhs):
      return "\(lhs) <= \(rhs)"
    case let .listEq(lhs, rhs):
      return "\(lhs) = \(rhs)"
    case let .boolEq(lhs, rhs):
      return "\(lhs) = \(rhs)"
    }
  }
}

extension Constraint: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .expr(expr):
      return expr.description
    case let .call(name, maybeArgs, maybeRet):
      let argsDesc = maybeArgs.map{ $0?.description ?? "*" }.joined(separator: ", ")
      if let ret = maybeRet {
        return "\(ret) = \(name)(\(argsDesc))"
      } else {
        return "\(name)(\(argsDesc))"
      }
    }
  }
}

extension Expr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .int(expr): return expr.description
    case let .list(expr): return expr.description
    case let .bool(expr): return expr.description
    }
  }
}
