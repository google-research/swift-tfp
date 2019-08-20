@testable import LibShapeChecker
import SIL
import XCTest

@available(macOS 10.13, *)
final class SolverTests: XCTestCase {
  let s1 = ShapeVar(name: 1)
  let s2 = ShapeVar(name: 2)
  let s3 = ShapeVar(name: 3)

  let d1 = DimVar(name: 1)
  let d2 = DimVar(name: 2)
  let d3 = DimVar(name: 3)
  let d4 = DimVar(name: 4)
  let d5 = DimVar(name: 5)
  let d6 = DimVar(name: 6)
  let d7 = DimVar(name: 7)

  func testRankMismatch() {
    assert(inconsistency: .rankMismatch(prev: 2, now: 1),
           with: [
             .shapeEqual(s1, .literal([.variable(d1), .variable(d2)])),
             .shapeEqual(s1, .literal([.literal(3)]))
           ])
    assert(inconsistency: .rankMismatch(prev: 2, nowAtLeast: 4),
           with: [
             .shapeEqual(s1, .literal([.variable(d1), .variable(d2)])),
             .shapeMember(s1, d3, 3)
           ])
  }

  func testDimSizeMismatch() {
    assert(inconsistency: .dimensionSizeMismatch(prev: 3, now: 5),
           with: [
             .shapeEqual(s1, .literal([.literal(3), .literal(4)])),
             .shapeEqual(s1, .literal([.literal(5), .literal(4)]))
           ])
  }

  func testTransitivity() {
    let base: [Constraint] = [
      .shapeMember(s1, d1, 0),
      .shapeEqual(s1, .variable(s2)),
      .shapeEqual(s2, .variable(s3)),
    ]
    withModel(for: base + [
                .shapeEqual(s3, .literal([.literal(4), .literal(5)]))
              ]) { model in
      XCTAssertEqual(model[.regular(d1)], .exact(4))
      guard case let .knownRank(shape) = model[s1] else {
        return XCTFail("Expected the shape model for s1 to have a single dim!")
      }
      XCTAssertEqual(shape.count, 2)
    }
    withModel(for: base + [
                .shapeMember(s3, d2, 0),
                .dimEqual(d2, .literal(4))
              ]) { model in
      XCTAssertEqual(model[.regular(d1)], .exact(4))
      guard case let .unstructured(dimMap) = model[s1] else {
        return XCTFail("Expected the shape model for s1 to be unstructered!")
      }
      XCTAssertEqual(dimMap.count, 1)
      XCTAssert(dimMap[0] != nil)
    }
  }

  func testNegativeDimIndices() {
    withModel(for: [
                .shapeMember(s1, d1, 2),
                .shapeMember(s1, d2, -2),
                .shapeEqual(s1, .variable(s2))
              ]) { model in
      XCTAssert(!model._areEquivalent(.regular(d1), .regular(d2)))
      guard checkedRestrict(&model, with: .shapeEqual(s2, .literal([.variable(d3),
                                                                    .variable(d4),
                                                                    .variable(d5),
                                                                    .variable(d6)]))) else { return }
      XCTAssert(model._areEquivalent(.regular(d1), .regular(d2)))
      guard checkedRestrict(&model, with: .shapeEqual(s2, .literal([.literal(1),
                                                                    .literal(2),
                                                                    .literal(3),
                                                                    .literal(4)]))) else { return }
      XCTAssertEqual(model[.regular(d1)], .exact(3))
      XCTAssertEqual(model[.regular(d2)], .exact(3))
    }
  }

  func assert(inconsistency: Inconsistency,
              with allConstraints: [Constraint]) {
    var satisfiable = allConstraints
    guard let contradiction = satisfiable.popLast() else {
      return XCTFail("Expected at least one constraint!")
    }
    do {
      var model = Model()
      do {
        try model.restrict(with: satisfiable)
      } catch {
        return XCTFail("Expected the model creation to fail only after seeing the last constraint!")
      }
      try model.restrict(with: [contradiction])
    } catch let error as Inconsistency {
      guard error == inconsistency else {
        return XCTFail("Expected to fail with \(inconsistency), but got \(error)")
      }
      return
    } catch {}
    XCTFail("Expected a constraint system to fail!")
  }

  func checkedRestrict(_ model: inout Model, with constraint: Constraint) -> Bool {
    do {
      try model.restrict(with: [constraint])
    } catch {
      XCTFail("Expected the restriction to succeed!")
      return false
    }
    return true
  }

  func withModel(for constraints: [Constraint], f: (inout Model) -> Void) {
    do {
      var model = Model()
      try model.restrict(with: constraints)
      f(&model)
    } catch {
      XCTFail("Expected a model to be satisfiable!")
    }
  }

  static var allTests = [
    ("testRankMismatch", testRankMismatch),
    ("testDimSizeMismatch", testDimSizeMismatch),
    ("testTransitivity", testTransitivity),
  ]
}

