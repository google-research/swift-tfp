public struct Warning {
  let issue: String
  let location: SourceLocation?
}

let nextId = count(from: 0)
var recordingLists: [Int: [Warning]] = [:]

func captureWarnings(_ f: () throws -> ()) rethrows -> [Warning] {
  let listId = nextId()
  recordingLists[listId] = []
  defer { recordingLists[listId] = nil }
  try f()
  return recordingLists[listId]!
}

func warn(_ issue: String, _ location: SourceLocation?) {
  for id in recordingLists.keys {
    recordingLists[id]! += [Warning(issue: issue, location: location)]
  }
}
