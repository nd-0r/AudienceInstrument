//
//  RingBuffer.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 4/13/24.
//

// The following adapted from QuantumLeaps lock-free-ring-buffer

/*============================================================================
* Lock-Free Ring Buffer (LFRB) for embedded systems
* GitHub: https://github.com/QuantumLeaps/lock-free-ring-buffer
*
*                    Q u a n t u m  L e a P s
*                    ------------------------
*                    Modern Embedded Software
*
* Copyright (C) 2005 Quantum Leaps, <state-machine.com>.
*
* SPDX-License-Identifier: MIT
*
* Permission is hereby granted, free of charge, to any person obtaining a
* copy of this software and associated documentation files (the "Software"),
* to deal in the Software without restriction, including without limitation
* the rights to use, copy, modify, merge, publish, distribute, sublicense,
* and/or sell copies of the Software, and to permit persons to whom the
* Software is furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
* DEALINGS IN THE SOFTWARE.
============================================================================*/

import Foundation

class RingBuffer<T> {
    private var buf: UnsafeMutablePointer<T>! = nil
    private var end: Int
    private var head: Int = 0
    private var tail: Int = 0

    init(capacity: Int) {
        guard capacity > 0 else {
            fatalError("\(String(describing: Self.self)): Capacity must be greater than 0.")
        }

        self.end = capacity
        self.buf = UnsafeMutablePointer<T>.allocate(capacity: capacity)
    }

    deinit {
        self.buf?.deallocate()
    }

// MARK: Thread-safe interface

    @discardableResult
    func pushFront(element: T) -> Bool {
        var head = self.head + 1
        if head == self.end {
            head = 0
        }

        if head != self.tail { /* buffer NOT full? */
            self.buf[self.head] = element /* copy the element into the buffer */
            self.head = head /* update the head to a *valid* index */
            return true  /* element placed in the buffer */
        } else {
            return false /* element NOT placed in the buffer */
        }
    }

    @discardableResult
    func popBack() -> T? {
        var tail = self.tail
        if (self.head != tail) { /* ring buffer NOT empty? */
            let out = self.buf[tail]

            tail += 1

            if (tail == self.end) {
                tail = 0
            }
            self.tail = tail /* update the tail to a *valid* index */
            return out
        } else {
            return nil
        }
    }

    func numFree() -> Int {
        let head = self.head
        let tail = self.tail

        if head == tail {
            return self.end - 1
        } else if head < tail {
            return tail - head - 1
        } else {
            return self.end + tail - head - 1
        }
    }

// MARK: NOT Thread-safe interface

    var count: Int {
        if head == tail {
            return 0
        } else if head < tail {
            return self.end - tail + head
        } else {
            return self.head - self.tail
        }
    }

    func toArray() -> [T] {
        var out: [T] = []

        for idx in 0..<(self.count) {
            out.append(self[idx]!)
        }

        return out
    }

    subscript(i: Int) -> T? {
        get {
            guard i >= 0 && i < self.count else {
                return nil
            }

            return self.buf[(self.head + i) % self.count]
        }
        set {
            guard i >= 0 && i < self.count else {
                return
            }

            self.buf[(self.head + i) % self.count] = newValue!
        }
    }
}
