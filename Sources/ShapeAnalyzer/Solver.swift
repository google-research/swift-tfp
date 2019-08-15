
struct DimVar {
  let name: Int
}

struct ShapeVar {
  let name: Int
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
