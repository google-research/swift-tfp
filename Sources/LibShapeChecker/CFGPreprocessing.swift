import SIL

typealias BlockName = String

extension Block {
  var successors : [BlockName]? {
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
  var numVertices = blocks.count
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
    assert(numVertices > 0)
    toReduce.removeFirst()
    guard let parent = predecessors[block].only else {
      fatalError("Collapsing a block with multiple predecessors")
    }
    successors[parent].remove(block)
    successors[parent].formUnion(successors[block])
    successors[parent].remove(parent)
    for successor in successors[block] {
      predecessors[successor].remove(block)
      if successor != parent {
        predecessors[successor].insert(parent)
      }
      if predecessors[successor].count == 1, successor != startBlock {
        toReduce.insert(successor)
      }
    }
    successors.remove(block)
    predecessors.remove(block)
    numVertices -= 1
  }


  return numVertices == 1
}

struct Loop: Equatable {
  let header: BlockName
  var body: Set<BlockName> // NB: Doesn't include the header!

  init(header: BlockName, body: Set<BlockName>) {
    self.header = header
    self.body = body
  }
}

// PRECONDITION: induceReducibleCFG(blocks)
func findLoops(_ blocks: [Block]) -> [Loop]? {
  var blocksByName = blocks.reduce(into: [BlockName: Block]()) {
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
