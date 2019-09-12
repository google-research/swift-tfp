import SIL

typealias Register = String

enum BuiltinFunction {
  case assert

  case broadcast

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

  case shapeConstructor
  case rankGetter
  case shapeGetter
  case shapeSubscript
  case shapeEqual
}

func abstract(_ block: Block, inside typeEnvironment: TypeEnvironment) -> FunctionSummary? {
  guard block.instructionDefs.count > 0 else { fatalError("Empty block??") }
  let interpreter = Interpreter(block, typeEnvironment)
  let result: Register
  switch block.instructionDefs.last!.instruction {
  case let .return(operand):
    result = operand.value
  default:
    return nil
  }
  return FunctionSummary(argExprs: block.arguments.map { interpreter.valuation[$0.valueName]?.expr },
                         retExpr: interpreter.valuation[result]?.expr,
                         constraints: interpreter.constraints)
}

// This class is really a poor man's state monad
fileprivate class Interpreter {
  enum AbstractValue {
    case int(IntExpr)
    case list(ListExpr)
    case bool(BoolExpr)
    case tensor(withShape: ListVar)

    case holePointer
    case tuple([AbstractValue?])
    case function(_ name: String)
    case partialApplication(_ fnReg: Register, _ args: [Register], _ argTypes: [Type])

    var expr: Expr? {
      switch self {
      case let .int(expr): return .int(expr)
      case let .list(expr): return .list(expr)
      case let .bool(expr): return .bool(expr)
      case let .tuple(subexprs): return .compound(.tuple(subexprs.map{ $0?.expr }))
      case let .tensor(withShape: v): return .list(.var(v))
      default: return nil
      }
    }
  }

  var constraints: [RawConstraint] = []
  var valuation: [Register: AbstractValue] = [:]
  let freshName = count(from: 0)
  let typeEnvironment: TypeEnvironment

  func freshVar(_ type: Type) -> AbstractValue? {
    switch simplifyType(type) {
    case .namedType("Int"): return .int(.var(IntVar(freshName())))
    case .namedType("Bool"): return .bool(.var(freshBoolVar()))
    case .namedType("TensorShape"): return freshShapeValue()
    case let .tupleType(types): return .tuple(types.map(freshVar))
    case let .namedType(name):
      guard let fields = typeEnvironment[name] else { return nil }
      return .tuple(fields.map{ freshVar($0.type) })
    case let t where isTensorType(t): return freshTensorValue()
    default: return nil
    }
  }

  func freshTensorValue() -> AbstractValue {
    return .tensor(withShape: ListVar(freshName()))
  }

  func freshShapeValue() -> AbstractValue {
    return .list(.var(ListVar(freshName())))
  }

  func freshBoolVar() -> BoolVar {
    return BoolVar(freshName())
  }

  init(_ block: Block, _ typeEnvironment: TypeEnvironment) {
    self.typeEnvironment = typeEnvironment
    var instructions = block.instructionDefs.makeIterator()

    for argument in block.arguments {
      valuation[argument.valueName] = freshVar(argument.type)
    }

    while let instrDef = instructions.next() {
      var updates: [AbstractValue?]?

      switch instrDef.instruction {

      case let .beginBorrow(operand):
        fallthrough
      case let .copyValue(operand):
        guard instrDef.result?.valueNames.count == 1 else {
          fatalError("Expected a single result from an ownership instruction!")
        }
        // NB: It is important to make sure the result has the same valuation as
        //     the operand, because the following might happen:
        //
        //     %1 = unknown_instruction()
        //     %2 = copy_value %1
        //     %3 = f(%2)                 // This implies some constraints on %1
        //     %4 = copy_value %1
        //     %5 = g(%4)                 // This implies more constraints on %1
        //
        //     The constraints coming from f and g calls might be useful for our purposes.
        updates = [valuation[operand.value, setDefault: freshVar(operand.type)]]

      case let .integerLiteral(type, value):
        guard case .selectType(.namedType("Builtin"), "IntLiteral") = type else { continue }
        updates = [.int(.literal(value))]

      case let .builtin(name, operands, type):
        guard name == arrayLiteralBuiltinName,
              .specializedType(.namedType("Array"), [.namedType("Int")]) == type else { continue }
        guard let arrayReg = operands.first?.value else { continue }
        let elementExprs = operands[1...].map{ (operand: Operand) -> IntExpr? in
          guard case let .int(expr) = valuation[operand.value] else { return nil }
          return expr
        }
        valuation[arrayReg] = .list(.literal(elementExprs))

      case let .functionRef(name, _):
        updates = [.function(name)]

      case let .partialApply(_, _, fn, _, args, fnType):
        guard case let .functionType(allArgTypes, _) = simplifyType(fnType) else {
          fatalError("Expected a function type in .partialApply, got: \(fnType)")
        }
        assert(allArgTypes.count >= args.count)
        updates = [.partialApplication(fn, args, allArgTypes.suffix(args.count))]

      case let .convertEscapeToNoescape(_, _, operand, _): fallthrough
      case let .convertFunction(operand, _, _): fallthrough
      case let .thinToThickFunction(operand, _): fallthrough
      case let .markDependence(operand, _):
        updates = [valuation[operand.value]]

      case let .globalAddr(name, type):
        // TODO: Figure out a better way to ignore the module name of the
        //       mangled symbol.
        guard case .addressType(.namedType("Int")) = type,
              name.hasSuffix("4____Sivp") else { break }
        updates = [.holePointer]

      case let .load(_, operand):
        guard case .holePointer = valuation[operand.value] else { break }
        guard let loc = getLocation(instrDef) else { break }
        updates = [.int(.hole(loc))]

      // NB: Shape accessors are implemented as coroutines.
      case let .beginApply(_, appliedFnReg, _, appliedArgs, appliedFnType):
          // Eyeballing the generated code indicates that in the cases we care about
          // begin_apply should be followed immediately by an end_apply.
          guard case .endApply(_) = instructions.next()?.instruction else {
            break
          }
          fallthrough
      case let .apply(_, appliedFnReg, _, appliedArgs, appliedFnType):
        guard case let .functionType(appliedArgTypes, resultType) = simplifyType(appliedFnType) else {
          fatalError("Expected a function type in .apply, got: \(appliedFnType)")
        }
        guard let (name: name, args: bundleArgs, argTypes: bundleArgTypes) = resolveFunction(appliedFnReg) else {
          break
        }
        let args = appliedArgs + bundleArgs
        let argTypes = appliedArgTypes + bundleArgTypes

        if let kind = getBuiltinFunctionRef(called: name) {
          updates = interpret(builtinFunction: kind, args: args, at: getLocation(instrDef))
          break
        }
        guard let results = instrDef.result?.valueNames,
              results.count == 1 else {
          fatalError("Apply instruction with no results")
        }

        constraints.append(.call(name,
                                  zip(argTypes, args).map{ valuation[$0.1, setDefault: freshVar($0.0)]?.expr },
                                  valuation[results[0], setDefault: freshVar(resultType)]?.expr,
                                  getLocation(instrDef)))

      case let .struct(_, operands):
        updates = [.tuple(operands.map{ valuation[$0.value] })]

      case let .structExtract(operand, decl):
        if decl.name == ["Bool", "_value"] {
          updates = [valuation[operand.value]]
        }
        guard decl.name.count == 2 else { break }
        let (typeName, fieldName) = (decl.name[0], decl.name[1])
        guard let fields = typeEnvironment[typeName],
              let fieldOffset = fields.firstIndex(where: { $0.name == fieldName }),
              case let .tuple(values) = valuation[operand.value],
              fieldOffset < values.count else { break }
        updates = [values[fieldOffset]]

      case let .tuple(elements):
        switch elements {
        case let .labeled(_, registers): updates = [.tuple(registers.map{ valuation[$0] })]
        case let .unlabeled(operands): updates = [.tuple(operands.map{ valuation[$0.value] })]
        }

      case let .destructureTuple(operand):
        guard case let .tuple(values) = valuation[operand.value] else { break }
        updates = values

      case let .tupleExtract(operand, offset):
        guard case let .tuple(values) = valuation[operand.value],
              offset < values.count else { break }
        updates = [values[offset]]

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

  func interpret(builtinFunction kind: BuiltinFunction, args: [Register], at loc: SourceLocation?) -> [AbstractValue?]? {
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
      return binaryOp(trailingCount: 1) { .bool(.intLt($0, $1)) }

    case .intSmallerEqual:
      return binaryOp(trailingCount: 1) { .bool(.intLe($0, $1)) }

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

    case .shapeConstructor:
      guard args.count == 2 else {
        fatalError("Shape constructor expected two arguments")
      }
      return [valuation[args[0]]]

    case .shapeGetter:
      guard args.count == 1 else {
        fatalError("Shape getter expected a single argument!")
      }
      guard case let .tensor(withShape: shapeVar) =
          valuation[args[0], setDefault: freshTensorValue()] else { return nil }
      return [.list(.var(shapeVar))]

    case .rankGetter:
      guard args.count == 1 else {
        fatalError("Rank getter expected a single argument!")
      }
      guard case let .tensor(withShape: shapeVar) =
          valuation[args[0], setDefault: freshTensorValue()] else { return nil }
      return [.int(.length(of: .var(shapeVar)))]

    case .shapeSubscript:
      guard args.count == 2 else {
        fatalError("Shape subscript expected two arguments")
      }
      let values = args.map{ valuation[$0] }
      // NB: We only support constant indices into shapes for now, but
      //     there's no fundamental reason why we couldn't generalize it.
      guard case let .int(.literal(dim)) = values[0] else { return nil }
      guard case let .list(shape) = values[1] else { return nil }
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

    case .assert:
      guard args.count == 4 else {
        fatalError("Assert expects four arguments")
      }
      guard let (name: name, args: args, argTypes: argTypes) = resolveFunction(args[0]) else {
        warn("Failed to find the asserted condition", loc)
        return nil
      }
      let condVar = freshBoolVar()
      constraints.append(.call(name,
                               zip(argTypes, args).map{ valuation[$0.1, setDefault: freshVar($0.0)]?.expr },
                               .bool(.var(condVar)),
                               loc))
      constraints.append(.expr(.var(condVar), loc))
      return nil

    case .broadcast:
      guard args.count == 2 else { return nil }
      guard case let .list(lhs) = valuation[args[0]],
            case let .list(rhs) = valuation[args[1]] else { return nil }
      return [.list(.broadcast(lhs, rhs))]
    }
  }

  func resolveFunction(_ baseFnReg: Register) -> (name: String, args: [Register], argTypes: [Type])? {
    guard valuation[baseFnReg] != nil else { return nil }
    var fnReg = baseFnReg
    var args: [Register] = []
    var argTypes: [Type] = []
    while case let .partialApplication(appliedFnReg, appliedArgs, appliedArgTypes) = valuation[fnReg] {
      fnReg = appliedFnReg
      args += appliedArgs
      argTypes += appliedArgTypes
    }
    guard case let .function(fnName) = valuation[fnReg] else {
      fatalError("Expected a function value!")
    }
    return (fnName, args, argTypes)
  }
}

func getLocation(_ instrDef: InstructionDef) -> SourceLocation? {
  return instrDef.sourceInfo?.loc.map{ .file($0.path, line: $0.line) }
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
    case "$ss6assert__4file4lineySbyXK_SSyXKs12StaticStringVSutF":
      return .assert
    case "$s10TensorFlow0A5ShapeV12arrayLiteralACSid_tcfC":
      return .shapeConstructor
    case "$s10TensorFlow0A0V5shapeAA0A5ShapeVvg":
      return .shapeGetter
    case "$s10TensorFlow0A5ShapeVyS2icir":
      return .shapeSubscript
    case "$s10TensorFlow0A0V4rankSivg":
      return .rankGetter
    case "$s10TensorFlow0A5ShapeV2eeoiySbAC_ACtFZ":
      return .shapeEqual
    case "broadcast":
      return .broadcast
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

fileprivate func simplifyType(_ type: Type) -> Type {
  switch type {
  case let .attributedType(_, t): return simplifyType(t)
  case let .genericType(_, _, t): return simplifyType(t)
  case let .withOwnership(_, subtype): return simplifyType(subtype)
  default: return type
  }
}

fileprivate extension Dictionary {
  subscript(key: Key, setDefault defaultValue: @autoclosure () -> Value?) -> Value? {
    mutating get {
      if let value = self[key] {
        return value
      } else {
        self[key] = defaultValue()
        return self[key]
      }
    }
  }
}
