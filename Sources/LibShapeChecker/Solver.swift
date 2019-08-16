
typealias VarName = Int

// VarName + Type of the variable it refers to
enum TypedVarName: Hashable {
  case shape(_ name: VarName)
  case dim(_ name: VarName)
}

struct DimVar {
  let name: VarName
}

struct ShapeVar {
  let name: VarName
}

enum DimExpr {
  case variable(_ dim: DimVar)
  case literal(_ value: Int)
}

enum ShapeExpr {
  case variable(_ shape: ShapeVar)
  case literal(_ dims: [DimExpr])
}

enum Constraint {
  case shapeEqual(_ variable: ShapeVar, _ expr: ShapeExpr)
  case dimEqual(_ variable: DimVar, _ expr: DimExpr)
  case shapeMember(_ shape: ShapeVar, _ dim: DimVar, _ offset: Int)
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Substitution support

typealias Substitution = (TypedVarName) -> VarName

func substitute(_ v: DimVar, using s: Substitution) -> DimVar {
  return DimVar(name: s(.dim(v.name)))
}

func substitute(_ v: ShapeVar, using s: Substitution) -> ShapeVar {
  return ShapeVar(name: s(.shape(v.name)))
}

func substitute(_ e: DimExpr, using s: Substitution) -> DimExpr {
  switch e {
  case let .variable(v):
    return .variable(substitute(v, using: s))
  case let .literal(l):
    return .literal(l)
  }
}

func substitute(_ e: ShapeExpr, using s: Substitution) -> ShapeExpr {
  switch e {
  case let .variable(v):
    return .variable(substitute(v, using: s))
  case let .literal(l):
    return .literal(l.map{ substitute($0, using: s) })
  }
}

func substitute(_ c: Constraint, using s: Substitution) -> Constraint {
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
  var description: String { "d" + String(name) }
}

extension ShapeVar: CustomStringConvertible {
  var description: String { "s" + String(name) }
}

extension DimExpr: CustomStringConvertible {
  var description: String {
    switch self {
    case let .variable(v):
      return v.description
    case let .literal(value):
      return String(value)
    }
  }
}

extension ShapeExpr: CustomStringConvertible {
  var description: String {
    switch self {
    case let .variable(v):
      return v.description
    case let .literal(exprs):
      return "[" + exprs.map{ $0.description }.joined(separator: ", ") + "]"
    }
  }
}

extension Constraint: CustomStringConvertible {
  var description: String {
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
