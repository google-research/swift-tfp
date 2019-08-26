@testable import LibShapeChecker
import SIL
import SPMUtility

func main() {
  let parser = ArgumentParser(usage: "<SIL path>",
                              overview: "Static analysis tool for verifying tensor shapes in Swift programs")
  let fileNameOpt = parser.add(positional: "<SIL path>", kind: String.self, usage: "Path to the analyzed SIL file")
  let showSignaturesOpt = parser.add(option: "--signatures", kind: Bool.self, usage: "Show constraint signatures")

  let args: ArgumentParser.Result
  do {
    args = try parser.parse(Array(CommandLine.arguments.dropFirst()))
  } catch {
    print(error)
    return
  }
  let fileName = args.get(fileNameOpt)!
  let showSignatures = args.get(showSignaturesOpt) ?? false

  let module: Module
  do {
    module = try Module.parse(fromSILPath: fileName)
  } catch {
    print("Error encountered during SIL module parsing: ", terminator: "")
    print(error)
    return
  }

  let analyzer = Analyzer()
  analyzer.analyze(module: module)
  for (fn, signature) in analyzer.environment.sorted(by: { $0.0 < $1.0 }) {
    guard !signature.constraints.isEmpty else { continue }
    print("")
    print(fn)
    if (showSignatures) {
      print(signature.prettyDescription)
    }
    let constraints = instantiate(constraintsOf: fn, inside: analyzer.environment)
    switch verify(constraints) {
    case .sat:
      print("✅ Constraints are satisfiable!")
    case .unknown:
      print("❔ Can't solve the constraint system")
    case let .unsat(maybeCore):
      if let core = maybeCore {
        print("❌ Derived a contradiction from:")
        for expr in core {
          print("  - \(expr)")
        }
      } else {
        print("⚠️ Found a contradiction, but I can't explain!")
      }
    }
  }

}

main()
