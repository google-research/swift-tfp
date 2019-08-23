import SIL

public struct FunctionSummary {
  // NB: Can be nil if the argument or return is not a tensor,
  //     or wasn't used in any constraint.
  let argVars: [Var?]
  let retVar: Var?
  public let constraints: [Constraint]
}

public typealias Environment = [String: FunctionSummary]

public class Analyzer {
  public var environment: Environment = [:]

  public init() {}

  public func analyze(module: Module) {
    // TODO: Sort the functions according to the call chain.
    //       Right now the analysis result depends on their order,
    //       which shouldn't be the case!
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
    return abstract(block)
  }

}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Instantiation of constraints for the call chain

public func instantiate(constraintsOf name: String,
                 inside env: Environment) -> [Constraint] {
  let instantiator = ConstraintInstantiator(name, env)
  return instantiator.constraints
}

class ConstraintInstantiator {
  typealias Substitution = DefaultDict<Var, Var>

  let environment: Environment
  var constraints: [Constraint] = []
  var callStack = Set<String>() // To sure we don't recurse

  let freshVar = count(from: 1) >>> Var.init


  init(_ name: String,
       _ env: Environment) {
    self.environment = env
    guard let summary = environment[name] else { return }
    let _ = apply(name, to: summary.argVars)
  }

  func apply(_ name: String, to args: [Var?]) -> Var? {
    guard let summary = environment[name] else { return nil }
    guard !callStack.contains(name) else { return nil }

    callStack.insert(name)
    defer { callStack.remove(name) }

    // Instantiate the constraint system for the callee, by:
    var substitution = Substitution{ [weak self] _ in self!.freshVar() }
    // NB: We pop at the end of the function, hence no defer here.

    // 1. Substituting the formal argument variables for the actual variables.
    assert(summary.argVars.count == args.count)
    for (maybeFormal, maybeActual) in zip(summary.argVars, args) {
      // NB: Only instantiate the mapping for args that have some constraints
      //     associated with them.
      guard let formal = maybeFormal else { continue }
      guard let actual = maybeActual else { continue }
      substitution[formal] = actual
    }

    // 2. Replacing the variables in the body of the summary with fresh versions.
    for constraint in summary.constraints {
      switch constraint {
      case let .expr(expr):
        constraints.append(.expr(substitute(expr, using: { substitution[$0] })))
      case let .call(name, args, maybeResult):
        let maybeApplyResult = apply(name, to: args)
        if let applyResult = maybeApplyResult,
           let result = maybeResult {
          substitution[result] = applyResult
        }
      }
    }

    guard let result = summary.retVar else { return nil }
    return substitution[result]
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - CustomStringConvertible instances

extension FunctionSummary: CustomStringConvertible {
  fileprivate func describeOptVar(_ v: Var?) -> String { v == nil ? "*" : v!.description }
  fileprivate var signature: String {
    "(" + argVars.map(describeOptVar).joined(separator: ", ") + ") -> " + describeOptVar(retVar)
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
