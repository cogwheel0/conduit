//
//  WeakArray.swift
//  flutter_callkit_incoming
//
//  Created by Mostafa Ibrahim on 18/01/2023.
//

import Foundation

class WeakBox<T:AnyObject> {
    weak var unbox: T?
    init(_ value: T?) {
        unbox = value
    }
}

struct WeakArray<T: AnyObject> {
    private var items: [WeakBox<T>] = []

    init(_ elements: [T]) {
        items = elements.map { WeakBox($0) }
    }

    init(_ elements: [T?]) {
        items = elements.map { WeakBox($0) }
    }

    mutating func append(_ obj:T?) {
        items.append(WeakBox(obj))
    }

    mutating func remove(at:Int) {
        items.remove(at: at)
    }
    
    mutating func reap() -> Self {
        items = items.filter { nil != $0.unbox }
        return self
    }
}

extension WeakArray: Collection {
    var startIndex: Int { return items.startIndex }
    var endIndex: Int { return items.endIndex }

    subscript(_ index: Int) -> T? {
        return items[index].unbox
    }

    func index(after idx: Int) -> Int {
        return items.index(after: idx)
    }
}
