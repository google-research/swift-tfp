import SIL

typealias BlockName = String

extension Block {
  var successors: [BlockName]? {
    switch terminatorDef.terminator {
    case .return(_): return []
    case let .br(label, _): return [label]
    case let .condBr(_, trueLabel, _, falseLabel, _): return [trueLabel, falseLabel]
    case let .switchEnum(_, cases):
      return cases.map {
        switch $0 {
        case let .case(_, label): return label
        case let .default(label): return label
        }
      }
    case .unreachable: return []
    case .unknown(_): return nil
    }
  }
}

// NB: This is terribly inefficient from a theoretical point of view,
//     but it's simple and it works. Our CFGs are unlikely to be huge anyway.
func induceReducibleCFG(_ blocks: [Block]) -> Bool? {
  var predecessors = DefaultDict<BlockName, Set<BlockName>>{ _ in [] }
  var successors = DefaultDict<BlockName, Set<BlockName>>{ _ in [] }
  var blocksRemaining = blocks.count
  var toReduce = Set<BlockName>()
  let startBlock = blocks[0].identifier

  for block in blocks {
    guard let blockSuccessors = block.successors else { return nil }
    for successor in blockSuccessors {
      guard successor != block.identifier else { continue }
      predecessors[successor].insert(block.identifier)
      successors[block.identifier].insert(successor)
    }
  }

  for block in blocks {
    if predecessors[block.identifier].count == 1,
       block.identifier != startBlock {
      toReduce.insert(block.identifier)
    }
  }

  while let block = toReduce.first {
    assert(blocksRemaining > 0)
    toReduce.removeFirst()
    guard let parent = predecessors[block].only else {
      fatalError("Collapsing a block with multiple predecessors")
    }
    successors[parent].remove(block)
    successors[parent].formUnion(successors[block])
    successors[parent].remove(parent)
    for successor in successors[block] {
      predecessors[successor].remove(block)
      // Avoid introducing self-loops
      if successor != parent {
        predecessors[successor].insert(parent)
      }
      if predecessors[successor].count == 1, successor != startBlock {
        toReduce.insert(successor)
      }
    }
    successors.remove(block)
    predecessors.remove(block)
    blocksRemaining -= 1
  }


  return blocksRemaining == 1
}

class Loop {
  let header: BlockName
  var body: Set<BlockName> // NB: Doesn't include the header!

  init(header: BlockName, body: Set<BlockName>) {
    self.header = header
    self.body = body
  }
}

fileprivate func forEach(
    _ cfg: [Block],
    inDepthFirstOrder f: (Block) -> (),
    onBackEdge: (((source: BlockName, ancestor: BlockName)) -> ())? = nil) {
  let blocksByName = cfg.reduce(into: [BlockName: Block]()) {
    $0[$1.identifier] = $1
  }
  var context: [BlockName: Int] = [cfg[0].identifier: 0]
  var stack: [BlockName] = [cfg[0].identifier]
  while let currentName = stack.last {
    let top = blocksByName[currentName]!
    let successors = top.successors!
    let nextSuccessorIdx = context[top.identifier]!
    guard nextSuccessorIdx < successors.count else {
      context[currentName] = nil
      let _ = stack.popLast()
      continue
    }
    context[top.identifier]! += 1
    let successor = successors[nextSuccessorIdx]
    f(blocksByName[currentName]!)
    if context.keys.contains(successor) {
      if let callback = onBackEdge {
        callback((currentName, successor))
      }
    } else {
      stack.append(successor)
      context[successor] = 0
    }
  }
}

// PRECONDITION: induceReducibleCFG(blocks)
func findLoops(_ blocks: [Block]) -> [Loop] {
  var predecessors = blocks.reduce(into: DefaultDict<BlockName, Set<BlockName>>{ _ in [] }) {
    for successor in $1.successors! {
      $0[successor].insert($1.identifier)
    }
  }

  func gatherPredecessors(of bottom: BlockName, into loop: inout Loop) {
    var toFollow = [bottom]
    while let next = toFollow.popLast() {
      loop.body.insert(next)
      for predecessor in predecessors[next] {
        guard predecessor != loop.header,
              !loop.body.contains(predecessor) else { continue }
        toFollow.append(predecessor)
      }
    }
  }

  var loops = DefaultDict<BlockName, Loop>{ header in Loop(header: header, body: []) }
  forEach(blocks,
          inDepthFirstOrder: { _ in return () },
          onBackEdge: { gatherPredecessors(of: $0.source, into: &loops[$0.ancestor]) })

  return loops.dictionary.values.sorted(by: { ($0.body.count, $0.header) < ($1.body.count, $1.header) })
}

// PRECONDITION: induceReducibleCFG(blocks)
func unloop(_ blocks: inout [Block]) {
  // TODO: Make this function more hygenic. It's fine if we assume that
  //       blocks follow the bbX convention and values are always %X, but
  //       this is not robust enough for the general case. I guess we could
  //       just alpha-normalize the inputs.
  let freshSuffix = count(from: 0) .>> String.init

  guard relaxedUnloop(&blocks, suffixGenerator: freshSuffix) else { return }

  // The CFG is now acyclic, so we can sort it.
  blocks = topoSort(blocks)

  // The transformation we've applied unfortunately breaks some of the
  // assumptions SSA makes, because the blocks have been duplicated with
  // little regard for register names. The two issues that may arise are that:
  // 1. Registers may be assigned to multiple times
  // 2. Blocks reachable only through loop bodies, but not belonging to the
  //    bodies (e.g. the branches where asserts fail fall into thie category)
  //    might have only had a single entry point and didn't need block arguments,
  //    while they might be called from multiple places now (which may be passing
  //    in different values, but they also don't have to <ugh>!).
  //
  // By adding explicit block arguments for all values that are defined inside
  // the block we deal with issue 2. In particular the CFG will never use the fact
  // that registers defined in some blocks are visible in all their dominatees.
  var missingValues = DefaultDict<BlockName, [Operand]>{ _ in [] }
  for var block in blocks.reversed() {
    let blockName = block.identifier
    var missingLocally: [Register: Type] = [:]
    var definedRegisters = Set<Register>()
    for arg in block.arguments {
      definedRegisters.insert(arg.valueName)
    }

    // Go over the block body
    for op in block.operatorDefs {
      let read = op.operator.operands ?? []
      for readReg in read {
        if !definedRegisters.contains(readReg.value) {
          missingLocally[readReg.value] = readReg.type
        }
      }

      let written = op.result?.valueNames ?? []
      definedRegisters.formUnion(written)
    }

    // Fix up the calls to successors to include the arguments they were missing
    replace(inside: &block, jumps: { successor, _, arguments in
      return (successor, arguments + missingValues[successor])
    })
    // Finally, check which registers are read by the terminator, but have not
    // been defined. Note that it is important that this happens after we fix
    // the calls to successors, because this loop will also consider all of
    // their additional arguments.
    for readReg in block.terminatorDef.terminator.operands! {
      if !definedRegisters.contains(readReg.value) {
        missingLocally[readReg.value] = readReg.type
      }
    }

    missingValues[blockName] = missingLocally.map{ Operand($0.key, $0.value) }.sorted(by: { $0.value < $1.value })
    block.arguments += missingValues[blockName].map{ Argument($0.value, $0.type) }
  }

  // Finally, we solve issue 1. by renaming all variables in the cloned blocks.
  // Note that this renaming code is valid only because each block only refers
  // to values that were defined inside it.
  blocks = blocks.map {
    var replacements = DefaultDict<Register, Register>{ orig in "\(orig)_\(freshSuffix())" }
    return $0.alphaConverted(using: { replacements[$0] })
  }
}

// NB: It's relaxed becase the modifications to blocks do not produce a valid
//     SSA control-flow grpah. This is why consumers should use unloop instead.
func relaxedUnloop(_ blocks: inout [Block],
                   suffixGenerator freshSuffix: () -> String = count(from: 0) .>> String.init) -> Bool {
  var loops = findLoops(blocks)
  guard !loops.isEmpty else { return false }

  var blocksByName = blocks.reduce(into: [BlockName: Block]()) {
    $0[$1.identifier] = $1
  }

  func clone(_ oldName: BlockName, suffix: String? = nil) -> Block {
    let oldBlock = blocksByName[oldName]!
    let newName = oldName + "_" + (suffix ?? freshSuffix())
    let newBlock = Block(newName, oldBlock.arguments, oldBlock.operatorDefs, oldBlock.terminatorDef)
    blocksByName[newName] = newBlock
    blocks.append(newBlock)
    return newBlock
  }

  func unreachable(like oldName: BlockName) -> BlockName {
    let oldBlock = blocksByName[oldName]!
    let newName = oldName + "_unreachable"
    if !blocksByName.keys.contains(newName) {
      let unreachableBlock = Block(newName, oldBlock.arguments,
                                   [], TerminatorDef(.unreachable, nil))
      blocksByName[newName] = unreachableBlock
      blocks.append(unreachableBlock)
    }
    return newName
  }

  for loop in loops {
    let bodyClones = loop.body.sorted().reduce(into: [BlockName: Block]()) {
      $0[$1] = clone($1)
    }
    let entryPoints = blocksByName[loop.header]!.successors!.filter{ loop.body.contains($0) }

    var bridgeHeader = clone(loop.header, suffix: "bridge")
    // Rewrite the bridge header such that its arguments end up unused, while the original
    // values are produced by special builtins which tell us nothing about the value.
    bridgeHeader.operatorDefs.insert(
      contentsOf: bridgeHeader.arguments.map{
        OperatorDef(Result([$0.valueName]),
                    .builtin("anyInhabitant", [], $0.type),
                    nil) },
      at: 0)
    bridgeHeader.arguments = bridgeHeader.arguments.map{ Argument("%unused_" + freshSuffix(), $0.type) }
    // There are two kinds of outgoing edges from the bridge block:
    //   - those that go into the loop are replaced to jump to the cloned body
    //   - those that would skip the loop are replaced with unreachable blocks
    //     (because we know that those paths are not taken).
    replace(inside: &bridgeHeader, labels: {
      entryPoints.contains($0) ? bodyClones[$0]!.identifier : unreachable(like: $0)
    })
    // The first iteration of the loop should either exit or jump to the bridge header.
    loop.body.forEach {
      replace(inside: &blocksByName[$0]!,
              labels: { $0 == loop.header ? bridgeHeader.identifier : $0 })
    }

    var finalHeader = clone(loop.header, suffix: "final")
    // Final header always exits the loop, so the edges that go inside are unreachable.
    replace(inside: &finalHeader, labels: {
      entryPoints.contains($0) ? unreachable(like: $0) : $0
    })
    bodyClones.values.forEach {
      replace(inside: &blocksByName[$0.identifier]!,
              labels: {
        if $0 == loop.header {
          // The clones should always jump to the final header instead of the original one.
          return finalHeader.identifier
        } else if loop.body.contains($0) {
          // All jumps that stay inside the body should point to other clones.
          return bodyClones[$0]!.identifier
        } else {
          // But all exits should stay untouched.
          return $0
        }
      })
    }

    // Add the newly created blocks to each loop that contains this header
    // (i.e. to all the outer loop of this one).
    for otherLoop in loops {
      guard otherLoop.header != loop.header,
            otherLoop.body.contains(loop.header) else { continue }
      otherLoop.body.formUnion(bodyClones.values.map{ $0.identifier })
      otherLoop.body.insert(bridgeHeader.identifier)
      otherLoop.body.insert(finalHeader.identifier)
    }
  }

  return true
}

enum ImplicitArgument {
  case none
  case switchedEnum
}

// TODO: Adding extra arguments to edges outgoing form a switchEnum instruction
//       requires adding a temporary block which will get the unpacked argument
func replace(inside block: inout Block,
             jumps jumpSub: (BlockName, ImplicitArgument, [Operand]) -> (BlockName, [Operand])) {
  func replaceTerminator(_ terminator: Terminator) -> Terminator {
    switch terminator {
      case let .br(label, args):
        let (newLabel, newArgs) = jumpSub(label, .none, args)
        return .br(newLabel, newArgs)
      case let .condBr(cond, trueLabel, trueArgs, falseLabel, falseArgs):
        let (newTrueLabel, newTrueArgs) = jumpSub(trueLabel, .none, trueArgs)
        let (newFalseLabel, newFalseArgs) = jumpSub(falseLabel, .none, falseArgs)
        return .condBr(cond, newTrueLabel, newTrueArgs, newFalseLabel, newFalseArgs)
      case let .switchEnum(operand, cases):
        return .switchEnum(operand, cases.map {
          switch $0 {
          case let .case(declRef, label):
            let (newLabel, extraArgs) = jumpSub(label, .switchedEnum, [])
            guard extraArgs.isEmpty else { fatalError("NYI: Replacement requires insertion of a trampoline block!") }
            return .case(declRef, newLabel)
          case let .default(label):
            let (newLabel, extraArgs) = jumpSub(label, .switchedEnum, [])
            guard extraArgs.isEmpty else { fatalError("NYI: Replacement requires insertion of a trampoline block!") }
            return .default(newLabel)
          }
        })
      case .return(_): return terminator
      case .unreachable: return terminator
      case .unknown(_): fatalError("attempting to transform CFGs with unknown terminators")
    }
  }
  block.terminatorDef = TerminatorDef(replaceTerminator(block.terminatorDef.terminator),
                                      block.terminatorDef.sourceInfo)
}

func replace(inside block: inout Block,
                labels labelSub: (BlockName) -> BlockName) {
  return replace(inside: &block, jumps: { (labelSub($0), $2) })
}

// PRECONDITION: cfg is acyclic, and cfg[0] is the entry block
// POSTCONDITION: topoSort(cfg)[0] == cfg[0]
func topoSort(_ cfg: [Block]) -> [Block] {
  guard let entryBlock = cfg.first else { return cfg }

  let blocksByName = cfg.reduce(into: [BlockName: Block]()) {
    $0[$1.identifier] = $1
  }
  var dependencies = DefaultDict<BlockName, Int>{ _ in 0 }
  for block in cfg {
    for succ in block.successors! {
      dependencies[succ] += 1
    }
  }

  // Make sure that there's only one entry block to this cfg (otherwise the
  // algorithm below is incorrect).
  assert(dependencies[entryBlock.identifier] == 0)
  for block in cfg {
    assert(block.identifier == entryBlock.identifier || dependencies[block.identifier] > 0)
  }

  var ordered: [Block] = []
  var ready = [entryBlock]
  while let block = ready.popLast() {
    ordered.append(block)
    for succ in block.successors!.reversed() {
      dependencies[succ] -= 1
      if dependencies[succ] == 0 {
        ready.append(blocksByName[succ]!)
      }
    }
  }
  assert(ordered.count == cfg.count)

  return ordered
}
