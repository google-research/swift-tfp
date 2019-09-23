enum LegalHoleValues: Equatable {
  case anything
  case only(Int)
  case examples([Int])
}

enum SolverResult: Equatable {
  case sat([SourceLocation: LegalHoleValues]?)
  case unknown
  case unsat([Constraint]?)
}

func isImpliedShapeEq(_ constraint: Constraint) -> Bool {
  switch constraint {
  case .expr(.listEq(_, _), assuming: _, .implied, _): return true
  default: return false
  }
}

// First, resolve the unnecessary equations that have been added at call sites.
// This should have exposed the boolean conditions that are then asserted directly,
// so we attemp to inline those next.
// Finally, before we attempt to resolve all shape equalities (for performance reasons)
// try to inline the implied ones into those that were asserted to make it more likely
// that user-written assertions show up in unsat cores.
let preprocess = { resolveEqualities($0, strength: .implied) } >>>
                 inlineBoolVars >>>
                 { inline($0, canInline: isImpliedShapeEq) } >>>
                 { resolveEqualities($0, strength: .all(of: [.shape, .implied])) }

func verify(_ constraints: [Constraint]) -> SolverResult {
  // TODO: We don't really need to construct the models if there are no holes
  let solver = Z3Context.default.makeSolver()
  var shapeVars = Set<ListVar>()
  var trackers: [String: Constraint] = [:]

  // This needs to be stateful to ensure that holes receive consistent assignment
  // of variables in all constraints where they appear.
  var denotation = Z3Denotation()
  for constraint in preprocess(constraints) {
    for assertion in denotation.denote(constraint) {
      trackers[solver.assertAndTrack(assertion)] = constraint
    }

    // Perform a no-op substitution that has a side effect of gathering
    // all variables appearing in a formula.
    let _ = substitute(constraint, using: {
      if case let .list(v) = $0 { shapeVars.insert(v) }
      return nil
    })
  }
  // Additionally assert that all shapes are non-negative
  let zero = Z3Context.default.literal(0)
  // FIXME: Do we need to assert the same thing for the temporary values? I guess so?
  for v in shapeVars {
    solver.assert(forall { Z3Context.default.make(listVariable: v.description).call($0) >= zero })
  }

  switch solver.check() {
  case .some(true):
    guard !denotation.holes.dictionary.isEmpty else { return .sat([:]) }
    guard let model = solver.getModel() else { return .sat(nil) }
    var holeValuation: [SourceLocation: LegalHoleValues] = [:]
    for (location, v) in denotation.holes.dictionary {
      guard let value = model.getInterpretation(of: declFor(v)) else {
        holeValuation[location] = .anything
        continue
      }
      // Try to find another value of v that satisfies the constraints.
      solver.temporaryScope {
        solver.assert(v != Z3Context.default.literal(value))
        switch solver.check() {
        case .some(true):
          if let anotherModel = solver.getModel(),
              let anotherValue = anotherModel.getInterpretation(of: declFor(v)) {
            holeValuation[location] = .examples([value, anotherValue])
          } else {
            holeValuation[location] = .examples([value])
          }
        case .none: holeValuation[location] = .examples([value])
        case .some(false): holeValuation[location] = .only(value)
        }
      }
    }
    return .sat(holeValuation)
  case .none:
    return .unknown
  case .some(false):
    guard let unsatCore = solver.getUnsatCore() else { return .unsat(nil) }
    return .unsat(unsatCore.map{ trackers[$0]! })
  }
}

////////////////////////////////////////////////////////////////////////////////
// Z3 translation

fileprivate let nextIntVariable = count(from: 0) .>> { "d_tmp\($0)" } .>> Z3Context.default.make(intVariable:)
fileprivate let nextListVariable = count(from: 0) .>> TaggedListVar.temporary

enum TaggedListVar: CustomStringConvertible {
  case real(ListVar)
  case temporary(VarName)

  var description: String {
    switch self {
    case let .real(v): return v.description
    case let .temporary(name): return "s_tmp\(name)"
    }
  }
}

struct Z3Denotation {
  // All denote(...) calls have to produce a well typed Z3Expr, but because
  // the Z3 language is relatively limited we also have to e.g. desugar some
  // expressions and allocate intermediate variables which have some constraints
  // applied to the (e.g. list literals like [2, 3] might get encoded as a function
  // variable in Z3). The way to think about it is that all assumptions have to be
  // satisfied for the result of denote(...) to be well formed.
  // Note that You don't ever need to e.g. negate them! If they fail then it means
  // that the negated subexpression is not well formed already!
  var assumptions: [Z3Expr<Bool>] = []
  var holes = DefaultDict<SourceLocation, Z3Expr<Int>>{ _ in nextIntVariable() }

  mutating func denote(_ constraint: Constraint) -> [Z3Expr<Bool>] {
    defer { assumptions = [] }
    switch constraint {
    case let .expr(expr, assuming: condExpr, _, _):
      let assertPart = denote(expr)
      let assert = assumptions + [assertPart]
      if condExpr != .true {
        assumptions = []
        let condPart = denote(condExpr)
        let cond = assumptions.reduce(condPart, &&)
        return assert.map{ implies(cond, $0) }
      } else {
        return assert
      }
    }
  }

  private func denote(_ v: ListVar) -> Z3Expr<[Int]> {
    return Z3Context.default.make(listVariable: v.description)
  }

  private func denote(_ v: TaggedListVar) -> Z3Expr<[Int]> {
    return Z3Context.default.make(listVariable: v.description)
  }

  private func denote(_ v: IntVar) -> Z3Expr<Int> {
    return Z3Context.default.make(intVariable: v.description)
  }

  private func denote(_ v: BoolVar) -> Z3Expr<Bool> {
    return Z3Context.default.make(boolVariable: v.description)
  }

  private mutating func denote(_ expr: IntExpr) -> Z3Expr<Int> {
    switch expr {
    case let .hole(loc):
      return holes[loc]
    case let .var(v):
      return denote(v)
    case let .literal(value):
      return Z3Context.default.literal(value)
    case let .length(of: list):
      return rank(of: list)
    case let .element(offset, of: list):
      let offsetExpr: Z3Expr<Int>
      let listRank = rank(of: list)
      if offset < 0 {
          offsetExpr = Z3Context.default.literal(-offset - 1)
      } else {
          offsetExpr = listRank - Z3Context.default.literal(offset + 1)
      }
      // NB: This ensures that the lookup is in bounds
      assumptions.append(listRank > offsetExpr)
      assumptions.append(offsetExpr >= Z3Context.default.literal(0))
      switch list {
      case let .broadcast(lhs, rhs):
        return denote(broadcast(lhs, rhs)).call(offsetExpr)
      case let .var(v):
        return denote(v).call(offsetExpr)
      case let .literal(exprs):
        let positiveOffset = offset < 0 ? offset + exprs.count : offset
        guard positiveOffset < exprs.count,
              positiveOffset >= 0,
              let expr = exprs[positiveOffset] else { return nextIntVariable() }
        return denote(expr)
      }
    case let .add(lhs, rhs):
      return denote(lhs) + denote(rhs)
    case let .sub(lhs, rhs):
      return denote(lhs) - denote(rhs)
    case let .mul(lhs, rhs):
      return denote(lhs) * denote(rhs)
    case let .div(lhs, rhs):
      return denote(lhs) / denote(rhs)
    }
  }

  private mutating func denote(_ expr: BoolExpr) -> Z3Expr<Bool> {
    switch expr {
    case .true:
      return Z3Context.default.true
    case .false:
      return Z3Context.default.false
    case let .var(v):
      return denote(v)
    case let .not(subexpr):
      return !denote(subexpr)
    case let .and(subexprs):
      return subexprs.map{ denote($0) }.reduce(&&)
    case let .or(subexprs):
      return subexprs.map{ denote($0) }.reduce(||)
    case let .intEq(lhs, rhs):
      return denote(lhs) == denote(rhs)
    case let .intGt(lhs, rhs):
      return denote(lhs) > denote(rhs)
    case let .intGe(lhs, rhs):
      return denote(lhs) >= denote(rhs)
    case let .intLt(lhs, rhs):
      return denote(lhs) < denote(rhs)
    case let .intLe(lhs, rhs):
      return denote(lhs) <= denote(rhs)
    case let .boolEq(lhs, rhs):
      return denote(lhs) == denote(rhs)
    case let .listEq(lhs, rhs):
      // This translation could have been much easier, but we try as hard as we can
      // to avoid quantifier instantiation. The following three functions dispatch
      // from top to bottom, narrowing the set of equations that have to be handled.
      func denoteListListEq(_ lhs: ListExpr, _ rhs: ListExpr) -> Z3Expr<Bool> {
        switch (lhs, rhs) {
        case let (.broadcast(lhs, rhs), other): fallthrough
        case let (other, .broadcast(lhs, rhs)):
          return denoteVarListEq(broadcast(lhs, rhs), other)

        case let (.var(v), other): fallthrough
        case let (other, .var(v)):
          return denoteVarListEq(.real(v), other)

        case let (.literal(lhsExprs), .literal(rhsExprs)):
          let lengthConstraint = BoolExpr.intEq(.literal(lhsExprs.count), .literal(rhsExprs.count))
          let elementConstraints = zip(lhsExprs, rhsExprs).compactMap {
            (maybeExprs: (IntExpr?, IntExpr?)) -> BoolExpr? in
            switch (maybeExprs.0, maybeExprs.1) {
            case let (.some(lhsExpr), .some(rhsExpr)):
              return .intEq(lhsExpr, rhsExpr)
            case let (.some(expr), .none): fallthrough
            case let (.none, .some(expr)):
              // FIXME: This is a bit overzealous, because we don't do any verification
              //        to determine whether the assertions are statements about lists
              //        of integers (where having negative elements is fine) or shapes.
              return .intGe(expr, .literal(0))
            case (.none, .none):
              return nil
            }
          }
          return denote(BoolExpr.and([lengthConstraint] + elementConstraints))
        }
      }

      func denoteVarListEq(_ v: TaggedListVar, _ expr: ListExpr) -> Z3Expr<Bool> {
        switch expr {
        case let .var(exprVar):
          return denoteVarVarEq(v, .real(exprVar))
        case let .literal(exprs):
          var assertions: [Z3Expr<Bool>] = []
          for (i, maybeDimExpr) in exprs.enumerated() {
            guard let dimExpr = maybeDimExpr else { continue }
            assertions.append(denote(v).call(Z3Context.default.literal(exprs.count - i - 1)) == denote(dimExpr))
          }
          let rankEquality = rank(of: v) == Z3Context.default.literal(exprs.count)
          return assertions.reduce(rankEquality, &&)
        case let .broadcast(lhs, rhs):
          return denoteVarVarEq(v, broadcast(lhs, rhs))
        }
      }

      func denoteVarVarEq(_ lhs: TaggedListVar, _ rhs: TaggedListVar) -> Z3Expr<Bool> {
        return forall { denote(lhs).call($0) == denote(rhs).call($0) } &&
               rank(of: lhs) == rank(of: rhs)
      }

      return denoteListListEq(lhs, rhs)
    }
  }

  private mutating func broadcast(_ lhsExpr: ListExpr, _ rhsExpr: ListExpr) -> TaggedListVar {
    // TODO: We could be smart in here and encode e.g. a broadcast with
    //       a literal without using any quantifiers.
    // TODO: Broadcasting is associative, so we could pool all the broadcasted
    //       lists and deal with all literals ahead of time.
    let lhsVar = materialize(lhsExpr)
    let rhsVar = materialize(rhsExpr)
    let lhs = denote(lhsVar)
    let rhs = denote(rhsVar)
    let v = nextListVariable()
    let one = Z3Context.default.literal(1)
    assumptions.append(forall {
      denote(v).call($0) == ite(lhs.call($0) == one, rhs.call($0), lhs.call($0))
    })
    // NB: An alternative formulation of the same fact (that also scales to
    //     a larger number of variables) is that:
    //     v[i] = max(lhs[i], rhs[i]) and (lhs[i] == 1 or lhs[i] == v[i])
    //                                and (rhs[i] == 1 or rhs[i] == v[i])
    assumptions.append(forall { lhs.call($0) == one ||
                                rhs.call($0) == one ||
                                lhs.call($0) == rhs.call($0) })
    assumptions.append(rank(of: v) == ite(rank(of: lhsVar) < rank(of: rhsVar), rank(of: rhsVar), rank(of: lhsVar)))
    return v
  }

  // Binds the value of the list expression to a variable.
  private mutating func materialize(_ expr: ListExpr) -> TaggedListVar {
    switch expr {
    case let .var(v):
      return .real(v)
    case let .literal(exprs):
      let v = nextListVariable()
      for (i, maybeDimExpr) in exprs.enumerated() {
        guard let dimExpr = maybeDimExpr else { continue }
        assumptions.append(denote(v).call(Z3Context.default.literal(exprs.count - i - 1)) == denote(dimExpr))
      }
      assumptions.append(rank(of: v) == Z3Context.default.literal(exprs.count))
      return v
    case let .broadcast(lhs, rhs):
      return broadcast(lhs, rhs)
    }
  }

  private func rank(of v: ListVar) -> Z3Expr<Int> {
    return Z3Context.default.make(intVariable: "\(v)_rank")
  }

  private func rank(of v: TaggedListVar) -> Z3Expr<Int> {
    return Z3Context.default.make(intVariable: "\(v)_rank")
  }

  private mutating func rank(of e: ListExpr) -> Z3Expr<Int> {
    switch e {
    case let .broadcast(lhs, rhs):
      return rank(of: broadcast(lhs, rhs))
    case let .var(v):
      return rank(of: v)
    case let .literal(shapeValue):
      return Z3Context.default.literal(shapeValue.count)
    }
  }
}

extension Array {
  func reduce(_ nextPartialResult: (Element, Element) -> Element) -> Element {
    guard let f = first else {
      fatalError("Reduce without initial value on an empty array!")
    }
    return suffix(from: 1).reduce(f, nextPartialResult)
  }
}
