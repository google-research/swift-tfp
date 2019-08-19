import SIL

func abstract(constraints: [FrontendConstraint],
              overSignature sig: (arguments: [Register?], result: Register?),
              inEnvironment env: Environment) -> FunctionSummary {
  let parser = ConstraintParser()
  parser.parse(constraints, env)
  return FunctionSummary(argVars: sig.arguments.map{ $0.flatMap{ parser.shapeVars[$0] } },
                         retVar: sig.result.flatMap{ parser.shapeVars[$0] },
                         constraints: parser.constraints)
}

fileprivate class ConstraintParser {

  struct DimIndex : Hashable {
    let register: Register
    let offset: Int

    init(_ offset: Int, of reg: Register) {
      self.offset = offset
      self.register = reg
    }
  }

  enum Error : Swift.Error {
    case unsupportedKind(_ constraint: Value)
    case negativeDimLiteral(_ constraint: Value)
  }

  var constraints: [Constraint] = []

  let nextShapeVarName = count(from: 1)
  var shapeVars: DefaultDict<Register, ShapeVar>!
  func lookupShape(of reg: Register) -> ShapeVar {
    return shapeVars[reg]
  }

  let nextDimVarName = count(from: 1)
  var dimVars: DefaultDict<DimIndex, DimVar>!
  func lookupDim(_ offset: Int, of reg: Register) -> DimVar {
    return dimVars[DimIndex(offset, of: reg)]
  }

  init() {
    self.shapeVars = DefaultDict<Register, ShapeVar>{ [weak self] _ in
      return ShapeVar(name: self!.nextShapeVarName())
    }
    self.dimVars = DefaultDict<DimIndex, DimVar>{ [weak self] dimIdx in
      let dimVar = DimVar(name: self!.nextDimVarName())
      let shapeVar = self!.lookupShape(of: dimIdx.register)
      self!.constraints.append(.shapeMember(shapeVar, dimVar, dimIdx.offset))
      return dimVar
    }
  }

  func parse(_ blockConstraints: [FrontendConstraint], _ environment: Environment) {
    for constraint in blockConstraints {
      do {
        switch constraint {
        case let .value(val):
          try parseValueConstraint(val)
        case let .apply(name, result, args):
          parseApplyConstraint(name, result, args, environment)
        }
      } catch {}
    }
  }

  func parseValueConstraint(_ constraint: Value, trySwapping: Bool = true) throws {
    // The only value-derived constraints we support right now are equality constraints.
    guard case let .equals(lhs, rhs) = constraint else {
      throw Error.unsupportedKind(constraint)
    }
    switch lhs {
    // x.rank == 2
    // FIXME: The current encoding has no easy way of representing rank equality!
    case let .rank(of: register):
      guard case let .int(rank) = rhs else {
        throw Error.unsupportedKind(constraint)
      }
      guard rank >= 0 else {
        throw Error.negativeDimLiteral(constraint)
      }
      let shapeExpr = ShapeExpr.literal((0..<rank).map{ .variable(lookupDim(Int($0), of: register)) })
      constraints.append(.shapeEqual(lookupShape(of: register), shapeExpr))

    // x.shape == y.shape
    case let .shape(of: lhsRegister):
      guard case let .shape(of: rhsRegister) = rhs else {
        throw Error.unsupportedKind(constraint)
      }
      let lhsVar = lookupShape(of: lhsRegister)
      let rhsVar = lookupShape(of: rhsRegister)
      constraints.append(.shapeEqual(lhsVar, .variable(rhsVar)))

    // x.shape[0] == 2
    // x.shape[0] == y.shape[1]
    case let .dim(lhsOffset, of: lhsRegister):
      let lhsVar = lookupDim(lhsOffset, of: lhsRegister)
      let rhsExpr: DimExpr
      switch rhs {
      case let .int(value):
        guard value >= 0 else {
          throw Error.negativeDimLiteral(constraint)
        }
        rhsExpr = .literal(Int(value))
      case let .dim(rhsOffset, of: rhsRegister):
        rhsExpr = .variable(lookupDim(rhsOffset, of: rhsRegister))
      default:
        throw Error.unsupportedKind(constraint)
      }
      constraints.append(.dimEqual(lhsVar, rhsExpr))

    default:
      if trySwapping {
        // NB: We don't want to throw from inside the swapped invocation, becase the
        // errors might indicate that the equation looked differently.
        do {
          try parseValueConstraint(.equals(rhs, lhs), trySwapping: false)
          return
        } catch {}
      }
      throw Error.unsupportedKind(constraint)
    }
  }

  func parseApplyConstraint(_ name: String,
                            _ result: Register,
                            _ args: [Register],
                            _ summaries: Environment) {
    guard let summary = summaries[name] else { return }

    // Instantiate the constraint system for the callee, by:
    var substitution = DefaultDict<TypedVarName, VarName>{
      switch $0 {
      case .dim(_): return self.nextDimVarName()
      case .shape(_): return self.nextShapeVarName()
      }
    }

    // 1. Substituting the formal argument variables for the actual variables.
    assert(summary.argVars.count == args.count)
    for (maybeArg, argReg) in zip(summary.argVars, args) {
      // NB: Only instantiate the mapping for args that have some constraints
      //     associated with them.
      guard maybeArg != nil else { continue }
      let argName = lookupShape(of: argReg).name
      substitution[.shape(argName)] = argName
    }

    // 2. Replacing the variables in the body of the summary with fresh versions.
    constraints += summary.constraints.map{ substitute($0, using: { substitution[$0] }) }

    // 3. Linking the shape variable of the result register to the formal result.
    if let genericRetVar = summary.retVar {
      shapeVars[result] = substitute(genericRetVar, using: { substitution[$0] })
    }
  }
}

