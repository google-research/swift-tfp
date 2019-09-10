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

public indirect enum IntExpr: Hashable, ExpressibleByIntegerLiteral {
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

  public init(integerLiteral lit: Int) {
    self = .literal(lit)
  }
}

public indirect enum ListExpr: Hashable {
  case `var`(ListVar)
  case literal([IntExpr?])
  case broadcast(ListExpr, ListExpr)
}

public indirect enum BoolExpr: Hashable {
  case `var`(BoolVar)
  case and([BoolExpr])
  case intEq(IntExpr, IntExpr)
  case intGt(IntExpr, IntExpr)
  case intGe(IntExpr, IntExpr)
  case intLt(IntExpr, IntExpr)
  case intLe(IntExpr, IntExpr)
  case listEq(ListExpr, ListExpr)
  case boolEq(BoolExpr, BoolExpr)
  // NB: No compound cases for the sake of type safety and
  //     because all compound expressions should get desugared
  //     during call resolution.
}

public enum CompoundExpr: Hashable {
  case tuple([Expr?])
}

public enum Expr: Hashable {
  case int(IntExpr)
  case list(ListExpr)
  case bool(BoolExpr)
  case compound(CompoundExpr)
}

public indirect enum SourceLocation: Hashable {
  case unknown
  case file(_ path: String, line: Int, parent: SourceLocation?)

  func withParent(_ newParent: SourceLocation?) -> SourceLocation {
    switch self {
    case .unknown: return .unknown
    case let .file(path, line: l, parent: _): return .file(path, line: l, parent: newParent)
    }
  }

  var stack: [SourceLocation] {
    switch self {
    case .unknown: return []
    case let .file(_, line: _, parent: parent):
      return (parent?.stack ?? []) + [self]
    }
  }
}

// NB: If a constraint is implied then the source location points
//     to the source location of the expression it was inferred from.
public enum ConstraintOrigin: Hashable {
    case asserted
    case implied
}

public enum Constraint: Hashable {
  case expr(BoolExpr, ConstraintOrigin, SourceLocation)
  // Calls could theoretically be expressed by something like
  // .resultTypeEq(result, .resultTypeCall(name, args))
  // However, there are valid Exprs (e.g. involving compound types)
  // which are not expressible by BoolExprs and this is a way of
  // ensuring that we desugar those before validation happens.
  case call(_ name: String, _ args: [Expr?], _ result: Expr?, SourceLocation)

  func withLocation(_ loc: SourceLocation) -> Constraint {
    switch self {
    case let .expr(expr, origin, _): return .expr(expr, origin, loc)
    case let .call(name, args, result, _): return .call(name, args, result, loc)
    }
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

public func substitute(_ e: CompoundExpr, using s: Substitution) -> CompoundExpr {
  switch e {
  case let .tuple(subexprs):
    return .tuple(subexprs.map{ $0.map{ substitute($0, using: s) } })
  }
}

public func substitute(_ c: Constraint, using s: Substitution) -> Constraint {
  switch c {
  case let .expr(expr, origin, loc):
    return .expr(substitute(expr, using: s), origin, loc)
  case let .call(name, args, result, loc):
    return .call(name,
                 args.map{ $0.map{ substitute($0, using: s) } },
                 result.map{ substitute($0, using: s) },
                 loc)
  }
}

public func substitute(_ e: Expr, using s: Substitution) -> Expr {
  switch e {
  case let .int(expr): return .int(substitute(expr, using: s))
  case let .list(expr): return .list(substitute(expr, using: s))
  case let .bool(expr): return .bool(substitute(expr, using: s))
  case let .compound(expr): return .compound(substitute(expr, using: s))
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Generic equality operator

infix operator ≡: ComparisonPrecedence

func ≡(_ a: Expr, _ b: Expr) -> [BoolExpr] {
  switch (a, b) {
  case let (.int(a), .int(b)): return [.intEq(a, b)]
  case let (.list(a), .list(b)): return [.listEq(a, b)]
  case let (.bool(a), .bool(b)): return [.boolEq(a, b)]
  case let (.compound(a), .compound(b)):
    switch (a, b) {
    case let (.tuple(aExprs), .tuple(bExprs)):
      guard aExprs.count == bExprs.count else {
        fatalError("Equating incompatible tuple expressions")
      }
      return zip(aExprs, bExprs).flatMap {
        (t: (Expr?, Expr?)) -> [BoolExpr] in
        guard let aExpr = t.0, let bExpr = t.1 else { return [] }
        return aExpr ≡ bExpr
      }
    }
  default: fatalError("Equating expressions of different types!")
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
      return "rank(\(expr))"
    case let .element(offset, of: expr):
      return "\(expr)[\(offset)]"
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

extension CompoundExpr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .tuple(subexprs):
      return "(" + subexprs.map{ $0?.description ?? "*" }.joined(separator: ", ") + ")"
    }
  }
}

extension Constraint: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .expr(expr, _, _):
      return expr.description
    case let .call(name, maybeArgs, maybeRet, _):
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
    case let .compound(expr): return expr.description
    }
  }
}

extension SourceLocation: CustomStringConvertible {
  public var description: String {
    switch self {
    case .unknown: return "an unknown location"
    case let .file(path, line: line, parent: _): return "\(path):\(line)"
    }
  }
}
