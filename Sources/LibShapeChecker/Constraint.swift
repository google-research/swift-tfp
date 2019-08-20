public typealias VarName = Int

// VarName + Type of the variable it refers to
public enum TypedVarName: Hashable {
  case shape(_ name: VarName)
  case dim(_ name: VarName)
}

public struct DimVar: Hashable {
  let name: VarName
}

public struct ShapeVar: Hashable {
  let name: VarName
}

public enum DimExpr {
  case variable(_ dim: DimVar)
  case literal(_ value: Int)
}

public enum ShapeExpr {
  case variable(_ shape: ShapeVar)
  case literal(_ dims: [DimExpr])
}

public enum Constraint {
  case shapeEqual(_ variable: ShapeVar, _ expr: ShapeExpr)
  case dimEqual(_ variable: DimVar, _ expr: DimExpr)
  case shapeMember(_ shape: ShapeVar, _ dim: DimVar, _ offset: Int)
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Substitution support

public typealias Substitution = (TypedVarName) -> VarName

public func substitute(_ v: DimVar, using s: Substitution) -> DimVar {
  return DimVar(name: s(.dim(v.name)))
}

public func substitute(_ v: ShapeVar, using s: Substitution) -> ShapeVar {
  return ShapeVar(name: s(.shape(v.name)))
}

public func substitute(_ e: DimExpr, using s: Substitution) -> DimExpr {
  switch e {
  case let .variable(v):
    return .variable(substitute(v, using: s))
  case let .literal(l):
    return .literal(l)
  }
}

public func substitute(_ e: ShapeExpr, using s: Substitution) -> ShapeExpr {
  switch e {
  case let .variable(v):
    return .variable(substitute(v, using: s))
  case let .literal(l):
    return .literal(l.map{ substitute($0, using: s) })
  }
}

public func substitute(_ c: Constraint, using s: Substitution) -> Constraint {
  switch c {
  case let .shapeEqual(v, e):
    return .shapeEqual(substitute(v, using: s), substitute(e, using: s))
  case let .dimEqual(v, e):
    return .dimEqual(substitute(v, using: s), substitute(e, using: s))
  case let .shapeMember(sv, dv, o):
    return .shapeMember(substitute(sv, using: s), substitute(dv, using: s), o)
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - CustomStringConvertible instances

extension DimVar: CustomStringConvertible {
  public var description: String { "d" + String(name) }
}

extension ShapeVar: CustomStringConvertible {
  public var description: String { "s" + String(name) }
}

extension DimExpr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .variable(v):
      return v.description
    case let .literal(value):
      return String(value)
    }
  }
}

extension ShapeExpr: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .variable(v):
      return v.description
    case let .literal(exprs):
      return "[" + exprs.map{ $0.description }.joined(separator: ", ") + "]"
    }
  }
}

extension Constraint: CustomStringConvertible {
  public var description: String {
    switch self {
    case let .shapeEqual(v, expr):
      return "\(v) = \(expr)"
    case let .dimEqual(v, expr):
      return "\(v) = \(expr)"
    case let .shapeMember(sv, dv, offset):
      return "\(sv)[\(offset)] = \(dv)"
    }
  }
}
