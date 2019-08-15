
struct DimVar {
  let name: Int
}

struct ShapeVar {
  let name: Int
}

enum ShapeExpr {
  case variable(_ shape: ShapeVar)
  case literal(_ dims: [DimExpr])
}

enum DimExpr {
  case variable(_ dim: DimVar)
  case literal(_ value: Int)
}

enum Constraint {
  case shapeEqual(_ variable: ShapeVar, _ expr: ShapeExpr)
  case dimEqual(_ variable: DimVar, _ expr: DimExpr)
  case shapeMember(_ shape: ShapeVar, _ dim: DimVar, _ offset: Int)
}
