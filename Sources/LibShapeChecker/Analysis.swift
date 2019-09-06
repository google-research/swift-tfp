import SIL

public struct FunctionSummary {
  let argExprs: [Expr?] // None only for arguments of unsupported types
  let retExpr: Expr?    // None for returns of unsupported types and when we
                        // don't know anything interesting about the returned value
  public let constraints: [Constraint]
}

public typealias StructDecl = [(name: String, type: Type)]

public typealias Environment = [String: FunctionSummary]
public typealias TypeEnvironment = [String: StructDecl]

public class Analyzer {
  public var environment: Environment = [:]
  public var typeEnvironment: TypeEnvironment = [:]

  public init() {}

  let supportedStructDecls: Set = [
    "pattern_binding_decl", "var_decl",
    "constructor_decl", "destructor_decl", "func_decl",
    // TODO: struct/class/enum decl?
  ]
  public func analyze(_ ast: SExpr) {
    guard case let .record("source_file", decls) = ast else {
      // TODO: Warn
      return
    }
    structLoop: for structDecl in decls {
      guard case let .value(.record("struct_decl", structDeclBody)) = structDecl,
                     structDeclBody.count > 2,
            case     .field("range", .sourceRange(_))     = structDeclBody[0],
            case let .value(.string(structName)) = structDeclBody[1] else { continue }
      var fields: StructDecl = []
      for decl in structDeclBody.suffix(from: 2) {
        // Ignore everything that's not a nested record...
        guard case let .value(.record(declName, declBody)) = decl else { continue }
        // but once a record is found, make sure we understand what it means.
        guard          supportedStructDecls.contains(declName) else { continue structLoop }
        // Finally, try to see if it declares a new field.
        guard          declName == "var_decl",
                       declBody.count >= 3,
              case     .field("range", .sourceRange(_))   = declBody[0],
              case let .value(.string(fieldName))         = declBody[1],
              case let .field("type", .string(fieldTypeName)) = declBody[2],
                       declBody.contains(.field("readImpl", .symbol("stored"))),
                   let fieldType = try? Type.parse(fromString: "$" + fieldTypeName) else { continue }
        fields.append((fieldName, fieldType))
      }
      typeEnvironment[structName] = fields
    }
  }

  public func analyze(_ module: Module) {
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
    return abstract(Block(block.identifier, block.arguments, instrDefs), inside: typeEnvironment)
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
func inlineBoolVars(_ constraints: [Constraint]) -> [Constraint] {
  var usedBoolVars = Set<BoolVar>()
  func gatherBoolVars(_ constraint: Constraint) {
    let _ = substitute(constraint) {
      if case let .bool(v) = $0 { usedBoolVars.insert(v) }
      return nil
    }
  }

  var exprs: [BoolVar: BoolExpr] = [:]
  for constraint in constraints {
    if case let .expr(.boolEq(.var(v), expr)) = constraint, exprs[v] == nil {
      exprs[v] = expr
      gatherBoolVars(.expr(expr))
    } else if case .expr(.var(_)) = constraint {
      // Do nothing
    } else {
      gatherBoolVars(constraint)
    }
  }

  return constraints.compactMap { constraint in
    if case let .expr(.boolEq(.var(v), _)) = constraint, !usedBoolVars.contains(v) {
      return nil
    } else if case let .expr(.var(v)) = constraint, !usedBoolVars.contains(v) {
      return exprs[v].map{ .expr($0) } ?? constraint
    }
    return constraint
  }
}


////////////////////////////////////////////////////////////////////////////////
// MARK: - Instantiation of constraints for the call chain

public func instantiate(constraintsOf name: String,
                 inside env: Environment) -> [Constraint] {
  let instantiator = ConstraintInstantiator(name, env)
  return instantiator.constraints
}

infix operator ≡: ComparisonPrecedence

fileprivate func ≡(_ a: Expr, _ b: Expr) -> [Constraint] {
  switch (a, b) {
  case let (.int(a), .int(b)): return [.expr(.intEq(a, b))]
  case let (.list(a), .list(b)): return [.expr(.listEq(a, b))]
  case let (.bool(a), .bool(b)): return [.expr(.boolEq(a, b))]
  case let (.compound(a), .compound(b)):
    switch (a, b) {
    case let (.tuple(aExprs), .tuple(bExprs)):
      guard aExprs.count == bExprs.count else {
        fatalError("Equating incompatible tuple expressions")
      }
      return zip(aExprs, bExprs).flatMap {
        (t: (Expr?, Expr?)) -> [Constraint] in
        guard let aExpr = t.0, let bExpr = t.1 else { return [] }
        return aExpr ≡ bExpr
      }
    }
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
    let subst = makeSubstitution()
    let _ = apply(name, to: summary.argExprs.map{ $0.map{ substitute($0, using: subst) }})
  }

  func makeSubstitution() -> (Var) -> Expr {
    var varMap = DefaultDict<Var, Var>(withDefault: freshVar)
    return { varMap[$0].expr }
  }

  func apply(_ name: String, to args: [Expr?]) -> Expr? {
    guard let summary = environment[name] else { return nil }

    guard !callStack.contains(name) else { return nil }
    callStack.insert(name)
    defer { callStack.remove(name) }

    // Instantiate the constraint system for the callee.
    let subst = makeSubstitution()

    assert(summary.argExprs.count == args.count)
    for (maybeFormal, maybeActual) in zip(summary.argExprs, args) {
      // NB: Only instantiate the mapping for args that have some constraints
      //     associated with them.
      guard let formal = maybeFormal else { continue }
      guard let actual = maybeActual else { continue }
      constraints += substitute(formal, using: subst) ≡ actual
    }

    // Replace the variables in the body of the summary with fresh ones to avoid conflicts.
    for constraint in summary.constraints {
      switch constraint {
      case let .expr(expr):
        constraints.append(.expr(substitute(expr, using: subst)))
      case let .call(name, args, maybeResult):
        let maybeApplyResult = apply(name, to: args.map{ $0.map{substitute($0, using: subst)} })
        if let applyResult = maybeApplyResult,
           let result = maybeResult {
          constraints += substitute(result, using: subst) ≡ applyResult
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
    "(" + argExprs.map{ $0?.description ?? "*" }.joined(separator: ", ") + ") -> " + (retExpr?.description ?? "*")
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
