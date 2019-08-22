import SIL

typealias Register = String

enum BuiltinFunction {
  case check
  case rankGetter
  case shapeGetter
  case shapeSubscript
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
      case let .integerLiteral(type, value):
        guard case let .selectType(baseType, elem) = type,
              case let .namedType(builtin) = baseType,
              builtin == "Builtin", isIntType(elem) else { continue }
        updates = [.int(.literal(value))]

      case let .builtin(name, args, _):
        updates = interpret(builtinInstruction: name,
                            values: args.map{ valuation[$0.value] })

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

  func interpret(builtinInstruction op: String, values: [AbstractValue?]) -> [AbstractValue]? {
    switch op {
    case "cmp_eq_Int64":
      let inputs = values.compactMap{ $0 }
      guard values.count == 2 && inputs.count == 2 else { return nil }
      guard case let .int(lhs) = values[0] else { return nil }
      guard case let .int(rhs) = values[1] else { return nil }
      return [.bool(.intEq(lhs, rhs))]
    default:
      return nil
    }
  }

  func interpret(builtinFunction kind: BuiltinFunction, args: [Register]) -> [AbstractValue?]? {
    switch kind {
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

fileprivate func isIntType(_ name: String) -> Bool {
  return ["Int1", "Int16", "Int32", "Int64", "Word"].contains(name)
}

fileprivate func getBuiltinFunctionRef(called name: String) -> BuiltinFunction? {
  switch name {
    case "check":
      return .check
    case "$s10TensorFlow0A0V5shapeAA0A5ShapeVvg":
      return .shapeGetter
    case "$s10TensorFlow0A5ShapeVyS2icir":
      return .shapeSubscript
    case "$s10TensorFlow0A0V4rankSivg":
      return .rankGetter
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
