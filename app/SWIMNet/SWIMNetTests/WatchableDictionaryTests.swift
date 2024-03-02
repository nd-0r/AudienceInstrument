//
//  WatchableDictionaryTests.swift
//  SWIMNetTests
//
//  Created by Andrew Orals on 2/27/24.
//

import XCTest
import Mockingbird
@testable import SWIMNet

final class WatchableDictionaryTests: XCTestCase {
    let mockDidUpdateCallback = mock(DidUpdateCallbackProtocol.self)
    var watchableDictionary: WatchableDictionary<Int, Int>?

    override func setUpWithError() throws {
        watchableDictionary = WatchableDictionary(didUpdateCallback: mockDidUpdateCallback)
    }

    override func tearDownWithError() throws {
        watchableDictionary = nil
        reset(mockDidUpdateCallback)
    }

    func testAddValues() async {
        let updateThreshold = 4
        let expectedDict = [0: 1, 1: 2, 2: 3, 3: 4, 4: 1, 5: 2, 6: 3, 7: 4]

        watchableDictionary!.updateThreshold = UInt(updateThreshold)

        var updateCounter = 0
        var currCalls = 0
        given(mockDidUpdateCallback.didUpdate()).willReturn()
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(currCalls)
        for i in 0...7 {
            watchableDictionary![i] = expectedDict[i]

            updateCounter += 1
            if updateCounter > updateThreshold {
                currCalls += 1
                updateCounter = 0
            }

            verify(mockDidUpdateCallback.didUpdate()).wasCalled(currCalls)
        }

        XCTAssertEqual(watchableDictionary!.dict, expectedDict)
        XCTAssertEqual(watchableDictionary!.keys, expectedDict.keys)
    }

    func testRemoveValues() async {
        let updateThreshold = 1
        watchableDictionary!.updateThreshold = UInt(updateThreshold)

        given(mockDidUpdateCallback.didUpdate()).willReturn()

        let startingDict = [0: 1, 1: 2, 2: 3, 3: 4, 4: 1, 5: 2, 6: 3, 7: 4]
        let expectedDict = [0: 1, 2: 3, 4: 1, 6: 3]

        for i in 0...7 {
            watchableDictionary![i] = startingDict[i]
        }

        verify(mockDidUpdateCallback.didUpdate()).wasCalled(4)
        watchableDictionary![1] = nil
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(4)
        watchableDictionary![3] = nil
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(5)
        watchableDictionary![5] = nil
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(5)
        watchableDictionary![7] = nil
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(6)

        XCTAssertEqual(watchableDictionary!.dict, expectedDict)
        XCTAssertEqual(watchableDictionary!.keys, expectedDict.keys)
    }

    func testChangeUpdateThreshold() async {
        given(mockDidUpdateCallback.didUpdate()).willReturn()

        watchableDictionary!.updateThreshold = UInt(1)
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(0)
        watchableDictionary![0] = 0
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(0)
        watchableDictionary![0] = 1
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(1)
        watchableDictionary![0] = 2
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(1)
        watchableDictionary!.updateThreshold = UInt(2)
        watchableDictionary![0] = 3
        // Shouldn't update because now the threshold is 2
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(1)
        watchableDictionary![0] = 4
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(2)
        watchableDictionary![0] = 5
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(2)
        watchableDictionary![0] = 6
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(2)
        watchableDictionary!.updateThreshold = UInt(1)
        watchableDictionary![0] = 7
        // Should update because update threshold can't decrease
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(3)
        watchableDictionary![0] = 8
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(3)
        watchableDictionary![0] = 9
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(3)
        watchableDictionary![0] = 10
        verify(mockDidUpdateCallback.didUpdate()).wasCalled(4)
    }

    func testIterate() throws {
        let startingDict = [0: 1, 1: 2, 2: 3, 3: 4, 4: 1, 5: 2, 6: 3, 7: 4]

        given(mockDidUpdateCallback.didUpdate()).willReturn()
        for i in 0...7 {
            watchableDictionary![i] = startingDict[i]
        }

        for (k, v) in watchableDictionary! {
            XCTAssertEqual(startingDict[k], v)
        }
    }
}
