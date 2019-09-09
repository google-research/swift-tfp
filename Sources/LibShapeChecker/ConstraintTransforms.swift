////////////////////////////////////////////////////////////////////////////////
// MARK: Simple transforms

// Normalizes names of variables
func alphaNormalize(_ constraints: [Constraint]) -> [Constraint] {
  var rename = DefaultDict<Var, Var>(withDefault: makeVariableGenerator())
  return constraints.map{ substitute($0, using: { rename[$0].expr }) }
}


// Returns a list of constraints in the same order, but with no single
// constraint appearing twice (only the first occurence is retained.
public func deduplicate(_ constraints: [Constraint]) -> [Constraint] {
  var seen = Set<Constraint>()
  return constraints.compactMap {
    guard !seen.contains($0) else { return nil }
    seen.insert($0)
    return $0
  }
}

// Tries to iteratively go over expressions, simplify them, and in case they
// equate a variable with an expression, inline the definition of this variable
// into all following constraints. The maximal multiplicative increase in the size
// of an expression is controlled by the upToSize argument.
public func inline(_ originalConstraints: [Constraint], upToSize: Int = 20) -> [Constraint] {
  var inlined: [Var: Expr] = [:]
  var inlineForbidden = Set<Var>()

  func handleEquality(_ v: Var, _ originalExpr: Expr) -> (Expr, Expr)? {
    if let alreadyInlined = inlined[v] {
      return (alreadyInlined, simplify(substitute(originalExpr, using: { inlined[$0] })))
    } else {
      let expr = simplify(substitute(originalExpr, using: {
        if let replacement = inlined[$0] {
          return replacement
        }
        inlineForbidden.insert($0)
        return nil
      }))
      if !inlineForbidden.contains(v) {
        if expr.complexity <= upToSize {
          inlined[v] = expr
          return nil
        } else {
          inlineForbidden.insert(v)
          return (v.expr, expr)
        }
      } else {
        return (v.expr, expr)
      }
    }
  }

  let constraints = originalConstraints.flatMap {
    (constraint: Constraint) -> [Constraint] in
    switch constraint {
    case let .expr(.listEq(.var(v), expr), loc):
      if let (lhs, rhs) = handleEquality(.list(v), .list(expr)) {
        return (lhs ≡ rhs).map{ .expr($0, loc) }
      }
      return []
    case let .expr(.intEq(.var(v), expr), loc):
      if let (lhs, rhs) = handleEquality(.int(v), .int(expr)) {
        return (lhs ≡ rhs).map{ .expr($0, loc) }
      }
      return []
    case let .expr(.boolEq(.var(v), expr), loc):
      if let (lhs, rhs) = handleEquality(.bool(v), .bool(expr)) {
        return (lhs ≡ rhs).map{ .expr($0, loc) }
      }
      return []
    default:
      return [simplify(substitute(constraint,
                                  using: { inlineForbidden.insert($0); return inlined[$0] }))]
    }
  }

  return inlined.isEmpty ? constraints : inline(constraints)
}

// Looks for variable equality statements and replaces all occurences of variables
// within a single equality class with its representative.
// NB: As much as it is both easy and possible to deal with equalities
//     on the int and bool level, keeping those usually allows us to provide
//     much better locations for error messages. Hence, we only deal with
//     lists here, because that case is very important to eliminate the number
//     of quantifier instantiations in the solver.
public func resolveEqualities(_ constraints: [Constraint], shapeOnly: Bool = true) -> [Constraint] {
  var equalityClasses = DefaultDict<Var, UnionFind<Var>>{ UnionFind($0) }

  let subset: [Constraint] = constraints.compactMap { (constraint: Constraint) -> Constraint? in
    switch constraint {
    case let .expr(expr, _):
      switch expr {
      case let .listEq(.var(lhs), .var(rhs)):
        union(equalityClasses[.list(lhs)], equalityClasses[.list(rhs)])
        return nil
      case let .intEq(.var(lhs), .var(rhs)):
        guard !shapeOnly else { return constraint }
        union(equalityClasses[.int(lhs)], equalityClasses[.int(rhs)])
        return nil
      case let .boolEq(.var(lhs), .var(rhs)):
        guard !shapeOnly else { return constraint }
        union(equalityClasses[.bool(lhs)], equalityClasses[.bool(rhs)])
        return nil
      default:
        return constraint
      }
    case .call(_, _, _, _):
      return constraint
    }
  }

  return subset.map {
    substitute($0, using: { representative(equalityClasses[$0]).expr })
  }
}

// Assertion instantiations produce patterns of the form:
// b4 = <cond>, b4
// This function tries to find those and inline them.
public func inlineBoolVars(_ constraints: [Constraint]) -> [Constraint] {
  var usedBoolVars = Set<BoolVar>()
  func gatherBoolVars(_ constraint: Constraint) {
    let _ = substitute(constraint, using: {
      if case let .bool(v) = $0 { usedBoolVars.insert(v) }
      return nil
    })
  }

  var exprs: [BoolVar: BoolExpr] = [:]
  for constraint in constraints {
    if case let .expr(.boolEq(.var(v), expr), _) = constraint, exprs[v] == nil {
      exprs[v] = expr
      gatherBoolVars(.expr(expr, .unknown)) // NB: Source location doesn't matter here
    } else if case .expr(.var(_), _) = constraint {
      // Do nothing
    } else {
      gatherBoolVars(constraint)
    }
  }

  return constraints.compactMap { constraint in
    if case let .expr(.boolEq(.var(v), _), _) = constraint, !usedBoolVars.contains(v) {
      return nil
    } else if case let .expr(.var(v), loc) = constraint, !usedBoolVars.contains(v) {
      return exprs[v].map{ .expr($0, loc) } ?? constraint
    }
    return constraint
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Simplification

// Simplifies the constraint without any additional context. For example
// a subexpression [1, 2, 3][1] will get replaced by 2.
public func simplify(_ constraint: Constraint) -> Constraint {
  switch constraint {
  case let .expr(expr, loc): return .expr(simplify(expr), loc)
  case let .call(name, args, result, loc): return .call(name, args.map{ $0.map(simplify) }, result.map(simplify), loc)
  }
}

public func simplify(_ genericExpr: Expr) -> Expr {
  switch genericExpr {
  case let .int(expr): return .int(simplify(expr))
  case let .list(expr): return .list(simplify(expr))
  case let .bool(expr): return .bool(simplify(expr))
  case let .compound(expr): return .compound(simplify(expr))
  }
}

public func simplify(_ expr: IntExpr) -> IntExpr {
  func binaryOp(_ clhs: IntExpr, _ crhs: IntExpr,
                _ f: (Int, Int) -> Int,
                _ constructor: (IntExpr, IntExpr) -> IntExpr,
                leftIdentity: Int? = nil,
                rightIdentity: Int? = nil) -> IntExpr {
    let (lhs, rhs) = (simplify(clhs), simplify(crhs))
    if case let .literal(lhsValue) = lhs,
       case let .literal(rhsValue) = rhs {
      return .literal(f(lhsValue, rhsValue))
    }
    if let id = leftIdentity, case .literal(id) = lhs {
      return rhs
    }
    if let id = rightIdentity, case .literal(id) = rhs {
      return lhs
    }
    return constructor(lhs, rhs)
  }


  switch expr {
  case .var(_): return expr
  case .literal(_): return expr
  case let .length(of: clist):
    let list = simplify(clist)
    if case let .literal(elems) = list {
      return .literal(elems.count)
    }
    return .length(of: list)
  case let .element(offset, of: clist):
    let list = simplify(clist)
    if case let .literal(elems) = list {
      let normalOffset = offset < 0 ? offset + elems.count : offset
      if 0 <= normalOffset, normalOffset < elems.count,
         let elem = elems[normalOffset] {
        return elem
      }
    }
    return .element(offset, of: list)
  case let .add(clhs, crhs):
    return binaryOp(clhs, crhs, +, IntExpr.add, leftIdentity: 0, rightIdentity: 0)
  case let .sub(clhs, crhs):
    return binaryOp(clhs, crhs, -, IntExpr.sub, rightIdentity: 0)
  case let .mul(clhs, crhs):
    return binaryOp(clhs, crhs, *, IntExpr.mul, leftIdentity: 1, rightIdentity: 1)
  case let .div(clhs, crhs):
    return binaryOp(clhs, crhs, /, IntExpr.div, rightIdentity: 1)
  }
}

public func simplify(_ expr: ListExpr) -> ListExpr {
  struct Break: Error {}
  func tryBroadcast(_ lhs: [IntExpr?], _ rhs: [IntExpr?]) throws -> [IntExpr?] {
    let paddedLhs = Array(repeating: 1, count: max(rhs.count - lhs.count, 0)) + lhs
    let paddedRhs = Array(repeating: 1, count: max(lhs.count - rhs.count, 0)) + rhs
    return try zip(paddedLhs, paddedRhs).map{ (l, r) in
      if (l == nil || l == 1) { return r }
      if (r == nil || r == 1) { return l }
      if (r == l) { return l }
      throw Break()
    }
  }

  switch expr {
  case .var(_): return expr
  case let .literal(subexprs): return .literal(subexprs.map{ $0.map(simplify) })
  case let .broadcast(clhs, crhs):
    let (lhs, rhs) = (simplify(clhs), simplify(crhs))
    if case let .literal(lhsElems) = lhs,
       case let .literal(rhsElems) = rhs {
      if let resultElems = try? tryBroadcast(lhsElems, rhsElems) {
        return .literal(resultElems)
      }
    }
    return .broadcast(lhs, rhs)
  }
}

public func simplify(_ expr: BoolExpr) -> BoolExpr {
  switch expr {
  case .var(_): return expr
  case let .and(subexprs): return .and(subexprs.map(simplify))
  case let .intEq(lhs, rhs): return .intEq(simplify(lhs), simplify(rhs))
  case let .intGt(lhs, rhs): return .intGt(simplify(lhs), simplify(rhs))
  case let .intGe(lhs, rhs): return .intGe(simplify(lhs), simplify(rhs))
  case let .intLt(lhs, rhs): return .intLt(simplify(lhs), simplify(rhs))
  case let .intLe(lhs, rhs): return .intLe(simplify(lhs), simplify(rhs))
  case let .listEq(lhs, rhs): return .listEq(simplify(lhs), simplify(rhs))
  case let .boolEq(lhs, rhs): return .boolEq(simplify(lhs), simplify(rhs))
  }
}

public func simplify(_ expr: CompoundExpr) -> CompoundExpr {
  switch expr {
  case let .tuple(subexprs): return .tuple(subexprs.map{ $0.map(simplify) })
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Complexity measure

// Returns an approximate measure of how hard to read the constraint will be when
// printed. In most cases it's equivalent to simply computing the number of nodes in
// the expression tree, but some rules don't conform to this specification.
extension Constraint {
  var complexity: Int {
    switch self {
    case let .expr(expr, _): return expr.complexity
    case .call(_, _, _, _): return 1
    }
  }
}

extension BoolExpr {
  var complexity: Int {
    switch self {
    case .var(_): return 1
    case let .and(subexprs): return 1 + subexprs.reduce(0, { $0 + $1.complexity })
    case let .intEq(lhs, rhs): fallthrough
    case let .intGt(lhs, rhs): fallthrough
    case let .intGe(lhs, rhs): fallthrough
    case let .intLt(lhs, rhs): fallthrough
    case let .intLe(lhs, rhs):
      return 1 + lhs.complexity + rhs.complexity
    case let .listEq(lhs, rhs):
      return 1 + lhs.complexity + rhs.complexity
    case let .boolEq(lhs, rhs):
      return 1 + lhs.complexity + rhs.complexity
    }
  }
}

extension IntExpr {
  var complexity: Int {
    switch self {
    case .var(_): return 1
    case .literal(_): return 1
    // NB: We don't add one, because both .rank and indexing does not increase
    //     the subjective complexity of the expression significantly
    case let .length(of: list): return list.complexity
    case let .element(_, of: list): return list.complexity
    case let .add(lhs, rhs): fallthrough
    case let .sub(lhs, rhs): fallthrough
    case let .mul(lhs, rhs): fallthrough
    case let .div(lhs, rhs):
      return 1 + lhs.complexity + rhs.complexity
    }
  }
}

extension ListExpr {
  var complexity: Int {
    switch self {
    case .var(_): return 1
    // FIXME: If we changed the way we print list literals to e.g. explode one
    //        element per line then we could take a max instead of a sum here.
    case let .literal(subexprs): return 1 + subexprs.reduce(0, { $0 + ($1?.complexity ?? 1) })
    case let .broadcast(lhs, rhs): return 1 + lhs.complexity + rhs.complexity
    }
  }
}

extension CompoundExpr {
  var complexity: Int {
    switch self {
    case let .tuple(elements): return 1 + elements.reduce(0, { $0 + ($1?.complexity ?? 1) })
    }
  }
}

extension Expr {
  var complexity: Int {
    switch self {
    case let .int(expr): return expr.complexity
    case let .bool(expr): return expr.complexity
    case let .list(expr): return expr.complexity
    case let .compound(expr): return expr.complexity
    }
  }
}
