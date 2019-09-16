@testable import LibShapeChecker
import SIL
import XCTest

let returnInstr = Terminator.return(Operand("", .namedType("")))

final class CFGPreprocessingTests: XCTestCase {

  let irreducible: [Block] = [
    Block("bb0", .condBr("", "bb1", [], "bb2", [])),
    Block("bb1", .condBr("", "bb2", [], "bb3", [])),
    Block("bb2", .condBr("", "bb1", [], "bb3", [])),
    Block("bb3", returnInstr),
  ]

  let chain: [Block] = [
    Block("bb0", .br("bb1", [])),
    Block("bb1", .br("bb2", [])),
    Block("bb2", .br("bb3", [])),
    Block("bb3", .br("bb4", [])),
    Block("bb4", returnInstr),
  ]

  let ifDiamond: [Block] = [
    Block("bb0", .condBr("", "bb1", [], "bb2", [])),
    Block("bb1", .br("bb3", [])),
    Block("bb2", .br("bb3", [])),
    Block("bb3", returnInstr),
  ]

  let simpleLoop: [Block] = [
    Block("bb0", .br("bb1", [])),
    Block("bb1", .condBr("", "bb2", [], "bb3", [])),
    Block("bb2", .br("bb1", [])),
    Block("bb3", returnInstr),
  ]

  let loopWithIf: [Block] = [
    Block("bb0", .br("bb1", [])),
    Block("bb1", .condBr("", "bb2", [], "bb6", [])),
    Block("bb2", .condBr("", "bb3", [], "bb4", [])),
    Block("bb3", .br("bb5", [])),
    Block("bb4", .br("bb5", [])),
    Block("bb5", .br("bb1", [])),
    Block("bb6", returnInstr),
  ]

  let loopWithTwoBackEdges: [Block] = [
    Block("bb0", .br("bb1", [])),
    Block("bb1", .condBr("", "bb2", [], "bb5", [])),
    Block("bb2", .condBr("", "bb3", [], "bb4", [])),
    Block("bb3", .br("bb1", [])),
    Block("bb4", .br("bb1", [])),
    Block("bb5", returnInstr),
  ]

  let nestedLoop: [Block] = [
    Block("bb0", .br("bb1", [])),
    Block("bb1", .condBr("", "bb2", [], "bb5", [])),
    Block("bb2", .condBr("", "bb3", [], "bb4", [])),
    Block("bb3", .br("bb2", [])),
    Block("bb4", .br("bb1", [])),
    Block("bb5", returnInstr),
  ]

  func testInducesReducibleCFG() {
    XCTAssertEqual(induceReducibleCFG(irreducible), false)
    XCTAssertEqual(induceReducibleCFG(chain), true)
    XCTAssertEqual(induceReducibleCFG(ifDiamond), true)
    XCTAssertEqual(induceReducibleCFG(simpleLoop), true)
    XCTAssertEqual(induceReducibleCFG(loopWithIf), true)
    XCTAssertEqual(induceReducibleCFG(loopWithTwoBackEdges), true)
    XCTAssertEqual(induceReducibleCFG(nestedLoop), true)
  }

  func testFindLoops() {
    XCTAssertEqual(findLoops(chain), [])
    XCTAssertEqual(findLoops(ifDiamond), [])
    XCTAssertEqual(findLoops(simpleLoop), [Loop(header: "bb1", body: ["bb2"])])
    XCTAssertEqual(findLoops(loopWithIf), [Loop(header: "bb1",
                                                body: ["bb2", "bb3", "bb4", "bb5"])])
    XCTAssertEqual(findLoops(loopWithTwoBackEdges), [Loop(header: "bb1",
                                                          body: ["bb2", "bb3", "bb4"])])
    XCTAssertEqual(findLoops(nestedLoop), [Loop(header: "bb2", body: ["bb3"]),
                                           Loop(header: "bb1",
                                                body: ["bb2", "bb3", "bb4"])])
  }

  static var allTests = [
    ("testInducesReducibleCFG", testInducesReducibleCFG),
  ]
}

fileprivate extension Block {
  convenience init(_ name: String, _ terminator: Terminator) {
    self.init(name, [], [], TerminatorDef(terminator, nil))
  }
}
