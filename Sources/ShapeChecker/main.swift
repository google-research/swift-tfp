import LibShapeChecker
import SIL
import SPMUtility

func main() {
  let parser = ArgumentParser(usage: "<SIL path>",
                              overview: "Static analysis tool for verifying tensor shapes in Swift programs")
  let fileNameOpt = parser.add(positional: "<SIL path>", kind: String.self, usage: "Path to the analyzed SIL file")

  let args: ArgumentParser.Result
  do {
    args = try parser.parse(Array(CommandLine.arguments.dropFirst()))
  } catch {
    print(error)
    return
  }
  let fileName = args.get(fileNameOpt)!

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
    print("")
    print(fn)
    print(signature.prettyDescription)
    do {
      var model = Model()
      try model.restrict(with: signature.constraints)
    } catch let error as Inconsistency {
      print("Found a shape error: \(error)")
      continue
    } catch {
      print("Unexpected error: \(error)")
      continue
    }
    print("Constraint check passed!")
  }

}

main()
