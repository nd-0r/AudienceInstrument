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
    private typealias NodeID = String
    private typealias DVDict = Dictionary<NodeID, ForwardingEntry<NodeID, Cost>>
    typealias Cost = UInt8
    let mockSendDelegate = mock(SendDelegate.self)
    var dVNode: DistanceVectorRoutingNode<String, Cost, SendDelegateMock>?

    override func setUpWithError() throws {
        dVNode = DistanceVectorRoutingNode<NodeID, Cost, SendDelegateMock>.init(
            selfId: "A",
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
        XCTAssertNil(dVNode!.getLinkForDest(dest: "B"))
        XCTAssertEqual(dVNode!.dVUpdateThreshold, 0)
        XCTAssertIdentical(dVNode!.sendDelegate as AnyObject?, self.mockSendDelegate)
    }

    // adding link costs updates distance vector if empty
    func testAddLinkCost() async throws {
        dVNode!.updateLinkCost(linkId: "B", newCost: 8)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: "B"), "B")
        let expectedDVTo_B: DVDict = [
            "A": ForwardingEntry(
                linkId: "A", cost: 0
            ),
            "B": ForwardingEntry(
                linkId: "B", cost: 8
            )
        ]

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)
    }
 
    // updating link costs updates distance vector if lower cost
    func testUpdateLinkCostLower() async throws {
        dVNode!.updateLinkCost(linkId: "B", newCost: 8)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: "B"), "B")

        dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: "B"), "B")
        // since the cost decreased, this should trigger a send
        let expectedDVTo_B: DVDict = [
            "A": ForwardingEntry(
                linkId: "A", cost: 0
            ),
            "B": ForwardingEntry(
                linkId: "B", cost: 5
            )
        ]
        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self)
        )).wasCalled(2)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)
    }

    // updating link costs does not update distance vector if higher cost
    func testUpdateLinkCostHigher() async throws {
        dVNode!.updateLinkCost(linkId: "B", newCost: 8)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: "B"), "B")
        let expectedDVTo_B: DVDict = [
            "A": ForwardingEntry(
                linkId: "A", cost: 0
            ),
            "B": ForwardingEntry(
                linkId: "B", cost: 8
            )
        ]
        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)

        dVNode!.updateLinkCost(linkId: "B", newCost: 9)
        XCTAssertEqual(dVNode!.getLinkForDest(dest: "B"), "B")
        // since the cost increased, this should not trigger a send
        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)
    }

    // distance vector is properly merged using local link costs and sent
    func testReceiveDistanceVectorWithUpdates() async throws {
        /*
           3     5     7
        D <-> A <-> B <-> C
        Cost from A to C: 12
         */
        let dVFrom_B: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: 7)
        ]
        let expectedDVTo_Neighbors: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 0),
            "B": ForwardingEntry(linkId: "B", cost: 5),
            "C": ForwardingEntry(linkId: "B", cost: 12),
            "D": ForwardingEntry(linkId: "D", cost: 3)
        ]

        dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        dVNode!.updateLinkCost(linkId: "D", newCost: 3)
        dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B
        )

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(1)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "D"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(1)
    }

    // distance vector not resent after receiving if entry not updated
    func testReceiveDistanceVectorNoUpdates() async throws {
        /*
           3     5
        D <-> A <-> B
         */
        let dVFrom_B: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0)
        ]
        let dVFrom_D: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 3),
            "D": ForwardingEntry(linkId: "D", cost: 0)
        ]

        dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        dVNode!.updateLinkCost(linkId: "D", newCost: 3)
        dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B
        )
        dVNode!.recvDistanceVector(
            fromNeighbor: "D",
            withDistanceVector: dVFrom_D
        )

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self),
            withDVDict: any(DVDict.self)
        )).wasCalled(3) // For calls to updateLinkCost()
    }

    // distance vector entries updated with link cost if peer on forward link tombstones it
    //   and destination is still reachable through direct link
    func testReceiveDistanceVectorDestUnreachableButDirect() async throws {
        /*
           3     5     7
        D <-> A <-> B <-> C
              | <-------->|
                    13
        ...
           3     5
        D <-> A <-> B     C
              | <-------->|
                    11
         */
        dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        dVNode!.updateLinkCost(linkId: "C", newCost: 13)
        dVNode!.updateLinkCost(linkId: "D", newCost: 3)

        let dVFrom_B1: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: 7)
        ]
        dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B1
        )

        let dVFrom_B2: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: Cost.max)
        ]
        dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B2
        )

        let expectedDVTo_Neighbors: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 0),
            "B": ForwardingEntry(linkId: "B", cost: 5),
            "C": ForwardingEntry(linkId: "C", cost: 13),
            "D": ForwardingEntry(linkId: "D", cost: 3)
        ]

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(2)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "D"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(2)
    }

    // distance vector entries tombstoned if peer on forward link tombstones it and
    //   destination not still reachable through direct link
    func testReceiveDistanceVectorDestUnreachableNoDirect() async throws {
        /*
           3     5     7
        D <-> A <-> B <-> C
        ...
           3     5
        D <-> A <-> B     C
         */
        dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        dVNode!.updateLinkCost(linkId: "D", newCost: 3)

        let dVFrom_B1: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: 7)
        ]
        dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B1
        )

        let dVFrom_B2: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: Cost.max)
        ]
        dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B2
        )

        let expectedDVTo_Neighbors: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 0),
            "B": ForwardingEntry(linkId: "B", cost: 5),
            "C": ForwardingEntry(linkId: "B", cost: Cost.max),
            "D": ForwardingEntry(linkId: "D", cost: 3)
        ]

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(1)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "D"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(1)
    }
 
    // distance vector entry tombstoned if neighbor link removed or sender unknown
    func testReceiveDistanceVectorDestUnreachableDirectUnreachable() async throws {
        /*
           3     5     7
        D <-> A <-> B <-> C
        ...
           3
        D <-> A     B     C
         */
        dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        dVNode!.updateLinkCost(linkId: "D", newCost: 3)

        let dVFrom_B: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: 7)
        ]
        dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B
        )

        dVNode!.updateLinkCost(linkId: "B", newCost: nil)

        // receive distance vector from unknown host
        let dVFrom_E: DVDict = [
            "F": ForwardingEntry(linkId: "F", cost: 37),
            "G": ForwardingEntry(linkId: "G", cost: 41),
            "H": ForwardingEntry(linkId: "H", cost: 43)
        ]
        dVNode!.recvDistanceVector(
            fromNeighbor: "E",
            withDistanceVector: dVFrom_E
        )

        let expectedDVTo_Neighbors: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 0),
            "B": ForwardingEntry(linkId: "B", cost: Cost.max),
            "C": ForwardingEntry(linkId: "B", cost: Cost.max),
            "D": ForwardingEntry(linkId: "D", cost: 3)
        ]

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(0)
        verify(await mockSendDelegate.send(
            sendTo: any(NodeID.self, of: "D"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(1)
    }

    /*
    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }
     */
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
