import SIL

typealias Register = String

enum BuiltinFunction {
  case check

  case intLiteralConstructor
  case intEqual
  case intGreater
  case intGreaterEqual
  case intSmaller
  case intSmallerEqual
  case intPlus
  case intMinus
  case intMultiply
  case intDivide

  case rankGetter
  case shapeGetter
  case shapeSubscript
  case shapeEqual
}

func abstract(_ block: Block) -> FunctionSummary? {
  guard block.instructionDefs.count > 0 else { fatalError("Empty block??") }
  let interpreter = Interpreter(block)
  let result: Register
  switch block.instructionDefs.last!.instruction {
  case let .return(operand):
    result = operand.value
  default:
    return nil
  }
  let lookupVar = { interpreter.variables.lookup($0) }
  return FunctionSummary(argVars: block.arguments.map{ lookupVar($0.valueName) },
                         retVar: lookupVar(result),
                         constraints: interpreter.constraints)
}

// This class is really a poor man's state monad
fileprivate class Interpreter {
  indirect enum AbstractValue {
    case int(IntExpr)
    case list(ListExpr)
    case bool(BoolExpr)
    case tupleIntBool(IntExpr)

    case builtinFunction(_ kind: BuiltinFunction)
    case function(_ name: String)
  }

  var constraints: [Constraint] = []
  var variables: DefaultDict<Register, Var>!
  var valuation: [Register: AbstractValue] = [:]
  var instructions: Array<InstructionDef>.Iterator
  let nextVar = count(from: 0) >>> Var.init

  init(_ block: Block) {
    self.instructions = block.instructionDefs.makeIterator()
    self.variables = DefaultDict{ [weak self] _ in self!.nextVar() }
    process(block)
  }

  func process(_ block: Block) {
    while let instrDef = instructions.next() {
      var updates: [AbstractValue?]?

      switch instrDef.instruction {

      case let .beginBorrow(operand):
        fallthrough
      case let .copyValue(operand):
        guard instrDef.result?.valueNames.count == 1 else {
          fatalError("Expected a single result from an ownership instruction!")
        }
        // Propagate the valuation and unify the shape variables
        updates = [valuation[operand.value]]
        let resultReg = instrDef.result!.valueNames[0]
        if let operandVar = variables.lookup(operand.value) {
          variables[resultReg] = operandVar
        }

      case let .integerLiteral(type, value):
        guard case .selectType(.namedType("Builtin"), "IntLiteral") = type else { continue }
        updates = [.int(.literal(value))]

      case let .functionRef(name, _):
        if let builtin = getBuiltinFunctionRef(called: name) {
          updates = [.builtinFunction(builtin)]
        } else {
          updates = [.function(name)]
        }

      // NB: Shape accessors are implemented as coroutines.
      case let .beginApply(_, fn, _, args, fnType):
          // Eyeballing the generated code indicates that in the cases we care about
          // begin_apply should be followed immediately by an end_apply.
          guard case .endApply(_) = instructions.next()?.instruction else {
            break
          }
          fallthrough
      case let .apply(_, fn, _, args, fnType):
        switch valuation[fn] {
        case let .function(name):
          guard let results = instrDef.result?.valueNames else {
            fatalError("Apply instruction with no results")
          }
          guard results.count == 1 else {
            fatalError("Apply instruction with multiple results")
          }
          let result = results[0]

          guard case let .functionType(_, resultType) = unwrapFunctionType(fnType) else {
            fatalError("Expected a function type, got: \(fnType)")
          }
          constraints.append(.call(name,
                                   args.map(variables.lookup),
                                   isTensorType(resultType) ? variables[result] : nil))
        case let .builtinFunction(kind):
          updates = interpret(builtinFunction: kind, args: args)
        case nil:
          break
        default:
          fatalError("Calling a non-function value")
        }

      case let .struct(type, operands):
        guard case let .namedType(typeName) = type,
              ["Bool", "Int"].contains(typeName) else { continue }
        updates = operands.map { valuation[$0.value] }

      case let .structExtract(operand, decl):
        switch decl.name {
        case ["Int", "_value"]:
          updates = [valuation[operand.value]]
        default:
          break
        }

      case let .tupleExtract(operand, decl):
        guard case let .tupleIntBool(fst) = valuation[operand.value] else { continue }
        guard decl == 0 else { continue }
        updates = [.int(fst)]

      default:
        break
      }

      guard let results = updates else { continue }
      let resultNames = (instrDef.result?.valueNames) ?? []
      guard results.count == resultNames.count else {
        fatalError("Expected a different number of returns")
      }
      for (name, value) in zip(resultNames, results) {
        valuation[name] = value
      }
    }
  }

  func interpret(builtinFunction kind: BuiltinFunction, args: [Register]) -> [AbstractValue?]? {
    func binaryOp(trailingCount: Int = 0, _ f: (IntExpr, IntExpr) -> AbstractValue) -> [AbstractValue?]? {
      let values = args.compactMap{ valuation[$0] }
      let expectedArgs = trailingCount + 2
      guard args.count == expectedArgs && values.count >= 2 else { return nil }
      guard case let .int(lhs) = values[0] else { return nil }
      guard case let .int(rhs) = values[1] else { return nil }
      return [f(lhs, rhs)]
    }

    switch kind {
    case .intEqual:
      return binaryOp(trailingCount: 1) { .bool(.intEq($0, $1)) }

    case .intGreater:
      return binaryOp(trailingCount: 1) { .bool(.intGt($0, $1)) }

    case .intGreaterEqual:
      return binaryOp(trailingCount: 1) { .bool(.intGe($0, $1)) }

    case .intSmaller:
      return binaryOp(trailingCount: 1) { .bool(.not(.intGe($0, $1))) }

    case .intSmallerEqual:
      return binaryOp(trailingCount: 1) { .bool(.not(.intGt($0, $1))) }

    case .intPlus:
      return binaryOp(trailingCount: 1) { .int(.add($0, $1)) }

    case .intMinus:
      return binaryOp(trailingCount: 1) { .int(.sub($0, $1)) }

    case .intMultiply:
      return binaryOp(trailingCount: 1) { .int(.mul($0, $1)) }

    case .intDivide:
      return binaryOp(trailingCount: 1) { .int(.div($0, $1)) }

    case .intLiteralConstructor:
      guard args.count == 2 else {
        fatalError("Int constructor expected two arguments")
      }
      return [valuation[args[0]]]

    case .shapeGetter:
      guard args.count == 1 else {
        fatalError("Shape getter expected a single argument!")
      }
      return [.list(.var(variables[args[0]]))]

    case .rankGetter:
      guard args.count == 1 else {
        fatalError("Rank getter expected a single argument!")
      }
      return [.int(.length(of: .var(variables[args[0]])))]

    case .shapeSubscript:
      guard args.count == 2 else {
        fatalError("Shape subscript expected two arguments")
      }
      let values = args.map{ valuation[$0] }
      // NB: We only support constant indices into shapes for now, but
      //     there's no fundamental reason why we couldn't generalize it.
      guard case let .int(.literal(dim)) = values[0] else { return nil }
      guard case let .list(shape) = values[1] else { return nil }
      // We add a rank constraint that makes this lookup well defined
      constraints.append(.expr(.intGt(.length(of: shape), .literal(dim))))
      // NB: We need to have two returns, because the second one is a coroutine token
      return [.int(.element(dim, of: shape)), nil]

    case .shapeEqual:
      // NB: Third argument is the metatype
      guard args.count == 3 else {
        fatalError("Shape equality expected three arguments")
      }
      let values = args.compactMap{ valuation[$0] }
      guard values.count == 2 else { return nil }
      guard case let .list(a) = values[0],
            case let .list(b) = values[1] else {
        fatalError("Expected shape arguments to shape equality operator!")
      }
      return [.bool(.listEq(a, b))]

    case .check:
      guard args.count == 1 else {
        fatalError("Check expects a single argument")
      }
      if case let .bool(cond) = valuation[args[0]] {
        constraints.append(.expr(cond))
      } else {
        // TODO: Turn into a proper log/warning
        print("Failed to recover a check!")
      }
      return nil
    }
  }
}

fileprivate func getBuiltinFunctionRef(called name: String) -> BuiltinFunction? {
  switch name {
    case "$sSi2eeoiySbSi_SitFZ":
      return .intEqual
    case "$sSi1goiySbSi_SitFZ":
      return .intGreater
    case "$sSi2geoiySbSi_SitFZ":
      return .intGreaterEqual
    case "$sSi1loiySbSi_SitFZ":
      return .intSmaller
    case "$sSi2leoiySbSi_SitFZ":
      return .intSmallerEqual
    case "$sSi1poiyS2i_SitFZ":
      return .intPlus
    case "$sSi1soiyS2i_SitFZ":
      return .intMinus
    case "$sSi1moiyS2i_SitFZ":
      return .intMultiply
    case "$sSi1doiyS2i_SitFZ":
      return .intDivide
    case "$sSi22_builtinIntegerLiteralSiBI_tcfC":
      return .intLiteralConstructor
    case "check":
      return .check
    case "$s10TensorFlow0A0V5shapeAA0A5ShapeVvg":
      return .shapeGetter
    case "$s10TensorFlow0A5ShapeVyS2icir":
      return .shapeSubscript
    case "$s10TensorFlow0A0V4rankSivg":
      return .rankGetter
    case "$s10TensorFlow0A5ShapeV2eeoiySbAC_ACtFZ":
      return .shapeEqual
    default:
      return nil
  }
}

fileprivate func isTensorType(_ type: Type) -> Bool {
  switch type {
  case let .attributedType(_, t): return isTensorType(t)
  case .specializedType(.namedType("Tensor"), _): return true
  default: return false
  }
}

fileprivate func unwrapFunctionType(_ type: Type) -> Type? {
  switch type {
  case let .attributedType(_, t):
    return unwrapFunctionType(t)
  case let .genericType(_, _, t):
    return unwrapFunctionType(t)
  case .functionType(_, _):
    return type
  default:
    return nil
  }
}
