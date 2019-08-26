class UnionFind<T> {
  var parent: UnionFind<T>?
  var size: Int = 1 // XXX: This is only accurate if parent == nil
  var value: T
  init(_ value: T) {
    self.value = value
  }
}

@discardableResult
func union<T>(_ a: UnionFind<T>, _ b: UnionFind<T>) -> (parent: UnionFind<T>, child: UnionFind<T>)? {
  var ar = find(a)
  var br = find(b)
  guard ar !== br else { return nil }
  if ar.size < br.size {
    swap(&ar, &br)
  }
  br.parent = ar
  ar.size += br.size
  return (parent: ar, child: br)
}

fileprivate func find<T>(_ a: UnionFind<T>) -> UnionFind<T> {
  var x = a
  while true {
    guard let y = x.parent else { break }
    x.parent = y.parent ?? y
    x = y
  }
  return x
}

func equivalent<T>(_ a: UnionFind<T>, _ b: UnionFind<T>) -> Bool {
  return find(a) === find(b)
}

func representative<T>(_ a: UnionFind<T>) -> T {
  return find(a).value
}

func value<T>(_ a: UnionFind<T>) -> T {
  return a.value
}
