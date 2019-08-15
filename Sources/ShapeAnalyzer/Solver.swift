
struct DimVar {
  let name: Int
}

struct ShapeVar {
  let name: Int
}

enum ShapeExpr {
  case shape(_ shape: ShapeVar)
  case literal(_ dims: [DimExpr])
}

enum DimExpr {
  case dim(_ dim: DimVar)
  case literal(_ value: Int)
}

enum Constraint {
  case rankEqual(_ shape: ShapeVar, _ rank: Int)
  case shapeEqual(_ variable: ShapeVar, _ expr: ShapeExpr)
  case dimEqual(_ variable: DimVar, _ expr: DimExpr)
  case shapeMember(_ shape: ShapeVar, _ dim: DimVar, _ offset: Int)
}
