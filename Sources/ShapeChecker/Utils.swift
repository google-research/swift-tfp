extension String {
  func leftPad(to: Int, with: Character = " ") -> String {
    let toPad = max(to - count, 0)
    if toPad > 0 {
      return String(repeating: with, count: toPad) + self
    } else {
      return self
    }
  }
}

struct Colors {
  // XXX: This doesn't nest well!
  static func withColor(_ color: String, _ f: () throws -> ()) rethrows {
    code("0;\(color)")
    do {
      try f()
    } catch {
      code("0")
      throw error
    }
    code("0")
  }

  static func withBlue(_ f: () throws -> ()) rethrows {
    try withColor("34", f)
  }

  static func withGray(_ f: () throws -> ()) rethrows {
    try withColor("90", f)
  }

  static func withBold(_ f: () throws -> ()) rethrows {
    try withColor("1", f)
  }

  static func code(_ code: String) {
    // TODO: Check isatty
    print("\u{001B}[\(code)m", terminator: "")
  }
}

struct LineCache {
  var lines: [String: [String]] = [:]

  mutating func print(_ path: String, line: Int) throws {
    if !lines.keys.contains(path) {
      let data = try String(contentsOfFile: path, encoding: .utf8)
      lines[path] = Array(data.split(separator: "\n", omittingEmptySubsequences: false)).map{ String($0) }
    }
    let file = lines[path]!
    let inBounds = { 0 <= $0 && $0 < file.count }
    Colors.withBlue {
      Swift.print("            | ", terminator: "")
    }
    if inBounds(line - 2) {
      Colors.withGray {
        Swift.print(file[line - 2])
      }
    }
    Colors.withBlue {
      Swift.print("      \(line.description.leftPad(to: 5)) | ", terminator: "")
    }
    if inBounds(line - 1) {
      Swift.print(file[line - 1])
    }
    Colors.withBlue {
      Swift.print("            | ", terminator: "")
    }
    if inBounds(line) {
      Colors.withGray {
        Swift.print(file[line])
      }
    }
  }
}

