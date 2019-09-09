import SIL

let arrayLiteralBuiltinName = "SHAPE_CHECKER_ARRAY_LITERAL"

// A helper data structure that holds def-use chains.
struct DefUse {
  let instrDefs: [InstructionDef]
  var uses = DefaultDict<Register, [Int]>{ _ in [] }

  init?(_ instrDefs: [InstructionDef]) {
    self.instrDefs = instrDefs
    for (i, instr) in instrDefs.enumerated() {
      // TODO: Warn
      guard let readList = instr.instruction.operandNames else { return nil }
      for register in Set(readList) {
        uses[register].append(i)
      }
    }
  }

  // INVARIANT: The defs might be duplicated, but always appear in the order
  //            in which they appeared as an argument to the init function.
  subscript(_ r: Register) -> [InstructionDef] {
    guard let uses = uses.lookup(r) else { return [] }
    return uses.map{ instrDefs[$0] }
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
func normalizeArrayLiterals(_ instrDefs: [InstructionDef]) -> [InstructionDef] {
  guard let uses = DefUse(instrDefs) else { return instrDefs }
  let literals = gatherLiterals(instrDefs)
  var replacedTuples: [Register: (Register, [Register], Type, Type)] = [:]

  return instrDefs.flatMap { (instrDef: InstructionDef) -> [InstructionDef] in
    switch instrDef.instruction {
    case let .apply(_, refRegister, _, args, _):
      // Make sure this is an apply that allocates an array and that its
      // size is known statically.
      guard literals[refRegister] == .allocateFuncRef,
            let tupleResult = instrDef.onlyResult,
            let sizeArg = args.only,
            case let .int(size) = literals[sizeArg] else { return [instrDef] }

      // Its only user should be a destructure_tuple instruction.
      guard let tupleDestruct = uses[tupleResult].only,
            case let .destructureTuple(tupleOperand) = tupleDestruct.instruction,
            let tupleOutputs = tupleDestruct.result?.valueNames,
            tupleOutputs.count == 2 else { return [instrDef] }
      let (arrayReg, basePtrReg) = (tupleOutputs[0], tupleOutputs[1])

      // FIXME: Handle empty literals

      // Which should be passed to pointer_to_address only.
      guard let pointerToAddress = uses[basePtrReg].only,
            case .pointerToAddress(_, _, _) = pointerToAddress.instruction,
            let baseAddress = pointerToAddress.onlyResult else { return [instrDef] }

      // The base pointer should be used once for each array element.
      let baseAddressUses = uses[baseAddress]
      guard baseAddressUses.count == size else { return [instrDef] }

      // NB: The following assumes that the elements are filled in order,
      //     which seems to hold in the generated code.
      var elements: [Register] = []

      // The first element is processed differently than all other, and
      // it's simply stored to the base address.
      guard case let .store(firstValue, _, _) = baseAddressUses[0].instruction else { return [instrDef] }
      elements.append(firstValue)


      var lastStoreAddr: Register = baseAddress
      for i in 1..<size {
        // All other elements have their address computed using an index_addr
        // instruction, and are stored through its result.
        let indexAddr = baseAddressUses[i]
        guard case let .indexAddr(_, index) = indexAddr.instruction,
              case .int(i) = literals[index.value],
              let addr = indexAddr.onlyResult,
              let store = uses[addr].only,
              case let .store(value, _, _) = store.instruction else { return [instrDef] }
        elements.append(value)
        lastStoreAddr = addr
      }

      guard case let .tupleType(tupleTypes) = tupleOperand.type,
            tupleTypes.count == 2 else { return [instrDef] }
      let arrayType = tupleTypes[0]
      guard case let .specializedType(.namedType("Array"), elementTypeList) = arrayType,
            let elementType = elementTypeList.only else { return [instrDef] }

      replacedTuples[lastStoreAddr] = (arrayReg, elements, arrayType, elementType)
      return [instrDef]
    case let .store(_, _, address):
      guard let (arrayReg, elements, arrayType, elementType) = replacedTuples[address.value] else { return [instrDef] }
      return [instrDef,
              InstructionDef(nil,
                             .builtin(arrayLiteralBuiltinName,
                               [Operand(arrayReg, arrayType)] + elements.map{ Operand($0, elementType) },
                               arrayType
                             ),
                             instrDef.sourceInfo)]

    default:
      return [instrDef]
    }
  }
}

func gatherLiterals(_ instrDefs: [InstructionDef]) -> [Register: ALAbstractValue] {
  let allocateUninitalizedArrayUSR = "$ss27_allocateUninitializedArrayySayxG_BptBwlF"
  var valuation: [Register: ALAbstractValue] = [:]

  for instrDef in instrDefs {
    switch instrDef.instruction {
    case let .integerLiteral(_, value):
      guard let resultReg = instrDef.onlyResult else { break }
      valuation[resultReg] = .int(value)
    case .functionRef(allocateUninitalizedArrayUSR, _):
      guard let resultReg = instrDef.onlyResult else { break }
      valuation[resultReg] = .allocateFuncRef
    default:
      break
    }
  }

  return valuation
}

fileprivate extension Array {
  var only: Element? { isEmpty ? nil : self[0] }
}

fileprivate extension InstructionDef {
  var onlyResult: Register? {
    guard result?.valueNames.count == 1 else { return nil }
    return result!.valueNames[0]
  }
}
