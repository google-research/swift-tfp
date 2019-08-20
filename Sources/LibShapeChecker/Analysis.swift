import SIL

public struct FunctionSummary {
  // NB: Can be nil if the argument or return is not a tensor,
  //     or wasn't used in any constraint.
  let argVars: [ShapeVar?]
  let retVar: ShapeVar?
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
      analyze(function: f)
    }
  }

  func analyze(function: Function) {
    guard function.blocks.count == 1 else { return }
    let maybeSummary = analyze(block: function.blocks[0])
    environment[function.name] = maybeSummary
  }

  func analyze(block: Block) -> FunctionSummary? {
    guard block.instructionDefs.count > 0 else { fatalError("Empty block??") }
    let constraints = gatherConstraints(block: block)
    let result: Register?
    switch block.instructionDefs.last!.instruction {
    case let .return(operand):
      result = isTensorType(operand.type) ? operand.value : nil
    default:
      return nil
    }
    let arguments = block.arguments.map{ isTensorType($0.type) ? $0.valueName : nil }
    return abstract(constraints: constraints,
                    overSignature: (arguments: arguments, result: result),
                    inEnvironment: environment)
  }

}

fileprivate func isTensorType(_ type: Type) -> Bool {
  // TODO: This switch can be a regular equality, but Type
  //       does not implement Equatable at the moment
  switch type {
  case .specializedType(.namedType("Tensor"), _): return true
  default: return false
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - CustomStringConvertible instances

extension FunctionSummary: CustomStringConvertible {
  fileprivate func describeOptVar(_ v: ShapeVar?) -> String { v == nil ? "*" : v!.description }
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
