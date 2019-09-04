enum SolverResult {
  case sat
  case unknown
  case unsat([BoolExpr]?)
}

let optimize = simplify >>> inlineBoolVars >>> simplify

func verify(_ constraints: [Constraint]) -> SolverResult {
  let solver = Z3Context.default.makeSolver()
  var shapeVars = Set<ListVar>()
  var trackers: [String: BoolExpr] = [:]

  for constraint in optimize(constraints) {
    switch constraint {
    case let .expr(expr):
      for assertion in denote(expr) {
        trackers[solver.assertAndTrack(assertion)] = expr
      }
      // Perform a no-op substitution that has a side effect of gathering
      // all variables appearing in a formula.
      let _ = substitute(expr, using: {
        if case let .list(v) = $0 {
          shapeVars.insert(v)
        }
        return nil
      })
    case .call(_, _, _):
      break
    }
  }
  // Additionally assert that all shapes are non-negative
  let zero = Z3Context.default.literal(0)
  // FIXME: Do we need to assert the same thing for the temporary values? I guess so?
  for v in shapeVars {
    solver.assert(forall { Z3Context.default.make(listVariable: v.description).call($0) >= zero })
  }

  switch solver.check() {
  case .some(true):
    return .sat
  case .none:
    return .unknown
  case .some(false):
    guard let unsatCore = solver.getUnsatCore() else { return .unsat(nil) }
    return .unsat(unsatCore.map{ trackers[$0]! })
  }
}

////////////////////////////////////////////////////////////////////////////////
// Z3 translation

fileprivate let nextIntVariable = count(from: 0) .>> String.init .>> Z3Context.default.make(intVariable:)
fileprivate let nextListVariable = count(from: 0) .>> TaggedListVar.temporary

func denote(_ expr: BoolExpr) -> [Z3Expr<Bool>] {
  var denotation = Z3Denotation()
  let result = denotation.denote(expr)
  return denotation.assumptions + [result]
}

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

  var assumptions: [Z3Expr<Bool>] = []

  func denote(_ v: ListVar) -> Z3Expr<[Int]> {
    return Z3Context.default.make(listVariable: v.description)
  }

  func denote(_ v: TaggedListVar) -> Z3Expr<[Int]> {
    return Z3Context.default.make(listVariable: v.description)
  }

  func denote(_ v: IntVar) -> Z3Expr<Int> {
    return Z3Context.default.make(intVariable: v.description)
  }

  func denote(_ v: BoolVar) -> Z3Expr<Bool> {
    return Z3Context.default.make(boolVariable: v.description)
  }

  mutating func denote(_ expr: IntExpr) -> Z3Expr<Int> {
    switch expr {
    case let .var(v):
      return denote(v)
    case let .literal(value):
      return Z3Context.default.literal(value)
    case let .length(of: list):
      switch list {
      case let .broadcast(lhs, rhs):
        return rank(of: broadcast(lhs, rhs))
      case let .var(v):
        return rank(of: v)
      case let .literal(shapeValue):
        return Z3Context.default.literal(shapeValue.count)
      }
    case let .element(offset, of: list):
      // NB: Negative offsets are not supported yet, so we treat them as "any value"
      //     so that they're never involved in a contradiction.
      guard offset >= 0 else { return nextIntVariable() }
      switch list {
      case let .broadcast(lhs, rhs):
        return denote(broadcast(lhs, rhs)).call(Z3Context.default.literal(offset))
      case let .var(v):
        return denote(v).call(Z3Context.default.literal(offset))
      case let .literal(exprs):
        // NB: Out of bounds accesses will trigger a failure through a different
        //     set of assertions anyway, so no need to check for that here.
        guard offset < exprs.count,
              let expr = exprs[offset] else { return nextIntVariable() }
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

  mutating func denote(_ expr: BoolExpr) -> Z3Expr<Bool> {
    switch expr {
    case let .var(v):
      return denote(v)
    case let .and(subexprs):
      return subexprs.map{ denote($0) }.reduce(&&)
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
          for (i, maybeDimExpr) in exprs.enumerated() {
            guard let dimExpr = maybeDimExpr else { continue }
            assumptions.append(denote(v).call(Z3Context.default.literal(i)) == denote(dimExpr))
          }
          assumptions.append(rank(of: v) == Z3Context.default.literal(exprs.count))
          return Z3Context.default.true
        case let .broadcast(lhs, rhs):
          return denoteVarVarEq(v, broadcast(lhs, rhs))
        }
      }

      func denoteVarVarEq(_ lhs: TaggedListVar, _ rhs: TaggedListVar) -> Z3Expr<Bool> {
        assumptions.append(rank(of: lhs) == rank(of: rhs))
        return forall { denote(lhs).call($0) == denote(rhs).call($0) }
      }

      return denoteListListEq(lhs, rhs)
    }
  }

  mutating func broadcast(_ lhsExpr: ListExpr, _ rhsExpr: ListExpr) -> TaggedListVar {
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
  mutating func materialize(_ expr: ListExpr) -> TaggedListVar {
    switch expr {
    case let .var(v):
      return .real(v)
    case let .literal(exprs):
      let v = nextListVariable()
      for (i, maybeDimExpr) in exprs.enumerated() {
        guard let dimExpr = maybeDimExpr else { continue }
        assumptions.append(denote(v).call(Z3Context.default.literal(i)) == denote(dimExpr))
      }
      assumptions.append(rank(of: v) == Z3Context.default.literal(exprs.count))
      return v
    case let .broadcast(lhs, rhs):
      return broadcast(lhs, rhs)
    }
  }

  func rank(of v: ListVar) -> Z3Expr<Int> {
    return Z3Context.default.make(intVariable: "\(v)_rank")
  }

  func rank(of v: TaggedListVar) -> Z3Expr<Int> {
    return Z3Context.default.make(intVariable: "\(v)_rank")
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
