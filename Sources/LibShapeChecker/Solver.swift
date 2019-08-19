enum Inconsistency : Error {
  case rankMismatch(prev: Int, now: Int)
  case rankMismatch(prev: Int, nowAtLeast: Int)
  case dimensionSizeMismatch(prev: Int, now: Int)
}

// We will sometimes want to allocate temporary variables to simplify the
// implementation, and this is how we avoid clashes with names generated
// by the rest of this program.
enum TaggedDimVar: Hashable {
  case regular(_ v: DimVar)
  case temporary(_ t: DimVar)
}


enum DimValuation {
  case exact(_ v: Int)
}

enum ShapeValuation {
  case knownRank(_ dims: [TaggedDimVar])
  // NB: In the future this will be able to hold both positive and negative
  //     indices. This means that once the rank will be recovered, we might
  //     have to unify some of those variables.
  case unstructured(_ dims: [Int: TaggedDimVar])
}

struct Model {
  // INVARIANT: shapes and dims only hold valuations for representatives of
  //            classes present in their respective Equiv fields
  private var _shapes: [ShapeVar: ShapeValuation] = [:]
  private var _shapeEquiv = DefaultDict<ShapeVar, UnionFind<ShapeVar>>{ UnionFind($0) }

  private var _dims: [TaggedDimVar: DimValuation] = [:]
  private var _dimEquiv = DefaultDict<TaggedDimVar, UnionFind<TaggedDimVar>>{ UnionFind($0) }

  private let nextTemporaryVar = count(from: 0) >>> DimVar.init >>> TaggedDimVar.temporary

  subscript(_ a: ShapeVar) -> ShapeValuation? {
    mutating get { _shapeEquiv.contains(key: a) ? _shapes[representative(_shapeEquiv[a])] : nil }
    set(val) { _shapes[representative(_shapeEquiv[a])] = val }
  }
  subscript(_ a: TaggedDimVar) -> DimValuation? {
    mutating get { _dimEquiv.contains(key: a) ? _dims[representative(_dimEquiv[a])] : nil }
    set(val) { _dims[representative(_dimEquiv[a])] = val }
  }

  mutating func equate(_ aRaw: ShapeVar, _ bRaw: ShapeVar) throws {
    let a = _shapeEquiv[aRaw]
    let b = _shapeEquiv[bRaw]
    guard let (parent: p, child: c) = union(a, b) else { return }
    let pr = representative(p)
    let cr = representative(c)
    _shapes[pr] = try unify(_shapes[pr], _shapes[cr])
    _shapes[cr] = nil
  }

  mutating func equate(_ aRaw: TaggedDimVar, _ bRaw: TaggedDimVar) throws {
    let a = _dimEquiv[aRaw]
    let b = _dimEquiv[bRaw]
    guard let (parent: p, child: c) = union(a, b) else { return }
    let pr = representative(p)
    let cr = representative(c)
    _dims[pr] = try unify(_dims[pr], _dims[cr])
    _dims[cr] = nil
  }

  ////////////////////////////////////////////////////////////////////////////////
  // XXX: No methods below this line should ever access any of the properties
  //      prefixed with an underscore!
  ////////////////////////////////////////////////////////////////////////////////

  // NB: While semantically this function is symmetric, the order of arguments
  //     will have an effect on the error messages, so please be careful about it.
  //     The general rule is that the first argument is supposed to be the previously
  //     known fact, and the second one something we have learned just now.
  func unify(_ ma: DimValuation?, _ mb: DimValuation?) throws -> DimValuation? {
    guard let a = ma else { return mb }
    guard let b = mb else { return ma }
    switch (a, b) {
    case let (.exact(va), .exact(vb)):
      guard va == vb else {
        throw Inconsistency.dimensionSizeMismatch(prev: va, now: vb)
      }
      return .exact(va)
    }
  }

  // NB: See note about the argument order in unify for DimValuation
  mutating func unify(_ ma: ShapeValuation?, _ mb: ShapeValuation?) throws -> ShapeValuation? {
    guard let a = ma else { return mb }
    guard let b = mb else { return ma }
    switch (a, b) {
    case let (.knownRank(aDims), .knownRank(bDims)):
      guard aDims.count == bDims.count else {
        throw Inconsistency.rankMismatch(prev: aDims.count, now: bDims.count)
      }
      try zip(aDims, bDims).forEach{ try equate($0, $1) }
      return a
    case let (.unstructured(dimMap), .knownRank(dims)):
      let rank = dims.count
      for (dimIdx, dimVar) in dimMap {
        try equate(dimVar, dims[normalize(dimIdx, rank)])
      }
      return b
    case let (.unstructured(aDimMap), .unstructured(bDimMap)):
      return try .unstructured(
        aDimMap.merging(bDimMap, uniquingKeysWith: { try equate($0, $1); return $0 }))
    case (.knownRank(_), .unstructured(_)):
      return try unify(mb, ma)
    }
  }

  mutating func restrict(with constraints: [Constraint]) throws {
    for constraint in constraints {
      switch constraint {
      case let .shapeEqual(shape, expr):
        switch expr {
        case let .variable(otherShape):
          try equate(shape, otherShape)
        case let .literal(dimExprs):
          self[shape] = try unify(self[shape], makeShapeValuation(self, dimExprs))
        }

      case let .dimEqual(dim, expr):
        switch expr {
        case let .variable(otherDim):
          try equate(.regular(dim), .regular(otherDim))
        case let .literal(value):
          self[.regular(dim)] = try unify(self[.regular(dim)], .exact(value))
        }

      case let .shapeMember(shape, dim, dimIdx):
        switch self[shape] {
          case let .knownRank(dims):
            guard dimInRange(dimIdx, dims) else {
              throw Inconsistency.rankMismatch(prev: dims.count, nowAtLeast: minNeededRank(dimIdx))
            }
            try equate(dims[normalize(dimIdx, dims.count)], .regular(dim))
          case let .unstructured(dimMap):
            if let prevDim = dimMap[dimIdx] {
              try equate(prevDim, .regular(dim))
            } else {
              self[shape] = .unstructured(dimMap + [dimIdx: .regular(dim)])
            }
          case .none:
            self[shape] = .unstructured([dimIdx: .regular(dim)])
        }
      }
    }
  }

  mutating func makeShapeValuation(_ model: Model, _ exprs: [DimExpr]) -> ShapeValuation {
    return .knownRank(exprs.map{
      switch $0 {
      case let .variable(v):
        return .regular(v)
      case let .literal(value):
        let tmpVar = nextTemporaryVar()
        self[tmpVar] = .exact(value)
        return tmpVar
      }
    })
  }
}

fileprivate extension Dictionary {
  static func +(_ a: Dictionary<Key, Value>, _ b: Dictionary<Key, Value>) -> Dictionary<Key, Value> {
    return a.merging(b, uniquingKeysWith: { _, _ in fatalError("Expected dictionaries to be disjoint!") })
  }
}

// TODO: make a Dimension newtype
fileprivate func dimInRange(_ dim: Int, _ ndim : Int) -> Bool {
  return dim < 0 ? dim >= -ndim : dim < ndim
}

fileprivate func dimInRange<T>(_ dim: Int, _ dims: [T]) -> Bool {
  return dimInRange(dim, dims.count)
}

fileprivate func normalize(_ dim: Int, _ ndims : Int) -> Int {
  return dim < 0 ? dim + ndims : dim
}

func minNeededRank(_ dim: Int) -> Int {
  return dim < 0 ? -dim : dim + 1
}
