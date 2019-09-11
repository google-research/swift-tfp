@testable import LibShapeChecker
import SIL
import SPMUtility

let processCore = deduplicate >>> { inline($0) } >>> alphaNormalize
var lineCache = LineCache()

// Command line options
var fileName: String!
var showSignatures: Bool!
var showStacks: Bool!
var showWarnings: Bool!

@available(macOS 10.13, *)
func main() {
  parseArgs()
  do {
    try withSIL(forFile: fileName) { module, silPath in
      let analyzer = Analyzer()
      try withAST(forSILPath: silPath) { ast in
        analyzer.analyze(ast)
      }

      analyzer.analyze(module)
      for (fn, signature) in analyzer.environment.sorted(by: { $0.0 < $1.0 }) {
        guard shouldVerify(signature) else { continue }

        Colors.withBold {
          print("\n\(fn)")
        }

        if showSignatures {
          print(signature.prettyDescription)
        }

        let constraints = instantiate(constraintsOf: fn, inside: analyzer.environment)
        if showWarnings {
          printWarnings(analyzer.warnings[fn, default: []], constraints)
        }
        check(constraints)
      }
    }
  } catch {
    print("An error occured: \(error)")
  }
}

func shouldVerify(_ signature: FunctionSummary) -> Bool {
  let nontrivialSignature =
    signature.retExpr != nil &&
    signature.argExprs.contains(where: { $0 != nil })
  return !signature.constraints.isEmpty || nontrivialSignature
}

func printWarnings(_ frontendWarnings: [Warning], _ constraints: [Constraint]) {
  let constraintWarnings = captureWarnings {
    warnAboutUnresolvedAsserts(constraints)
  }
  for warning in frontendWarnings + constraintWarnings {
    print("⚠️ ", terminator: "")
    Colors.withBold { Colors.withYellow {
      print(" Warning: ", terminator: "")
    }}
    print(warning.issue)
    if case let .file(path, line: line, parent: _) = warning.location {
      try? lineCache.print(path, line: line, leftPadding: 2)
    }
  }
}

func check(_ constraints: [Constraint]) {
  switch verify(constraints) {
  case let .sat(maybeHoles):
    print("✅ Constraints are satisfiable!")
    guard let holes = maybeHoles else {
      return print("  ⚠️ Failed to analyze legal hole values")
    }
    for (location, value) in holes {
      switch value {
      case .anything:
        print(" - The hole at \(location) can take an arbitrary value")
      case let .examples(examples):
        let examplesDesc = examples.map{ $0.description }.joined(separator: ", ")
        print("  - Some example values that the hole at \(location) might take are: \(examplesDesc)")
      case let .only(value):
        print("  - The hole at \(location) has to be exactly \(value)")
      }
      if case let .file(path, line: line, parent: _) = location {
        try? lineCache.print(path, line: line, leftPadding: 2)
      }
    }
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
          try? lineCache.print(path, line: line, leftPadding: 6)
        }
      }
    } else {
      print("⚠️ Found a contradiction, but I can't explain!")
    }
  }
}

func parseArgs() {
  let parser = ArgumentParser(usage: "<SIL path>",
                              overview: "Static analysis tool for verifying tensor shapes in Swift programs")
  let fileNameOpt = parser.add(positional: "<SIL path>", kind: String.self, usage: "Path to the analyzed SIL file")
  let showSignaturesOpt = parser.add(option: "--signatures", kind: Bool.self, usage: "Show constraint signatures")
  let showStacksOpt = parser.add(option: "--stacks", kind: Bool.self, usage: "Show full call stacks associated with each contradictory constraint")
  let WnoneOpt = parser.add(option: "-Wnone", kind: Bool.self, usage: "Don't display warnings")

  let args: ArgumentParser.Result
  do {
    args = try parser.parse(Array(CommandLine.arguments.dropFirst()))
  } catch {
    print(error)
    return
  }
  fileName = args.get(fileNameOpt)!
  showSignatures = args.get(showSignaturesOpt) ?? false
  showStacks = args.get(showStacksOpt) ?? false
  showWarnings = !(args.get(WnoneOpt) ?? false)
}

if #available(macOS 10.13, *) {
  main()
} else {
  print("Unsupported platform!")
}
