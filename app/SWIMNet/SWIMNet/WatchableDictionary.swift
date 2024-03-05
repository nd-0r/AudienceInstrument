//
//  WatchableDictionary.swift
//  SWIMNet
//
//  Created by Andrew Orals on 2/25/24.
//

import Foundation

protocol DidUpdateCallbackProtocol {
    func didUpdate() -> Void
}

protocol WatchableDictionaryProtocol: Sequence, IteratorProtocol {
    associatedtype K: Hashable & Comparable & Sendable
    associatedtype V: Sendable

    var keys: Dictionary<K, V>.Keys { get }
    var dict: Dictionary<K, V> { get }
    var didUpdateCallback: DidUpdateCallbackProtocol { get }
    var updateThreshold: UInt { get set }
    subscript(key: K) -> V? { get set }
}

class WatchableDictionary<K: Hashable & Comparable & Sendable, V: Sendable>: WatchableDictionaryProtocol {
    typealias Element = (K, V)
    typealias Dict = Dictionary<K, V>

    private struct DefaultDidUpdateCallback: DidUpdateCallbackProtocol {
        func didUpdate() -> Void { }
    }

    var keys: Dictionary<K, V>.Keys { get { self.dict.keys } }
    var didUpdateCallback: DidUpdateCallbackProtocol
    private var _updateThreshold: UInt
    var updateThreshold: UInt {
        get { _updateThreshold }
        set {
            // cannot lower threshold
            if newValue > _updateThreshold {
                _updateThreshold = newValue
            }
        }
    }

    private var updates = 0
    private(set) var dict: Dictionary<K, V>
    private var dictIter: Dictionary<K, V>.Iterator?

    init(
        updateThreshold: UInt = 0,
        didUpdateCallback didUpdate: DidUpdateCallbackProtocol = DefaultDidUpdateCallback(),
        backingDict dict: Dictionary<K, V> = [K:V]()
    ) {
        self._updateThreshold = updateThreshold
        self.didUpdateCallback = didUpdate
        self.dict = dict
    }

    subscript(key:K) -> V? {
        get {
            return dict[key]
        } set {
            // if newValue is nil then about to remove key
            dict[key] = newValue
            update()
        }
    }

    func batchUpdate(keyValuePairs: [(K, V)]) -> Void {
        guard !keyValuePairs.isEmpty else {
            return
        }

        for (key, value) in keyValuePairs {
            dict[key] = value
        }
        update()
    }

    func next() -> (K, V)? {
        guard dictIter != nil else {
            dictIter = dict.makeIterator()
            return dictIter!.next()
        }

        return dictIter!.next()
    }

    private func update() {
        updates += 1

        if updates > updateThreshold {
            didUpdateCallback.didUpdate()
            updates = 0
        }
    }
}
