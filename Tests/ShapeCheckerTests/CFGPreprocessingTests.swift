@testable import LibShapeChecker
import SIL
import XCTest

let returnInstr = Terminator.return(Operand("", .namedType("")))

func o(_ name: String) -> Operand {
  return Operand(name, .namedType("Int"))
}

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

let nestedLoopWithAssert: [Block] = [
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
        // This cond_br to an unreachable block appears e.g. when asserts are inlined.
        .condBr("%9", "bb1", [o("%9"), o("%10")], "bb6", [])),
  Block("bb5", .return(o("%1"))),
  Block("bb6", [], [
          OperatorDef(nil, .builtin("print_err", [o("%9")], .namedType("Void")), nil),
        ],
        .unreachable),
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
  nestedLoopWithAssert,
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
    XCTAssertEqual(findLoops(nestedLoopWithAssert),
                   [Loop(header: "bb2", body: ["bb3"]),
                    Loop(header: "bb1",
                         body: ["bb2", "bb3", "bb4"])])
  }

  func testUnloopNested() {
    var cfg = clone(nestedLoopWithAssert)
    let _ = unloop(&cfg)
    let expectedCFG: [Block] = [
      Block("bb0", ["%0_10", "%1_11"],
            .br("bb1", [o("%0_10"), o("%1_11"), o("%1_11")])),
      Block("bb1", ["%2_12", "%3_13", "%1_14"], [
              OperatorDef(Result(["%4_15"]), .builtin("something1", [o("%2_12")], .namedType("Int")), nil),
            ],
            .condBr("%4_15", "bb2", [o("%3_13"), o("%1_14"), o("%2_12")], "bb5", [o("%1_14")])),
      Block("bb2", ["%5_16", "%1_17", "%2_18"], [
              OperatorDef(Result(["%6_19"]), .builtin("something2", [o("%5_16")], .namedType("Int")), nil),
            ],
            .condBr("%6_19", "bb3", [o("%1_17"), o("%2_18")], "bb4", [o("%1_17"), o("%2_18")])),
      Block("bb3", ["%1_20", "%2_21"], [
              OperatorDef(Result(["%7_22"]), .builtin("magic", [], .namedType("Int")), nil),
              OperatorDef(Result(["%8_23"]), .builtin("more_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%8_23", "bb2_bridge", [o("%7_22"), o("%1_20"), o("%2_21")], "bb5", [o("%1_20")])),
      Block("bb2_bridge", ["%unused_1_24", "%1_25", "%2_26"], [
              OperatorDef(Result(["%5_27"]), .builtin("anyInhabitant", [], .namedType("Int")), nil),
              OperatorDef(Result(["%6_28"]), .builtin("something2", [o("%5_27")], .namedType("Int")), nil),
            ],
            .condBr("%6_28", "bb3_0", [o("%1_25"), o("%2_26")], "bb4_unreachable", [])),
      Block("bb3_0", ["%1_29", "%2_30"], [
              OperatorDef(Result(["%7_31"]), .builtin("magic", [], .namedType("Int")), nil),
              OperatorDef(Result(["%8_32"]), .builtin("more_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%8_32", "bb2_final", [o("%7_31"), o("%1_29"), o("%2_30")], "bb5", [o("%1_29")])),
      Block("bb2_final", ["%5_33", "%1_34", "%2_35"], [
              OperatorDef(Result(["%6_36"]), .builtin("something2", [o("%5_33")], .namedType("Int")), nil),
            ],
            .condBr("%6_36", "bb3_unreachable", [], "bb4", [o("%1_34"), o("%2_35")])),
      Block("bb4", ["%1_37", "%2_38"], [
              OperatorDef(Result(["%9_39"]), .builtin("iter_cond", [o("%2_38")], .namedType("Int")), nil),
              OperatorDef(Result(["%10_40"]), .builtin("super_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%9_39", "bb1_bridge", [o("%9_39"), o("%10_40"), o("%1_37")], "bb6", [o("%9_39")])),
      Block("bb1_bridge", ["%unused_8_41", "%unused_9_42", "%1_43"], [
              OperatorDef(Result(["%2_44"]), .builtin("anyInhabitant", [], .namedType("Int")), nil),
              OperatorDef(Result(["%3_45"]), .builtin("anyInhabitant", [], .namedType("Int")), nil),
              OperatorDef(Result(["%4_46"]), .builtin("something1", [o("%2_44")], .namedType("Int")), nil),
            ],
            .condBr("%4_46", "bb2_2", [o("%3_45"), o("%1_43"), o("%2_44")], "bb5_unreachable", [])),
      Block("bb2_2", ["%5_47", "%1_48", "%2_49"], [
              OperatorDef(Result(["%6_50"]), .builtin("something2", [o("%5_47")], .namedType("Int")), nil),
            ],
            .condBr("%6_50", "bb3_5", [o("%1_48"), o("%2_49")], "bb4_7", [o("%1_48"), o("%2_49")])),
      Block("bb3_5", ["%1_51", "%2_52"], [
              OperatorDef(Result(["%7_53"]), .builtin("magic", [], .namedType("Int")), nil),
              OperatorDef(Result(["%8_54"]), .builtin("more_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%8_54", "bb2_bridge_3", [o("%7_53"), o("%1_51"), o("%2_52")], "bb5", [o("%1_51")])),
      Block("bb2_bridge_3", ["%unused_1_55", "%1_56", "%2_57"], [
              OperatorDef(Result(["%5_58"]), .builtin("anyInhabitant", [], .namedType("Int")), nil),
              OperatorDef(Result(["%6_59"]), .builtin("something2", [o("%5_58")], .namedType("Int")), nil),
            ],
            .condBr("%6_59", "bb3_0_6", [o("%1_56"), o("%2_57")], "bb4_unreachable", [])),
      Block("bb3_0_6", ["%1_60", "%2_61"], [
              OperatorDef(Result(["%7_62"]), .builtin("magic", [], .namedType("Int")), nil),
              OperatorDef(Result(["%8_63"]), .builtin("more_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%8_63", "bb2_final_4", [o("%7_62"), o("%1_60"), o("%2_61")], "bb5", [o("%1_60")])),
      Block("bb2_final_4", ["%5_64", "%1_65", "%2_66"], [
              OperatorDef(Result(["%6_67"]), .builtin("something2", [o("%5_64")], .namedType("Int")), nil),
            ],
            .condBr("%6_67", "bb3_unreachable", [], "bb4_7", [o("%1_65"), o("%2_66")])),
      Block("bb3_unreachable", .unreachable),
      Block("bb4_7", ["%1_68", "%2_69"], [
              OperatorDef(Result(["%9_70"]), .builtin("iter_cond", [o("%2_69")], .namedType("Int")), nil),
              OperatorDef(Result(["%10_71"]), .builtin("super_magic", [], .namedType("Int")), nil),
            ],
            .condBr("%9_70", "bb1_final", [o("%9_70"), o("%10_71"), o("%1_68")], "bb6", [o("%9_70")])),
      Block("bb1_final", ["%2_72", "%3_73", "%1_74"], [
              OperatorDef(Result(["%4_75"]), .builtin("something1", [o("%2_72")], .namedType("Int")), nil),
            ],
            .condBr("%4_75", "bb2_unreachable", [o("%3_73")], "bb5", [o("%1_74")])),
      Block("bb2_unreachable", ["%5_76"], .unreachable),
      Block("bb5", ["%1_77"], [], .return(o("%1_77"))),
      Block("bb6", ["%9_78"], [
              OperatorDef(nil, .builtin("print_err", [o("%9_78")], .namedType("Void")), nil),
            ],
            .unreachable),
      Block("bb4_unreachable", .unreachable),
      Block("bb5_unreachable", .unreachable),
    ]
    XCTAssertEqual(cfg, expectedCFG)
  }

  func testUnloopProperties() {
    for templateCFG in reducibleExamples {
      var cfg = clone(templateCFG)
      let hasLoops = !findLoops(cfg).isEmpty
      unloop(&cfg)
      if !hasLoops {
        XCTAssertEqual(cfg, templateCFG)
      } else {
        // Make sure that the graph is reducible and the loops are gone
        guard induceReducibleCFG(cfg)! else {
          XCTFail("Unlooped graph is irreducible!")
          continue
        }
        XCTAssertTrue(findLoops(cfg).isEmpty)

        // Make sure that every register is assigned to only once, and that
        // the blocks are closed
        var assignedNames = Set<Register>()
        for block in topoSort(cfg) {
          var localRegs = Set<Register>(block.arguments.map{ $0.valueName })
          for op in block.operatorDefs {
            for readReg in op.operator.operands ?? [] {
              XCTAssertTrue(localRegs.contains(readReg.value))
            }
            for writtenReg in op.result?.valueNames ?? [] {
              XCTAssertFalse(assignedNames.contains(writtenReg))
              assignedNames.insert(writtenReg)
              localRegs.insert(writtenReg)
            }
          }
          for readReg in block.terminatorDef.terminator.operands ?? [] {
            XCTAssertTrue(localRegs.contains(readReg.value))
          }
        }
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

