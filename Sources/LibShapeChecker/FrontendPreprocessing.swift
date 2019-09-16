import SIL

let arrayLiteralBuiltinName = "SHAPE_CHECKER_ARRAY_LITERAL"

// A helper data structure that holds def-use chains.
struct DefUse {
  let operatorDefs: [OperatorDef]
  var uses = DefaultDict<Register, [Int]>{ _ in [] }

  init?(_ operatorDefs: [OperatorDef]) {
    self.operatorDefs = operatorDefs
    for (i, operatorDef) in operatorDefs.enumerated() {
      guard let readList = operatorDef.operator.operandNames else {
        warn("Failed to analyze instruction \(operatorDef.operator)", getLocation(operatorDef))
        return nil
      }
      for register in Set(readList) {
        uses[register].append(i)
      }
    }
  }

  // INVARIANT: The defs might be duplicated, but always appear in the order
  //            in which they appeared as an argument to the init function.
  subscript(_ r: Register) -> [OperatorDef] {
    guard let uses = uses.lookup(r) else { return [] }
    return uses.map{ operatorDefs[$0] }
  }
}

enum ALAbstractValue: Equatable {
  case int(Int)
  case allocateFuncRef
}

// The SIL code used to allocate arrays is quite involved and requires
// analyzing the heap. Instead of piling all of this complexity on the
// frontend, we preprocess the sequence of instructions and try to
// annotate code patterns looking like literal allocation with a single
// instruction that informs the frontend about the array elements.
func normalizeArrayLiterals(_ operatorDefs: [OperatorDef]) -> [OperatorDef] {
  let (literals, usesArrayAllocation) = gatherLiterals(operatorDefs)
  guard usesArrayAllocation else { return operatorDefs }
  guard let uses = DefUse(operatorDefs) else { return operatorDefs }
  var replacedTuples: [Register: (Register, [Register], Type, Type)] = [:]

  return operatorDefs.flatMap { (operatorDef: OperatorDef) -> [OperatorDef] in
    switch operatorDef.operator {
    case let .apply(_, refRegister, _, args, _):
      // Make sure this is an apply that allocates an array and that its
      // size is known statically.
      guard literals[refRegister] == .allocateFuncRef,
            let tupleResult = operatorDef.onlyResult,
            let sizeArg = args.only,
            case let .int(size) = literals[sizeArg] else { return [operatorDef] }

      var tupleOutputs: [Register] = []
      var tupleOperand: Operand!
      let tupleUsers = uses[tupleResult]
      if let tupleDestruct = tupleUsers.only,
         case let .destructureTuple(tupleOperand_) = tupleDestruct.operator {
        tupleOutputs = tupleDestruct.result?.valueNames ?? []
        tupleOperand = tupleOperand_
      } else if tupleUsers.count == 2,
                case let .tupleExtract(tupleOperand_, 0) = tupleUsers[0].operator,
                case     .tupleExtract(_, 1) = tupleUsers[1].operator {
        tupleOutputs = tupleUsers.compactMap{ $0.result?.valueNames.only }
        tupleOperand = tupleOperand_
      }
      guard tupleOutputs.count == 2 else { return [operatorDef] }
      let (arrayReg, basePtrReg) = (tupleOutputs[0], tupleOutputs[1])

      // FIXME: Handle empty literals

      // Which should be passed to pointer_to_address only.
      guard let pointerToAddress = uses[basePtrReg].only,
            case .pointerToAddress(_, _, _) = pointerToAddress.operator,
            let baseAddress = pointerToAddress.onlyResult else { return [operatorDef] }

      // The base pointer should be used once for each array element.
      let baseAddressUses = uses[baseAddress]
      guard baseAddressUses.count == size else { return [operatorDef] }

      // NB: The following assumes that the elements are filled in order,
      //     which seems to hold in the generated code.
      var elements: [Register] = []

      // The first element is processed differently than all other, and
      // it's simply stored to the base address.
      guard case let .store(firstValue, _, _) = baseAddressUses[0].operator else { return [operatorDef] }
      elements.append(firstValue)


      var lastStoreAddr: Register = baseAddress
      for i in 1..<size {
        // All other elements have their address computed using an index_addr
        // instruction, and are stored through its result.
        let indexAddr = baseAddressUses[i]
        guard case let .indexAddr(_, index) = indexAddr.operator,
              case .int(i) = literals[index.value],
              let addr = indexAddr.onlyResult,
              let store = uses[addr].only,
              case let .store(value, _, _) = store.operator else { return [operatorDef] }
        elements.append(value)
        lastStoreAddr = addr
      }

      guard case let .tupleType(tupleTypes) = tupleOperand.type,
            tupleTypes.count == 2 else { return [operatorDef] }
      let arrayType = tupleTypes[0]
      guard case let .specializedType(.namedType("Array"), elementTypeList) = arrayType,
            let elementType = elementTypeList.only else { return [operatorDef] }

      replacedTuples[lastStoreAddr] = (arrayReg, elements, arrayType, elementType)
      return [operatorDef]
    case let .store(_, _, address):
      guard let (arrayReg, elements, arrayType, elementType) = replacedTuples[address.value] else { return [operatorDef] }
      return [operatorDef,
              OperatorDef(nil,
                          .builtin(arrayLiteralBuiltinName,
                            [Operand(arrayReg, arrayType)] + elements.map{ Operand($0, elementType) },
                            arrayType
                          ),
                          operatorDef.sourceInfo)]

    default:
      return [operatorDef]
    }
  }
}

func gatherLiterals(_ operatorDefs: [OperatorDef]) -> ([Register: ALAbstractValue], Bool) {
  let allocateUninitalizedArrayUSR = "$ss27_allocateUninitializedArrayySayxG_BptBwlF"
  var valuation: [Register: ALAbstractValue] = [:]
  var usesArrayAllocation = false

  for operatorDef in operatorDefs {
    switch operatorDef.operator {
    case let .integerLiteral(_, value):
      guard let resultReg = operatorDef.onlyResult else { break }
      valuation[resultReg] = .int(value)
    case .functionRef(allocateUninitalizedArrayUSR, _):
      guard let resultReg = operatorDef.onlyResult else { break }
      usesArrayAllocation = true
      valuation[resultReg] = .allocateFuncRef
    default:
      break
    }
  }

  return (valuation, usesArrayAllocation)
}

fileprivate extension OperatorDef {
  var onlyResult: Register? {
    guard result?.valueNames.count == 1 else { return nil }
    return result!.valueNames[0]
  }
}
