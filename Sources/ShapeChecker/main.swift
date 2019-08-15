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

  Analyzer().analyze(module: module)
}

main()
