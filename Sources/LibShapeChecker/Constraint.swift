public typealias VarName = Int

public struct Var: Hashable {
  let name: VarName
  init(_ name: VarName) { self.name = name }
}

public indirect enum IntExpr: Equatable {
  // NB: No variables on this level. All integral qualities are derived from
  //     list expressions for now.
  case literal(Int)
  case length(of: ListExpr)
  // TODO: Accept int expressions instead of literals only?
  // FIXME: Verify that this is a positive expression, because our
  //        current encoding does not play well with negative dim indices.
  case element(Int, of: ListExpr)

  case add(IntExpr, IntExpr)
}

public indirect enum ListExpr: Equatable {
  case `var`(Var)
}

public enum BoolExpr: Equatable {
  case intEq(IntExpr, IntExpr)
  case intGt(IntExpr, IntExpr)
  case listEq(ListExpr, ListExpr)
}

public enum Constraint: Equatable {
  case expr(BoolExpr)
  case call(_ name: String, _ args: [Var?], _ result: Var?)
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Substitution support

public typealias Substitution = (Var) -> Var

public func substitute(_ v: Var, using s: Substitution) -> Var {
  return s(v)
}

public func substitute(_ e: IntExpr, using s: Substitution) -> IntExpr {
  switch e {
  case let .literal(v):
    return .literal(v)
  case let .length(of: expr):
    return .length(of: substitute(expr, using: s))
  case let .element(offset, of: expr):
    return .element(offset, of: substitute(expr, using: s))
  case let .add(lhs, rhs):
    return .add(substitute(lhs, using: s), substitute(rhs, using: s))
  }
}

public func substitute(_ e: ListExpr, using s: Substitution) -> ListExpr {
  switch e {
  case let .var(v):
    return .var(substitute(v, using: s))
  }
}

public func substitute(_ e: BoolExpr, using s: Substitution) -> BoolExpr {
  switch e {
  case let .intEq(lhs, rhs):
    return .intEq(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .intGt(lhs, rhs):
    return .intGt(substitute(lhs, using: s), substitute(rhs, using: s))
  case let .listEq(lhs, rhs):
    return .listEq(substitute(lhs, using: s), substitute(rhs, using: s))
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

////////////////////////////////////////////////////////////////////////////////
// MARK: - CustomStringConvertible instances

extension Var: CustomStringConvertible {
  public var description: String { "s" + String(name) }
}

extension IntExpr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .literal(v):
      return String(v)
    case let .length(of: expr):
      return "\(expr).rank"
    case let .element(offset, of: expr):
      return "\(expr).shape[\(offset)]"
    case let .add(lhs, rhs):
      return "\(lhs) + \(rhs)"
    }
  }
}

extension ListExpr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .var(v):
      return v.description
    }
  }
}

extension BoolExpr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .intEq(lhs, rhs):
      return "\(lhs) == \(rhs)"
    case let .intGt(lhs, rhs):
      return "\(lhs) > \(rhs)"
    case let .listEq(lhs, rhs):
      return "\(lhs) == \(rhs)"
    }
  }
}

extension Optional: CustomStringConvertible where Wrapped == Var {
  public var description: String { self == nil ? "*" : self!.description }
}

extension Constraint: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .expr(expr):
      return expr.description
    case let .call(name, maybeArgs, maybeRet):
      let argsDesc = maybeArgs.map{ $0.description }.joined(separator: ", ")
      if let ret = maybeRet {
        return "\(ret) = \(name)(\(argsDesc))"
      } else {
        return "\(name)(\(argsDesc))"
      }
    }
  }
}
