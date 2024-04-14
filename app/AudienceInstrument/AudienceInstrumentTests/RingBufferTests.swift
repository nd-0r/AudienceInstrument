//
//  RingBufferTests.swift
//  AudienceInstrumentTests
//
//  Created by Andrew Orals on 4/14/24.
//

import Foundation
import XCTest
@testable import AudienceInstrument

class RingBufferTests: XCTestCase {
    
    func verifyElements<T: Equatable>(_ cb: RingBuffer<T>, _ expected: [T], _ capacity: Int) {
        XCTAssertEqual(capacity - cb.numFree(), expected.count + 1)
        for e in expected {
            XCTAssertEqual(cb.popBack()!, e)
        }
    }
    
    func testInitLen3() {
        let cb = RingBuffer<Int>(capacity: 3)
        XCTAssertEqual(cb.count, 0)
        XCTAssertEqual(cb.numFree(), 2)
    }

    func testPushFrontLen0() {
        let cb = RingBuffer<Int>(capacity: 2)
        cb.pushFront(element: 4)
        verifyElements(cb, [4], 2)
    }
    
    func testPushFrontLen1() {
        let cb = RingBuffer<Int>(capacity: 3)
        cb.pushFront(element: 1)
        cb.pushFront(element: 2)
        verifyElements(cb, [1, 2], 3)
    }
    
    func testPushFrontLenFull() {
        let cb = RingBuffer<Int>(capacity: 3)
        cb.pushFront(element: 1)
        cb.pushFront(element: 2)
        cb.pushFront(element: 3) // Should not be added, buffer full
        verifyElements(cb, [1, 2], 3)
    }
    
    func testPopBack() {
        let cb = RingBuffer<Int>(capacity: 5)
        cb.pushFront(element: 1)
        cb.pushFront(element: 2)
        cb.pushFront(element: 3)
        cb.pushFront(element: 4)
        XCTAssertEqual(cb.popBack(), 1)
        XCTAssertEqual(cb.popBack(), 2)
        verifyElements(cb, [3, 4], 5)
    }
    
    func testPopBackExceedLen() {
        let cb = RingBuffer<Int>(capacity: 3)
        cb.pushFront(element: 1)
        cb.pushFront(element: 2)
        XCTAssertEqual(cb.popBack(), 1)
        XCTAssertEqual(cb.popBack(), 2)
        XCTAssertNil(cb.popBack())
        verifyElements(cb, [], 3)
    }

    func testStressTestPushFrontPopBack() {
        let cb = RingBuffer<Int>(capacity: 5)
        for idx in 0..<8 {
            if idx > 3 {
                cb.popBack()
            }
            cb.pushFront(element: idx)
        }
        verifyElements(cb, [4, 5, 6, 7], 5)
    }
    
}
