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
