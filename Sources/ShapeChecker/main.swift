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

// TODO: Remove @testable!!
@testable import LibShapeChecker
import SIL
import SPMUtility

// TODO: Would it be safe to strip all the assumptions in the core?
//       If the cores are guaranteed to be _minimal_ then I think so,
//       but otherwise no.
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
        let constraints = instantiate(constraintsOf: fn, inside: analyzer.environment)

        guard shouldShow(fn, analyzer, constraints) else { continue }

        Colors.withBold {
          print("\n\(fn)")
        }

        if showSignatures {
          print(signature.prettyDescription)
        }

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

func shouldShow(_ name: String, _ analyzer: Analyzer, _ constraints: [Constraint]) -> Bool {
  return showSignatures ||
         constraints.contains(where: { $0.origin != .implied }) ||
         !(analyzer.warnings[name]?.isEmpty ?? true)
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
    lineCache.print(warning.location, leftPadding: 2)
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
      lineCache.print(location, leftPadding: 2)
    }
  case .unknown:
    print("❔ Can't solve the constraint system")
  case let .unsat(maybeCore):
    if let core = maybeCore {
      print("❌ Derived a contradiction from:")
      for constraint in processCore(core) {
        guard case let .expr(expr, assuming: _, origin, stack) = constraint else {
          fatalError("Unexpected constraint type in the unsat core!")
        }
        Colors.withBold {
          print("  - \(expr)")
        }
        if showStacks {
          let callLocations = stack.callLocations
          for frame in callLocations[..<(callLocations.count - 1)] {
            print("      Called from \(frame?.description ?? "<unknown>"):")
          }
        }
        switch origin {
        case .implied: print("      Implied by ", terminator: "")
        case .asserted: print("      Asserted at ", terminator: "")
        }
        switch stack {
        case .top: print("an unknown location")
        case let .frame(location, caller: _):
          print(location?.description ?? "an unknown location")
          lineCache.print(location, leftPadding: 6)
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
