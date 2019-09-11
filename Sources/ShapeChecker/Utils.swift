import LibShapeChecker

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

  static func withYellow(_ f: () throws -> ()) rethrows {
    try withColor("33", f)
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

  mutating func print(_ location: SourceLocation?, leftPadding: Int) {
    guard case let .file(path, line: line) = location else { return }
    if !lines.keys.contains(path) {
      guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return }
      lines[path] = Array(data.split(separator: "\n", omittingEmptySubsequences: false)).map{ String($0) }
    }
    let padding = String(repeating: " ", count: leftPadding)
    let file = lines[path]!
    let inBounds = { 0 <= $0 && $0 < file.count }
    Colors.withBlue {
      Swift.print("\(padding)      | ", terminator: "")
    }
    if inBounds(line - 2) {
      Colors.withGray {
        Swift.print(file[line - 2])
      }
    }
    Colors.withBlue {
      Swift.print("\(padding)\(line.description.leftPad(to: 5)) | ", terminator: "")
    }
    if inBounds(line - 1) {
      Swift.print(file[line - 1])
    }
    Colors.withBlue {
      Swift.print("\(padding)      | ", terminator: "")
    }
    if inBounds(line) {
      Colors.withGray {
        Swift.print(file[line])
      }
    }
  }
}

