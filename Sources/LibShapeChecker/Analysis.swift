import SIL

public struct FunctionSummary {
  let argVars: [Var?] // None only for arguments of unsupported types
  let retExpr: Expr?  // None for returns of unsupported types and when we
                      // don't know anything interesting about the returned value
  public let constraints: [Constraint]
}

public typealias Environment = [String: FunctionSummary]

public class Analyzer {
  public var environment: Environment = [:]

  public init() {}

  public func analyze(module: Module) {
    for f in module.functions {
      analyze(f)
    }
  }

  func analyze(_ function: Function) {
    guard function.blocks.count == 1 else { return }
    let maybeSummary = analyze(function.blocks[0])
    environment[function.name] = maybeSummary
  }

  func analyze(_ block: Block) -> FunctionSummary? {
    let instrDefs = normalizeArrayLiterals(block.instructionDefs)
    return abstract(Block(block.identifier, block.arguments, instrDefs))
  }

}

func simplify(_ constraints: [Constraint]) -> [Constraint] {
  var equalityClasses = DefaultDict<Var, UnionFind<Var>>{ UnionFind($0) }

  let subset: [Constraint] = constraints.compactMap { (constraint: Constraint) -> Constraint? in
    switch constraint {
    case let .expr(expr):
      switch expr {
      case let .listEq(.var(lhs), .var(rhs)):
        union(equalityClasses[.list(lhs)], equalityClasses[.list(rhs)])
        return nil
      case let .intEq(.var(lhs), .var(rhs)):
        union(equalityClasses[.int(lhs)], equalityClasses[.int(rhs)])
        return nil
      case let .boolEq(.var(lhs), .var(rhs)):
        union(equalityClasses[.bool(lhs)], equalityClasses[.bool(rhs)])
        return nil
      default:
        return .expr(expr)
      }
    case .call(_, _, _):
      return nil
    }
  }

  return subset.map {
    substitute($0, using: { representative(equalityClasses[$0]).expr })
  }
}


////////////////////////////////////////////////////////////////////////////////
// MARK: - Instantiation of constraints for the call chain

public func instantiate(constraintsOf name: String,
                 inside env: Environment) -> [Constraint] {
  let instantiator = ConstraintInstantiator(name, env)
  return instantiator.constraints
}

fileprivate func ==(_ a: Expr, _ b: Expr) -> BoolExpr {
  switch (a, b) {
  case let (.int(a), .int(b)): return .intEq(a, b)
  case let (.list(a), .list(b)): return .listEq(a, b)
  case let (.bool(a), .bool(b)): return .boolEq(a, b)
  default: fatalError("Equating expressions of different types!")
  }
}

class ConstraintInstantiator {
  let environment: Environment
  var constraints: [Constraint] = []
  var callStack = Set<String>() // To sure we don't recurse
  let freshVar = makeVariableGenerator()

  init(_ name: String,
       _ env: Environment) {
    self.environment = env
    guard let summary = environment[name] else { return }
    let _ = apply(name, to: summary.argVars.map{ $0.map{ freshVar($0).expr } })
  }

  func apply(_ name: String, to args: [Expr?]) -> Expr? {
    guard let summary = environment[name] else { return nil }

    guard !callStack.contains(name) else { return nil }
    callStack.insert(name)
    defer { callStack.remove(name) }

    // Instantiate the constraint system for the callee.
    var varMap = DefaultDict<Var, Var>(withDefault: freshVar)
    let subst = { varMap[$0].expr }

    assert(summary.argVars.count == args.count)
    for (maybeFormal, maybeActual) in zip(summary.argVars, args) {
      // NB: Only instantiate the mapping for args that have some constraints
      //     associated with them.
      guard let formal = maybeFormal else { continue }
      guard let actual = maybeActual else { continue }
      constraints.append(.expr(varMap[formal].expr == actual))
    }

    // Replace the variables in the body of the summary with fresh ones to avoid conflicts.
    for constraint in summary.constraints {
      switch constraint {
      case let .expr(expr):
        constraints.append(.expr(substitute(expr, using: subst)))
      case let .call(name, args, maybeResult):
        // TODO: Add an extension on Substitution type
        let maybeApplyResult = apply(name, to: args.map{ $0.map{substitute($0, using: subst)} })
        if let applyResult = maybeApplyResult,
           let result = maybeResult {
          constraints.append(.expr(substitute(result, using: subst) == applyResult))
        }
      }
    }

    guard let result = summary.retExpr else { return nil }
    return substitute(result, using: subst)
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - CustomStringConvertible instances

extension FunctionSummary: CustomStringConvertible {
  fileprivate var signature: String {
    "(" + argVars.map{ $0?.description ?? "*" }.joined(separator: ", ") + ") -> " + (retExpr?.description ?? "*")
  }
  public var description: String {
    guard !constraints.isEmpty else { return signature }
    return constraints.description + " => " + signature
  }
  public var prettyDescription: String {
    guard constraints.count > 4 else { return description }
    return "[" + constraints.map{ $0.description }.joined(separator: ",\n ") + "] => " + signature
  }
}
