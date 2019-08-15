import SIL

struct FunctionSummary {
  // NB: Can be nil if the argument or return is not a tensor,
  //     or wasn't used in any constraint.
  let argVars: [ShapeVar?]
  let retVar: ShapeVar?
  let constraints: [Constraint]
}

struct Analyzer {

  func analyze(module: Module) {
    for f in module.functions {
      analyze(function: f)
    }
  }

  func analyze(function: Function) {
    guard function.blocks.count == 1 else { return }
    print("\n\n")
    print("Analyzing " + function.name)
    analyze(block: function.blocks[0])
  }

  func analyze(block: Block) {
    guard block.instructionDefs.count > 0 else { fatalError("Empty block??") }
    let constraints = gatherConstraints(block: block)
    let result: Operand
    switch block.instructionDefs.last!.instruction {
    case let .return(operand):
      result = operand
    default:
      return
    }
    let summary = parse(constraints,
                        arguments: block.arguments,
                        result: result)
    print(summary)
  }
}

enum ConstraintParseError : Error {
  case unsupportedKind(_ constraint: Value)
  case negativeDimLiteral(_ constraint: Value)
}

struct DimSpec : Hashable {
  let reg: Register
  let offset: Int
}

func parse(_ constraintValues: [Value], arguments: [Argument], result: Operand) -> FunctionSummary {
  var constraints: [Constraint] = []
  var shapeVars: [Register: ShapeVar] = [:]
  var dimVars: [DimSpec: DimVar] = [:]

  // TODO: Make those into objects
  var sc = 0
  func freshShapeVar() -> ShapeVar { sc += 1; return ShapeVar(name: sc) }
  func lookupShape(of reg: Register) -> ShapeVar {
    return shapeVars[reg, default: freshShapeVar()]
  }

  var dc = 0
  func freshDimVar(_ offset: Int, of reg: Register) -> DimVar {
    dc += 1
    let dv = DimVar(name: dc)
    constraints.append(.shapeMember(lookupShape(of: reg), dv, offset))
    return dv
  }
  func lookupDim(_ offset: Int, of reg: Register) -> DimVar {
    return dimVars[DimSpec(reg: reg, offset: offset), default: freshDimVar(offset, of: reg)]
  }

  func parseEqualityConstraint(_ constraint: Value, trySwapping: Bool = true) throws {
    guard case let .equals(lhs, rhs) = constraint else {
      throw ConstraintParseError.unsupportedKind(constraint)
    }
    switch lhs {
    // x.rank == 2
    case let .rank(of: register):
      guard case let .int(rank) = rhs else {
        throw ConstraintParseError.unsupportedKind(constraint)
      }
      guard rank >= 0 else {
        throw ConstraintParseError.negativeDimLiteral(constraint)
      }
      let shapeExpr = ShapeExpr.literal((0..<rank).map{ .dim(lookupDim(Int($0), of: register)) })
      constraints.append(.shapeEqual(lookupShape(of: register), shapeExpr))

    // x.shape == y.shape
    case let .shape(of: lhsRegister):
      guard case let .shape(of: rhsRegister) = rhs else {
        throw ConstraintParseError.unsupportedKind(constraint)
      }
      let lhsVar = lookupShape(of: lhsRegister)
      let rhsVar = lookupShape(of: rhsRegister)
      constraints.append(.shapeEqual(lhsVar, .shape(rhsVar)))

    // x.shape[0] == 2
    // x.shape[0] == y.shape[1]
    case let .dim(lhsOffset, of: lhsRegister):
      let lhsVar = lookupDim(lhsOffset, of: lhsRegister)
      let rhsExpr: DimExpr
      switch rhs {
      case let .int(value):
        guard value >= 0 else {
          throw ConstraintParseError.negativeDimLiteral(constraint)
        }
        rhsExpr = .literal(Int(value))
      case let .dim(rhsOffset, of: rhsRegister):
        rhsExpr = .dim(lookupDim(rhsOffset, of: rhsRegister))
      default:
        throw ConstraintParseError.unsupportedKind(constraint)
      }
      constraints.append(.dimEqual(lhsVar, rhsExpr))

    default:
      if trySwapping {
        // NB: We don't want to throw from inside the swapped invocation, becase the
        // errors might indicate that the equation looked differently.
        do {
          try parseEqualityConstraint(.equals(rhs, lhs), trySwapping: false)
          return
        } catch {}
      }
      throw ConstraintParseError.unsupportedKind(constraint)
    }
  }

  for constraint in constraintValues {
    do {
      try parseEqualityConstraint(constraint)
    } catch {}
  }

  func isTensorType(_ type: Type) -> Bool {
    // TODO: fix once Type supports Equatable
    switch type {
    case .namedType("Tensor"): return true
    default: return false
    }
  }

  return FunctionSummary(argVars: arguments.map{ isTensorType($0.type) ? lookupShape(of: $0.valueName) : nil },
                         retVar: isTensorType(result.type) ? lookupShape(of: result.value) : nil,
                         constraints: constraints)
}
