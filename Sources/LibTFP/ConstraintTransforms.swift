// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
  // TODO: Origin and stack don't matter
  return constraints.compactMap {
    guard !seen.contains($0) else { return nil }
    seen.insert($0)
    return $0
  }
}

// Preprocess constraints to find the weakest assumption under which a
// variable is used. This is useful, because it allows us to e.g. inline
// equalities when we have a guarantee that all users of a variable have
// to satisfy the same assumption that the equality does.
func computeWeakestAssumptions(_ constraints: [Constraint]) -> [Var: BoolExpr] {
  var userAssumptions = DefaultDict<Var, Set<BoolExpr>>{ _ in [] }
  for constraint in constraints {
    switch constraint {
    case let .expr(expr, assuming: cond, _, _):
      let _ = substitute(expr, using: {
        userAssumptions[$0].insert(cond)
        return nil
      })
    }
  }

  var weakestAssumption: [Var: BoolExpr] = [:]
  for entry in userAssumptions.dictionary {
    let assumptions = entry.value.sorted(by: { $0.description < $1.description })
    var currentWeakest = assumptions[0]
    for assumption in assumptions.suffix(from: 1) {
      if assumption =>? currentWeakest {
        continue
      } else if currentWeakest =>? assumption {
        currentWeakest = assumption
      } else {
        currentWeakest = .true
      }
    }
    weakestAssumption[entry.key] = currentWeakest
  }

  return weakestAssumption
}

// Tries to iteratively go over expressions, simplify them, and in case they
// equate a variable with an expression, inline the definition of this variable
// into all following constraints.
func inline(_ originalConstraints: [Constraint],
            canInline: (Constraint) -> Bool = { $0.complexity <= 20 },
            simplifying shouldSimplify: Bool = true) -> [Constraint] {
  // NB: It is safe to reuse this accross iterations.
  let weakestAssumption = computeWeakestAssumptions(originalConstraints)
  let simplifyExpr: (Expr) -> Expr = shouldSimplify ? simplify : { $0 }
  let simplifyConstraint: (Constraint) -> Constraint = shouldSimplify ? simplify : { $0 }

  var constraints = originalConstraints
  while true {
    var inlined: [Var: Expr] = [:]
    var inlineForbidden = Set<Var>()

    func subst(_ v: Var) -> Expr? {
      if let replacement = inlined[v] {
        return replacement
      }
      inlineForbidden.insert(v)
      return nil
    }

    func tryInline(_ v: Var, _ originalExpr: Expr, assuming cond: BoolExpr) -> Bool {
      guard !inlined.keys.contains(v),
            weakestAssumption[v]! =>? cond else { return false }
      let expr = simplifyExpr(substitute(originalExpr, using: subst))
      // NB: The substitution above might have added the variable to inlineForbidden
      guard !inlineForbidden.contains(v) else { return false }
      inlined[v] = expr
      return true
    }

    constraints = constraints.compactMap { constraint in
      if canInline(constraint) {
        let cond = constraint.assumption
        switch constraint.expr {
        case let .listEq(.var(v), expr),
             let .listEq(expr, .var(v)):
          if tryInline(.list(v), .list(expr), assuming: cond) { return nil }
        case let .intEq(.var(v), expr),
             let .intEq(expr, .var(v)):
          if tryInline(.int(v), .int(expr), assuming: cond) { return nil }
        case let .boolEq(.var(v), expr),
             let .boolEq(expr, .var(v)):
          if tryInline(.bool(v), .bool(expr), assuming: cond) { return nil }
        default: break
        }
      }
      return simplifyConstraint(substitute(constraint, using: subst))
    }
    if inlined.isEmpty { break }
  }
  return constraints
}

// Assertion instantiations produce patterns of the form:
// b4 = <cond>, b4
// This function tries to find those and inline the conditions.
public func inlineBoolVars(_ constraints: [Constraint]) -> [Constraint] {
  return inline(constraints, canInline: {
    switch $0 {
    case .expr(.boolEq(.var(_), _), assuming: _, _, _): return true
    case .expr(.boolEq(_, .var(_)), assuming: _, _, _): return true
    default: return false
    }
  }, simplifying: false)
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Simplification

// Simplifies the constraint without any additional context. For example
// a subexpression [1, 2, 3][1] will get replaced by 2.
public func simplify(_ constraint: Constraint) -> Constraint {
  switch constraint {
  case let .expr(expr, assuming: cond, origin, stack):
    return .expr(simplify(expr), assuming: simplify(cond), origin, stack)
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
  case .hole(_): return expr
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
  case .true: return expr
  case .false: return expr
  case .var(_): return expr
  case let .not(.not(subexpr)): return simplify(subexpr)
  case let .not(subexpr): return .not(simplify(subexpr))
  // TODO: Collapse and/or trees and filter out true/false
  case let .and(subexprs): return .and(subexprs.map(simplify))
  case let .or(subexprs): return .or(subexprs.map(simplify))
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
    case let .expr(expr, assuming: _, _, _): return expr.complexity
    }
  }
}

extension BoolExpr {
  var complexity: Int {
    switch self {
    case .true: return 1
    case .false: return 1
    case .var(_): return 1
    case let .not(subexpr): return 1 + subexpr.complexity
    case let .and(subexprs): fallthrough
    case let .or(subexprs): return 1 + subexprs.reduce(0, { $0 + $1.complexity })
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
    case .hole(_): return 1
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
