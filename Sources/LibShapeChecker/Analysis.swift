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
