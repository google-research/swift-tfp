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

// PRECONDITION: induceReducibleCFG(blocks)
func findLoops(_ blocks: [Block]) -> [Loop] {
  let blocksByName = blocks.reduce(into: [BlockName: Block]()) {
    $0[$1.identifier] = $1
  }
  var predecessors = blocks.reduce(into: DefaultDict<BlockName, Set<BlockName>>{ _ in [] }) {
    for successor in $1.successors! {
      $0[successor].insert($1.identifier)
    }
  }
  var loops = DefaultDict<BlockName, Loop>{ header in Loop(header: header, body: []) }
  var context: [BlockName: Int] = [blocks[0].identifier: 0]
  var stack: [BlockName] = [blocks[0].identifier]

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

  while let topName = stack.last {
    let top = blocksByName[topName]!
    let successors = top.successors!
    let nextSuccessorIdx = context[top.identifier]!
    guard nextSuccessorIdx < successors.count else {
      context[topName] = nil
      let _ = stack.popLast()
      continue
    }
    context[top.identifier]! += 1
    let successor = successors[nextSuccessorIdx]
    if context.keys.contains(successor) {
      gatherPredecessors(of: topName, into: &loops[successor])
    } else {
      stack.append(successor)
      context[successor] = 0
    }
  }

  return loops.dictionary.values.sorted(by: { ($0.body.count, $0.header) < ($1.body.count, $1.header) })
}

// PRECONDITION: induceReducibleCFG(blocks)
func unloop(_ blocks: inout [Block]) {
  var loops = findLoops(blocks)
  guard !loops.isEmpty else { return }

  // TODO: Make this function more hygenic. It's fine if we assume that
  //       blocks follow the bbX convention, but this is not robust enough
  //       for the general case.
  let freshSuffix = count(from: 0) .>> { "_\($0)" }
  var blocksByName = blocks.reduce(into: [BlockName: Block]()) {
    $0[$1.identifier] = $1
  }
  func clone(_ blockName: BlockName, hint: String? = nil) -> Block {
    let oldBlock = blocksByName[blockName]!
    let name = blockName + (hint ?? "") + freshSuffix()
    let newBlock = Block(name,
                         oldBlock.arguments,
                         oldBlock.operatorDefs,
                         oldBlock.terminatorDef)
    blocksByName[name] = newBlock
    blocks.append(newBlock)
    return newBlock
  }

  func unreachable(like blockName: BlockName) -> BlockName {
    let oldBlock = blocksByName[blockName]!
    let name = blockName + "_unreachable"
    if blocksByName.keys.contains(name) {
      return name
    } else {
      let unreachableBlock =
        Block(name, oldBlock.arguments, [], TerminatorDef(.unreachable, nil))
      blocksByName[name] = unreachableBlock
      blocks.append(unreachableBlock)
      return name
    }
  }

  for loop in loops {
    let bodyClones = loop.body.sorted().reduce(into: [BlockName: Block]()) {
      $0[$1] = clone($1)
    }
    let entryPoints = blocksByName[loop.header]!.successors!.filter{ loop.body.contains($0) }

    var bridgeHeader = clone(loop.header, hint: "_bridge")
    // Rewrite the bridge header such that its arguments end up unused, while the original
    // values are produced by special builtins which tell us nothing about the value.
    bridgeHeader.operatorDefs.insert(
      contentsOf: bridgeHeader.arguments.map{
        OperatorDef(Result([$0.valueName]),
                    .builtin("anyInhabitant", [], $0.type),
                    nil) },
      at: 0)
    bridgeHeader.arguments = bridgeHeader.arguments.map{ Argument("%unused" + freshSuffix(), $0.type) }
    // There are two kinds of outgoing edges from the bridge block:
    //   - those that go into the loop are replaced to jump to the cloned body
    //   - those that would skip the loop are replaced with unreachable blocks
    //     (because we know that those paths are not taken).
    substitute(inside: &bridgeHeader, labels: {
      entryPoints.contains($0) ? bodyClones[$0]!.identifier : unreachable(like: $0)
    })
    // The first iteration of the loop should either exit or jump to the bridge header.
    loop.body.forEach {
      substitute(inside: &blocksByName[$0]!,
                 labels: { $0 == loop.header ? bridgeHeader.identifier : $0 })
    }

    var finalHeader = clone(loop.header, hint: "_final")
    // Final header always exits the loop, so the edges that go inside are unreachable.
    substitute(inside: &finalHeader, labels: {
      entryPoints.contains($0) ? unreachable(like: $0) : $0
    })
    bodyClones.values.forEach {
      substitute(inside: &blocksByName[$0.identifier]!,
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
}

func substitute(inside block: inout Block,
                labels labelSub: (BlockName) -> BlockName) {
  func replaceTerminator(_ terminator: Terminator) -> Terminator {
    switch terminator {
      case let .br(label, args):
        return .br(labelSub(label), args)
      case let .condBr(cond, trueLabel, trueArgs, falseLabel, falseArgs):
        return .condBr(cond,
                       labelSub(trueLabel), trueArgs,
                       labelSub(falseLabel), falseArgs)
      case let .switchEnum(operand, cases):
        return .switchEnum(operand, cases.map {
          switch $0 {
          case let .case(declRef, label): return .case(declRef, labelSub(label))
          case let .default(label): return .default(labelSub(label))
          }
        })
      case .return(_): fatalError("return should never be part of a loop")
      case .unreachable: fatalError("unreachable should never be part of a loop")
      case .unknown(_): fatalError("attempting to transform CFGs with unknown terminators")
    }
  }
  block.terminatorDef = TerminatorDef(replaceTerminator(block.terminatorDef.terminator),
                                      block.terminatorDef.sourceInfo)
}
