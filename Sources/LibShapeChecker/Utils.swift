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

// Helpful type aliases
typealias Register = String

// Function composition operator.
// NB: To the best of my knowledge it's impossible make it fully polymorphic
//     (e.g. in the number of arguments), so if you need more cases feel free
//     to add them below!
infix operator .>>: FunctionComposition
infix operator >>>: FunctionComposition

precedencegroup FunctionComposition {
  associativity: left
}

@inlinable
func >>><A, B, C>(_ f: @escaping (A) -> B, _ h: @escaping (B) -> C) -> (A) -> C {
  return { h(f($0)) }
}

@inlinable
func .>><B, C>(_ f: @escaping () -> B, _ h: @escaping (B) -> C) -> () -> C {
  return { h(f()) }
}

// An infinite stream of integers.
func count(from: Int, by: Int = 1) -> (() -> Int) {
  var current = from
  let f = { () -> Int in
    let r = current
    current += by
    return r
  }
  return f
}

// A dictionary with an infallible subscript.
struct DefaultDict<K : Hashable, V> {
  private var dict: [K: V] = [:]
  private var defaultConstructor: (K) -> V
  var dictionary: [K: V] { dict }

  init(withDefault constructor: @escaping (K) -> V) {
    self.defaultConstructor = constructor
  }

  subscript(_ key: K) -> V {
    mutating get {
      if dict[key] == nil { dict[key] = defaultConstructor(key) }
      return dict[key]!
    }
    set(value) {
      dict[key] = value
    }
  }

  func lookup(_ key: K) -> V? {
    return dict[key]
  }

  mutating func remove(_ key: K) {
    dict[key] = nil
  }
}

extension Array {
  var only: Element? { count != 1 ? nil : first }
}

extension Set {
  var only: Element? { count != 1 ? nil : first }
}
