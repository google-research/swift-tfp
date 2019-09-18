@testable import LibShapeChecker
import SIL
import XCTest

let returnInstr = Terminator.return(Operand("", .namedType("")))

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

let dag: [Block] = [
  Block("bb0", .condBr("", "bb1", [], "bb2", [])),
  Block("bb1", .condBr("", "bb3", [], "bb4", [])),
  Block("bb2", .condBr("", "bb3", [], "bb4", [])),
  Block("bb3", .br("bb6", [])),
  Block("bb4", .condBr("", "bb5", [], "bb6", [])),
  Block("bb5", .br("bb6", [])),
  Block("bb6", returnInstr),
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

let DAGExamples: [[Block]] = [
  chain,
  ifDiamond,
  dag,
]

let reducibleExamples: [[Block]] = DAGExamples + [
  simpleLoop,
  loopWithIf,
  loopWithTwoBackEdges,
  nestedLoop,
]

final class CFGPreprocessingTests: XCTestCase {
  func testInducesReducibleCFG() {
    XCTAssertEqual(induceReducibleCFG(irreducible), false)
    for cfg in reducibleExamples {
      XCTAssertEqual(induceReducibleCFG(cfg), true)
    }
  }

  func testFindLoops() {
    XCTAssertEqual(findLoops(chain), [])
    XCTAssertEqual(findLoops(ifDiamond), [])
    XCTAssertEqual(findLoops(dag), [])
    XCTAssertEqual(findLoops(simpleLoop), [Loop(header: "bb1", body: ["bb2"])])
    XCTAssertEqual(findLoops(loopWithIf), [Loop(header: "bb1",
                                                body: ["bb2", "bb3", "bb4", "bb5"])])
    XCTAssertEqual(findLoops(loopWithTwoBackEdges), [Loop(header: "bb1",
                                                          body: ["bb2", "bb3", "bb4"])])
    XCTAssertEqual(findLoops(nestedLoop), [Loop(header: "bb2", body: ["bb3"]),
                                           Loop(header: "bb1",
                                                body: ["bb2", "bb3", "bb4"])])
  }

  func testUnloopNested() {
    func o(_ name: String) -> Operand {
      return Operand(name, .namedType("Int"))
    }
    var nestedLoop: [Block] = [
      Block("bb0", ["%0", "%1"],
            .br("bb1", [o("%0"), o("%1")])),
      Block("bb1", ["%2", "%3"], [
              OperatorDef(Result(["%4"]), .builtin("something1", [o("%2")], .namedType("Int")), nil),
            ],
            .condBr("%4", "bb2", [o("%3")], "bb5", [])),
      Block("bb2", ["%5"], [
              OperatorDef(Result(["%6"]), .builtin("something2", [o("%5")], .namedType("Int")), nil),
            ],
            .condBr("%6", "bb3", [], "bb4", [])),
      Block("bb3", [], [
              OperatorDef(Result(["%7"]), .builtin("magic", [], .namedType("Int")), nil),
              OperatorDef(Result(["%8"]), .builtin("more_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%8", "bb2", [o("%7")], "bb5", [])),
      Block("bb4", [], [
              OperatorDef(Result(["%9"]), .builtin("iter_cond", [o("%2")], .namedType("Int")), nil),
              OperatorDef(Result(["%10"]), .builtin("super_magic", [], .namedType("Int")), nil),
            ],
            .br("bb1", [o("%9"), o("%10")])),
      Block("bb5", .return(o("%1"))),
    ]
    unloop(&nestedLoop)
    let expectedOutput: [Block] = [
      Block("bb0", ["%0", "%1"],
            .br("bb1", [o("%0"), o("%1")])),
      Block("bb1", ["%2", "%3"], [
              OperatorDef(Result(["%4"]), .builtin("something1", [o("%2")], .namedType("Int")), nil),
            ],
            .condBr("%4", "bb2", [o("%3")], "bb5", [])),
      Block("bb2", ["%5"], [
              OperatorDef(Result(["%6"]), .builtin("something2", [o("%5")], .namedType("Int")), nil),
            ],
            .condBr("%6", "bb3", [], "bb4", [])),
      Block("bb3", [], [
              OperatorDef(Result(["%7"]), .builtin("magic", [], .namedType("Int")), nil),
              OperatorDef(Result(["%8"]), .builtin("more_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%8", "bb2_bridge_1", [o("%7")], "bb5", [])),
      Block("bb4", [], [
              OperatorDef(Result(["%9"]), .builtin("iter_cond", [o("%2")], .namedType("Int")), nil),
              OperatorDef(Result(["%10"]), .builtin("super_magic", [], .namedType("Int")), nil),
            ],
            .br("bb1_bridge_10", [o("%9"), o("%10")])),
      Block("bb5", .return(o("%1"))),

      // First unloop
      Block("bb3_0", [], [
              OperatorDef(Result(["%7"]), .builtin("magic", [], .namedType("Int")), nil),
              OperatorDef(Result(["%8"]), .builtin("more_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%8", "bb2_final_3", [o("%7")], "bb5", [])),
      Block("bb2_bridge_1", ["%unused_2"], [
              OperatorDef(Result(["%5"]), .builtin("anyInhabitant", [], .namedType("Int")), nil),
              OperatorDef(Result(["%6"]), .builtin("something2", [o("%5")], .namedType("Int")), nil),
            ],
            .condBr("%6", "bb3_0", [], "bb4_unreachable", [])),
      Block("bb4_unreachable", .unreachable),
      Block("bb2_final_3", ["%5"], [
              OperatorDef(Result(["%6"]), .builtin("something2", [o("%5")], .namedType("Int")), nil),
            ],
            .condBr("%6", "bb3_unreachable", [], "bb4", [])),
      Block("bb3_unreachable", .unreachable),

      // Second unloop
      Block("bb2_4", ["%5"], [
              OperatorDef(Result(["%6"]), .builtin("something2", [o("%5")], .namedType("Int")), nil),
            ],
            .condBr("%6", "bb3_7", [], "bb4_9", [])),
      Block("bb2_bridge_1_5", ["%unused_2"], [
              OperatorDef(Result(["%5"]), .builtin("anyInhabitant", [], .namedType("Int")), nil),
              OperatorDef(Result(["%6"]), .builtin("something2", [o("%5")], .namedType("Int")), nil),
            ],
            .condBr("%6", "bb3_0_8", [], "bb4_unreachable", [])),
      Block("bb2_final_3_6", ["%5"], [
              OperatorDef(Result(["%6"]), .builtin("something2", [o("%5")], .namedType("Int")), nil),
            ],
            .condBr("%6", "bb3_unreachable", [], "bb4_9", [])),
      Block("bb3_7", [], [
              OperatorDef(Result(["%7"]), .builtin("magic", [], .namedType("Int")), nil),
              OperatorDef(Result(["%8"]), .builtin("more_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%8", "bb2_bridge_1_5", [o("%7")], "bb5", [])),
      Block("bb3_0_8", [], [
              OperatorDef(Result(["%7"]), .builtin("magic", [], .namedType("Int")), nil),
              OperatorDef(Result(["%8"]), .builtin("more_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%8", "bb2_final_3_6", [o("%7")], "bb5", [])),
      Block("bb4_9", [], [
              OperatorDef(Result(["%9"]), .builtin("iter_cond", [o("%2")], .namedType("Int")), nil),
              OperatorDef(Result(["%10"]), .builtin("super_magic", [], .namedType("Int")), nil),
            ],
            .br("bb1_final_13", [o("%9"), o("%10")])),
      Block("bb1_bridge_10", ["%unused_11", "%unused_12"], [
              OperatorDef(Result(["%2"]), .builtin("anyInhabitant", [], .namedType("Int")), nil),
              OperatorDef(Result(["%3"]), .builtin("anyInhabitant", [], .namedType("Int")), nil),
              OperatorDef(Result(["%4"]), .builtin("something1", [o("%2")], .namedType("Int")), nil),
            ],
            .condBr("%4", "bb2_4", [o("%3")], "bb5_unreachable", [])),
      Block("bb5_unreachable", .unreachable),
      Block("bb1_final_13", ["%2", "%3"], [
              OperatorDef(Result(["%4"]), .builtin("something1", [o("%2")], .namedType("Int")), nil),
            ],
            .condBr("%4", "bb2_unreachable", [o("%3")], "bb5", [])),
      Block("bb2_unreachable", ["%5"], .unreachable),
    ]
    XCTAssertEqual(nestedLoop, expectedOutput)
  }

  func testUnloopProperties() {
    for templateCFG in reducibleExamples {
      var cfg = clone(templateCFG)
      let hasLoops = !findLoops(cfg).isEmpty
      unloop(&cfg)
      if !hasLoops {
        XCTAssertEqual(cfg, templateCFG)
      } else {
        guard induceReducibleCFG(cfg)! else {
          XCTFail("Unlooped graph is irreducible!")
          continue
        }
        XCTAssertTrue(findLoops(cfg).isEmpty)
      }
    }
  }

  func testTopoSort() {
    func assertSorted(_ cfg: [Block]) {
      let position = Dictionary<BlockName, Int>(
        cfg.enumerated().map{ ($0.element.identifier, $0.offset) },
        uniquingKeysWith: { _,_ in fatalError() })
      for block in cfg {
        for successor in block.successors! {
          XCTAssertTrue(position[block.identifier]! < position[successor]!)
        }
      }
    }

    for cfg in DAGExamples {
      assertSorted(topoSort(cfg))
      for _ in 0..<10 {
        let result = topoSort([cfg[0]] + cfg[1...].shuffled())
        assertSorted(result)
        XCTAssertTrue(result[0] == cfg[0])
      }
    }
  }

  func clone(_ cfg: [Block]) -> [Block] {
    return cfg.map {
      Block($0.identifier, $0.arguments, $0.operatorDefs, $0.terminatorDef)
    }
  }

  static var allTests = [
    ("testInducesReducibleCFG", testInducesReducibleCFG),
    ("testFindLoops", testFindLoops),
    ("testUnloopNested", testUnloopNested),
    ("testUnloopProperties", testUnloopProperties),
    ("testTopoSort", testTopoSort),
  ]
}

fileprivate extension Block {
  convenience init(_ name: String, _ terminator: Terminator) {
    self.init(name, [], [], TerminatorDef(terminator, nil))
  }

  convenience init(_ name: String, _ args: [String], _ terminator: Terminator) {
    self.init(name, args, [], terminator)
  }

  convenience init(_ name: String, _ args: [String], _ body: [OperatorDef], _ terminator: Terminator) {
    self.init(name, args.map{ Argument($0, .namedType("Int")) }, body, TerminatorDef(terminator, nil))
  }
}

extension Loop: Equatable {
  public static func ==(_ a: Loop, _ b: Loop) -> Bool {
    return a.header == b.header && a.body == b.body
  }
}

