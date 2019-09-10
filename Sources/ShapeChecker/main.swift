@testable import LibShapeChecker
import SIL
import SPMUtility

let processCore = deduplicate >>> { inline($0) } >>> alphaNormalize

@available(macOS 10.13, *)
func main() {
  let parser = ArgumentParser(usage: "<SIL path>",
                              overview: "Static analysis tool for verifying tensor shapes in Swift programs")
  let fileNameOpt = parser.add(positional: "<SIL path>", kind: String.self, usage: "Path to the analyzed SIL file")
  let showSignaturesOpt = parser.add(option: "--signatures", kind: Bool.self, usage: "Show constraint signatures")
  let showStacksOpt = parser.add(option: "--stacks", kind: Bool.self, usage: "Show full call stacks associated with each contradictory constraint")

  let args: ArgumentParser.Result
  do {
    args = try parser.parse(Array(CommandLine.arguments.dropFirst()))
  } catch {
    print(error)
    return
  }
  let fileName = args.get(fileNameOpt)!
  let showSignatures = args.get(showSignaturesOpt) ?? false
  let showStacks = args.get(showStacksOpt) ?? false

  do {
    var lineCache = LineCache()
    try withSIL(forFile: fileName) { module, silPath in
      let analyzer = Analyzer()
      try withAST(forSILPath: silPath) { ast in
        analyzer.analyze(ast)
      }

      analyzer.analyze(module)
      for (fn, signature) in analyzer.environment.sorted(by: { $0.0 < $1.0 }) {
        let nontrivialSignature = signature.retExpr != nil && signature.argExprs.contains(where: { $0 != nil })
        guard !signature.constraints.isEmpty || nontrivialSignature else { continue }
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
            for constraint in processCore(core) {
              guard case let .expr(expr, origin, loc) = constraint else {
                fatalError("Unexpected constraint type in the unsat core!")
              }
              let locExplanation: String
              switch origin {
              case .implied: locExplanation = "Implied by"
              case .asserted: locExplanation = "Asserted at"
              }
              Colors.withBold {
                print("  - \(expr)")
              }
              if showStacks {
                let stack = loc.stack
                for frame in stack[..<(stack.count - 1)] {
                  print("      Called from \(frame):")
                }
              }
              print("      \(locExplanation) \(loc):")
              if case let .file(path, line: line, parent: _) = loc {
                try? lineCache.print(path, line: line)
              }
            }
          } else {
            print("⚠️ Found a contradiction, but I can't explain!")
          }
        }
      }
    }
  } catch {
    print("An error occured: \(error)")
  }

}

if #available(macOS 10.13, *) {
  main()
} else {
  print("Unsupported platform!")
}
