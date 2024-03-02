//
//  SWIMNetTests.swift
//  SWIMNetTests
//
//  Created by Andrew Orals on 2/6/24.
//

import Mockingbird
import XCTest
@testable import SWIMNet

final class DistanceVectorNodeTests: XCTestCase {
    let mockSendDelegate = mock(SendDelegate.self)
    var dVNode: DistanceVectorRoutingNode<Int, SendDelegateMock>?

    override func setUpWithError() throws {
        dVNode = DistanceVectorRoutingNode<Int, SendDelegateMock>.init(
            linkUpdateThreshold: 0,
            dvUpdateThreshold: 0,
            linkCosts: [:],
            sendDelegate: self.mockSendDelegate
        )
    }

    override func tearDownWithError() throws {
        dVNode = nil
        reset(mockSendDelegate)
    }

    // class initialized with no links and empty distance vector
    func testInitEmpty() {
        XCTAssertNil(dVNode!.getLinkForDest(dest: 1))
        XCTAssertEqual(dVNode!.dVUpdateThreshold, 0)
        XCTAssertIdentical(dVNode!.sendDelegate as AnyObject?, self.mockSendDelegate)
    }

    // adding link costs updates distance vector if empty
    func testAddLinkCost() async throws {
        dVNode!.updateLinkCost(linkId: 1, newCost: 8)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: 1), 1)
        let expectedDVTo1: Dictionary<Int, ForwardingEntry<Int>> = [
            1: ForwardingEntry(
                linkId: 1, cost: 8
            )
        ]

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(Int.self, of: 1),
            withDVDict: any(Dictionary<Int, ForwardingEntry<Int>>.self, of: expectedDVTo1)
        )).wasCalled(1)
    }
 
    // updating link costs updates distance vector if lower cost
    func testUpdateLinkCostLower() async throws {
        dVNode!.updateLinkCost(linkId: 1, newCost: 8)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: 1), 1)

        dVNode!.updateLinkCost(linkId: 1, newCost: 5)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: 1), 1)
        // since the cost decreased, this should trigger a send
        let expectedDVTo1: Dictionary<Int, ForwardingEntry<Int>> = [
            1: ForwardingEntry(
                linkId: 1, cost: 5
            )
        ]
        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(Int.self, of: 1),
            withDVDict: any(Dictionary<Int, ForwardingEntry<Int>>.self, of: expectedDVTo1)
        )).wasCalled(2)
    }

    // updating link costs does not update distance vector if higher cost
    func testUpdateLinkCostHigher() async throws {
        dVNode!.updateLinkCost(linkId: 1, newCost: 8)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: 1), 1)
        let expectedDVTo1: Dictionary<Int, ForwardingEntry<Int>> = [
            1: ForwardingEntry(
                linkId: 1, cost: 8
            )
        ]
        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(Int.self, of: 1),
            withDVDict: any(Dictionary<Int, ForwardingEntry<Int>>.self, of: expectedDVTo1)
        )).wasCalled(1)

        dVNode!.updateLinkCost(linkId: 1, newCost: 9)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: 1), 1)
        // since the cost increased, this should not trigger a send
        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(Int.self, of: 1),
            withDVDict: any(Dictionary<Int, ForwardingEntry<Int>>.self, of: expectedDVTo1)
        )).wasCalled(1)
    }

    // distance vector is properly merged using local link costs
    func testReceiveDistanceVector() async throws {
    
    }

    // distance vector resent after receiving if entry updated
    // distance vector not resent after receiving if entry not updated
    // distance vector adds additional entries from peer
    // distance vector entries removed if peer on forward link removes it

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}

final class DistanceVectorNetworkTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}
