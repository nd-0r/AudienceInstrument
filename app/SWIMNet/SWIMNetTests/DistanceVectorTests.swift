//
//  SWIMNetTests.swift
//  SWIMNetTests
//
//  Created by Andrew Orals on 2/6/24.
//

import Mockingbird
import SwiftGraph
import XCTest
@testable @preconcurrency import SWIMNet

func logMessage(_ message: String, to output: FileHandle) {
    if let data = message.data(using: .utf8) {
        output.write(data)
    }
}

// From https://gist.github.com/nestserau/ce8f5e5d3f68781732374f7b1c352a5a
public final class AtomicTimedInteger {
    
    private let lock = DispatchSemaphore(value: 1)
    private var _value: Int
    private var _last_set_time: DispatchTime
    
    public init(value initialValue: Int = 0) {
        _value = initialValue
        _last_set_time = DispatchTime.now()
    }
    
    public var value: Int {
        get {
            lock.wait()
            defer { lock.signal() }
            return _value
        }
        set {
            lock.wait()
            defer { lock.signal() }
            _last_set_time = DispatchTime.now()
            _value = newValue
        }
    }

    public var setInterval: UInt64 {
        get {
            lock.wait()
            defer { lock.signal() }
            return DispatchTime.now().uptimeNanoseconds - _last_set_time.uptimeNanoseconds
        }
    }
    
    public func decrementAndGet() -> Int {
        lock.wait()
        defer { lock.signal() }
        _value -= 1
        return _value
    }
    
    public func incrementAndGet() -> Int {
        lock.wait()
        defer { lock.signal() }
        _value += 1
        return _value
    }
}

fileprivate struct ForwardingEntry<PeerId: PeerIdT, Cost: CostT>: ForwardingEntryProtocol {
    public var linkID: PeerId
    public var cost: Cost
    public var description: String {
        "NextHop: \(linkID) Cost: \(cost)"
    }

    init(linkID: PeerId, cost: Cost) {
        self.linkID = linkID
        self.cost = cost
    }
}

final class DistanceVectorNodeTests: XCTestCase {
    private typealias NodeID = String
    private typealias DVDict = Dictionary<NodeID, ForwardingEntry<NodeID, Cost>>
    typealias Cost = UInt32
    let mockSendDelegate = mock(SendDelegate.self)
    private var dVNode: DistanceVectorRoutingNode<String, Cost, SendDelegateMock, ForwardingEntry<NodeID, Cost>>?

    override func setUpWithError() throws {
        dVNode = DistanceVectorRoutingNode<NodeID, Cost, SendDelegateMock, ForwardingEntry<NodeID, Cost>>.init(
            selfId: "A",
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
    func testInitEmpty() async {
        let linkToB = await dVNode!.getLinkForDest(dest: "B")
        let sendDelegate = await dVNode!.sendDelegate
        XCTAssertNil(linkToB)
        XCTAssertIdentical(sendDelegate, self.mockSendDelegate)
    }

    // adding link costs updates distance vector if empty
    func testAddLinkCost() async throws {
        try await dVNode!.updateLinkCost(linkId: "B", newCost: 8)
        let (linkToB, _) = await dVNode!.getLinkForDest(dest: "B")!
        XCTAssertEqual(linkToB, "B")
        let expectedDVTo_B: DVDict = [
            "A": ForwardingEntry(
                linkID: "A", cost: 0
            ),
            "B": ForwardingEntry(
                linkID: "B", cost: 8
            )
        ]

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)
    }
 
    // updating link costs updates distance vector if lower cost
    func testUpdateLinkCostLower() async throws {
        try await dVNode!.updateLinkCost(linkId: "B", newCost: 8)
        var (linkToB, _) = await dVNode!.getLinkForDest(dest: "B")!
        XCTAssertEqual(linkToB, "B")

        try await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        (linkToB, _) = await dVNode!.getLinkForDest(dest: "B")!
        XCTAssertEqual(linkToB, "B")
        // since the cost decreased, this should trigger a send
        let expectedDVTo_B: DVDict = [
            "A": ForwardingEntry(
                linkID: "A", cost: 0
            ),
            "B": ForwardingEntry(
                linkID: "B", cost: 5
            )
        ]
        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self)
        )).wasCalled(2)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)
    }

    // updating link costs does not update distance vector if higher cost
    func testUpdateLinkCostHigher() async throws {
        try await dVNode!.updateLinkCost(linkId: "B", newCost: 8)
        var (linkToB, _) = await dVNode!.getLinkForDest(dest: "B")!
        XCTAssertEqual(linkToB, "B")
        let expectedDVTo_B: DVDict = [
            "A": ForwardingEntry(
                linkID: "A", cost: 0
            ),
            "B": ForwardingEntry(
                linkID: "B", cost: 8
            )
        ]
        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)

        try await dVNode!.updateLinkCost(linkId: "B", newCost: 9)
        (linkToB, _) = await dVNode!.getLinkForDest(dest: "B")!
        XCTAssertEqual(linkToB, "B")
        // since the cost increased, this should not trigger a send
        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)
    }

    func testUpdateLinkCostTooBig() async throws {
        do {
            try await dVNode!.updateLinkCost(linkId: "B", newCost: dVNode!.kMaxCost)
        } catch DistanceVectorRoutingNodeError.invalidCost(_) {
            XCTFail("Expected NO error when setting cost to `kMaxCost`")
        }

        do {
            try await dVNode!.updateLinkCost(linkId: "B", newCost: dVNode!.kMaxCost + 1)
        } catch DistanceVectorRoutingNodeError.invalidCost(_) {
            return
        }

        XCTFail("Expected error when setting cost to `kMaxCost + 1`")
    }

    // distance vector is properly merged using local link costs and sent
    func testReceiveDistanceVectorWithUpdates() async throws {
        /*
           3     5     7
        D <-> A <-> B <-> C
        Cost from A to C: 12
         */
        let dVFrom_B: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 5),
            "B": ForwardingEntry(linkID: "B", cost: 0),
            "C": ForwardingEntry(linkID: "C", cost: 7)
        ]
        let expectedDVTo_Neighbors: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 0),
            "B": ForwardingEntry(linkID: "B", cost: 5),
            "C": ForwardingEntry(linkID: "B", cost: 12),
            "D": ForwardingEntry(linkID: "D", cost: 3)
        ]

        try await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        try await dVNode!.updateLinkCost(linkId: "D", newCost: 3)
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B
        )

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(1)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
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
            "A": ForwardingEntry(linkID: "A", cost: 5),
            "B": ForwardingEntry(linkID: "B", cost: 0)
        ]
        let dVFrom_D: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 3),
            "D": ForwardingEntry(linkID: "D", cost: 0)
        ]

        try await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        try await dVNode!.updateLinkCost(linkId: "D", newCost: 3)
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B
        )
        await dVNode!.recvDistanceVector(
            fromNeighbor: "D",
            withDistanceVector: dVFrom_D
        )

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
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
        try await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        try await dVNode!.updateLinkCost(linkId: "C", newCost: 13)
        try await dVNode!.updateLinkCost(linkId: "D", newCost: 3)

        let dVFrom_B1: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 5),
            "B": ForwardingEntry(linkID: "B", cost: 0),
            "C": ForwardingEntry(linkID: "C", cost: 7)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B1
        )

        let dVFrom_B2: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 5),
            "B": ForwardingEntry(linkID: "B", cost: 0),
            "C": ForwardingEntry(linkID: "C", cost: Cost.max)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B2
        )

        let expectedDVTo_Neighbors: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 0),
            "B": ForwardingEntry(linkID: "B", cost: 5),
            "C": ForwardingEntry(linkID: "C", cost: 13),
            "D": ForwardingEntry(linkID: "D", cost: 3)
        ]

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(2)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
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
        try await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        try await dVNode!.updateLinkCost(linkId: "D", newCost: 3)

        let dVFrom_B1: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 5),
            "B": ForwardingEntry(linkID: "B", cost: 0),
            "C": ForwardingEntry(linkID: "C", cost: 7)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B1
        )

        let dVFrom_B2: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 5),
            "B": ForwardingEntry(linkID: "B", cost: 0),
            "C": ForwardingEntry(linkID: "C", cost: Cost.max)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B2
        )

        let expectedDVTo_Neighbors: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 0),
            "B": ForwardingEntry(linkID: "B", cost: 5),
            "D": ForwardingEntry(linkID: "D", cost: 3)
        ]

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(1)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
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
        try await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        try await dVNode!.updateLinkCost(linkId: "D", newCost: 3)

        let dVFrom_B: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 5),
            "B": ForwardingEntry(linkID: "B", cost: 0),
            "C": ForwardingEntry(linkID: "C", cost: 7)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B
        )

        try await dVNode!.updateLinkCost(linkId: "B", newCost: nil)

        // receive distance vector from unknown host
        let dVFrom_E: DVDict = [
            "F": ForwardingEntry(linkID: "F", cost: 37),
            "G": ForwardingEntry(linkID: "G", cost: 41),
            "H": ForwardingEntry(linkID: "H", cost: 43)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "E",
            withDistanceVector: dVFrom_E
        )

        let expectedDVTo_Neighbors: DVDict = [
            "A": ForwardingEntry(linkID: "A", cost: 0),
            "B": ForwardingEntry(linkID: "B", cost: Cost.max),
            "C": ForwardingEntry(linkID: "B", cost: Cost.max),
            "D": ForwardingEntry(linkID: "D", cost: 3)
        ]

        try await Task.sleep(nanoseconds: 100000000)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_Neighbors)
        )).wasCalled(0)
        verify(await mockSendDelegate.send(
            from: any(NodeID.self, of: "A"),
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

class SimulatedNetwork<NodeId, Cost>
where NodeId: PeerIdT & Decodable & Encodable,
              Cost: CostT & Decodable & Encodable {
    struct SendDelegateMock: SendDelegate, Sendable {
        var owner: SimulatedNetwork<NodeId, Cost>?

        func send(
            from: any SWIMNet.PeerIdT,
            sendTo peerId: any SWIMNet.PeerIdT,
            withDVDict dv: Sendable
        ) async throws {
            guard owner != nil else {
                return
            }

            _ = owner!.gossips.incrementAndGet()

            await owner!.dVNodes[peerId as! NodeId]!.recvDistanceVector(
                fromNeighbor: from as! NodeId,
                withDistanceVector: dv as! Dictionary<NodeId, ForwardingEntry<NodeId, Cost>>
            )
        }
    }

    fileprivate enum TestError: Error {
        case failure(String, DVNode.DistanceVector, DVNode.DistanceVector)
    }

    var networkGraph: WeightedGraph<NodeId, Cost>
    fileprivate typealias DVNode = DistanceVectorRoutingNode<NodeId, Cost, SendDelegateMock, ForwardingEntry<NodeId, Cost>>
    fileprivate var dVNodes: [NodeId:DVNode] = [:]
    var sendDelegateMock: SendDelegateMock
    private var gossips = AtomicTimedInteger(value: 0)

    var maxCost: Cost? {
        get {
            self.dVNodes.first?.1.kMaxCost
        }
    }


    init(networkGraph: WeightedGraph<NodeId, Cost>) async throws {
        self.networkGraph = networkGraph

        sendDelegateMock = SendDelegateMock()
        sendDelegateMock.owner = self
 
        for nodeId in networkGraph.vertices {
            // Because each node can communicate with itself
            networkGraph.addEdge(from: nodeId, to: nodeId, weight: 0, directed: false)

            dVNodes[nodeId] = DVNode(
                selfId: nodeId,
                dvUpdateThreshold: 0,
                linkCosts: [:],
                sendDelegate: sendDelegateMock
            )
        }

        for edge in networkGraph.edgeList() {
            let uVertex = networkGraph.vertexAtIndex(edge.u)
            let vVertex = networkGraph.vertexAtIndex(edge.v)

            guard uVertex != vVertex else {
                continue // discard self-loops
            }

            if edge.directed {
                try await dVNodes[uVertex]!.updateLinkCost(linkId: vVertex, newCost: edge.weight)
            } else {
                try await dVNodes[uVertex]!.updateLinkCost(linkId: vVertex, newCost: edge.weight)
                try await dVNodes[vVertex]!.updateLinkCost(linkId: uVertex, newCost: edge.weight)
            }
        }
    }

    func updateLinkCost(source: NodeId, dest: NodeId, newCost: Cost?) async throws {
        if !networkGraph.edgeExists(from: source, to: dest) {
            guard newCost != nil else {
                return
            }

            networkGraph.addEdge(from: source, to: dest, weight: newCost!, directed: false)
        }

        let sourceId = networkGraph.indexOfVertex(source)!
        let destId = networkGraph.indexOfVertex(dest)!
        let currEdge = networkGraph.edges[sourceId].first(where: {edgeFromSource in
            return edgeFromSource.v == destId
        })!

        if newCost == nil {
            networkGraph.removeAllEdges(
                from: sourceId,
                to: destId,
                bidirectional: !currEdge.directed
            )
        } else {
            networkGraph.edges[sourceId][networkGraph.edges[sourceId].firstIndex(where: {e in
                e.v == destId
            })!].weight = newCost!

            if !currEdge.directed {
                // update in the other direction as well
                networkGraph.edges[destId][networkGraph.edges[destId].firstIndex(where: {e in
                    e.v == sourceId
                })!].weight = newCost!
            }
        }

        try await dVNodes[source]!.updateLinkCost(linkId: dest, newCost: newCost)
        if !currEdge.directed {
            try await dVNodes[dest]!.updateLinkCost(linkId: source, newCost: newCost)
        }
    }

    func verifyForwardingTables() async throws {
        // note: cannot test networks with multiple equal-cost paths
        var shortestPaths: [NodeId:([Cost?], [Int:WeightedEdge<Cost>])] = [:]
        for vertex in networkGraph.vertices {
            shortestPaths[vertex] = networkGraph.dijkstra(root: vertex, startDistance: 0)
        }

        for vertex in networkGraph.vertices {
            // find all the neighbors of `vertex`
            let vertexId = networkGraph.indexOfVertex(vertex)
            let (_, pathDict) = shortestPaths[vertex]!
            let neighbors = networkGraph.edgesForVertex(vertex)!
                .filter({ neighborEdge in
                    guard neighborEdge.u != neighborEdge.v else {
                        // exclude self-loops
                        return false
                    }

                    // find only neighbor edges that are in the best paths
                    var shortestPathLastEdge = pathDict[neighborEdge.v]
                    if shortestPathLastEdge == nil {
                        // because I'm not sure if the edge always has the vertex as the destination
                        shortestPathLastEdge = pathDict[neighborEdge.u]!
                        return shortestPathLastEdge!.v == vertexId
                    }
                    return shortestPathLastEdge!.u == vertexId
                }).compactMap({ neighborEdge in
                    (
                        networkGraph.vertexAtIndex(neighborEdge.v),
                        ForwardingEntry(
                            linkID: networkGraph.vertexAtIndex(neighborEdge.v),
                            cost: neighborEdge.weight
                        )
                    )
                })

            var expectedFTableEntryList: [NodeId:ForwardingEntry<NodeId, Cost>] = [:]
            for (neighborVertex, _) in neighbors {
                // Create forwarding entries for all destinations whose best path
                //   goes through `neighborVertex` of `vertex`
                for nodeIdOnNeighborPath in dijkstraPathDictBFS(start: neighborVertex, dijkstraPathDict: shortestPaths[vertex]!.1) {
                    expectedFTableEntryList[nodeIdOnNeighborPath] = ForwardingEntry(
                        linkID: neighborVertex,
                        cost: shortestPaths[vertex]!.0[networkGraph.indexOfVertex(nodeIdOnNeighborPath)!]!
                    )
                }
            }
            expectedFTableEntryList[vertex] = ForwardingEntry(linkID: vertex, cost: 0)

            /*
            let actualFTableEntryList = await dVNodes[vertex]!.distanceVector
            guard expectedFTableEntryList.count == actualFTableEntryList.keys.count else {
                throw TestError.failure(
                    """
                    Table size for node \(vertex) is \
                    \(actualFTableEntryList.keys.count) but expected \
                    \(expectedFTableEntryList.count)
                    """,
                    expectedFTableEntryList,
                    actualFTableEntryList
                )
            }
             */

//            logMessage("Node \(vertex) expected: \(expectedFTableEntryList.dvstr)", to: .standardError)
//            logMessage("Node \(vertex) actual: \(await dVNodes[vertex]!.distanceVector.dvstr)", to: .standardError)

            for (dest, entry) in expectedFTableEntryList {
                if let (actualLink, actualCost) = await dVNodes[vertex]!.getLinkForDest(dest: dest) {
                    guard entry.linkID == actualLink && entry.cost == actualCost else {
                        throw TestError.failure(
                            """
                            Entry mismatch for node \(vertex) and destination \(dest): \
                            Expected entry with link \(entry.linkID) and cost \
                            \(entry.cost) but got entry with link \
                            \(actualLink) and cost \(actualCost)
                            """,
                            expectedFTableEntryList,
                            await dVNodes[vertex]!.distanceVector
                        )
                    }
                } else {
                    throw TestError.failure(
                        """
                        Entry mismatch for node \(vertex) and destination \(dest): \
                        Expected entry with link \(entry.linkID) and cost \
                        \(entry.cost) but got no entry
                        """,
                        expectedFTableEntryList,
                        await dVNodes[vertex]!.distanceVector
                    )
                }
            }
        } // end `for vertex in networkGraph.vertices`
    }

    func converge(interval: UInt = 100_000_000) async throws {
        // poll until the network is quiet
        var setInterval = gossips.setInterval
        while (setInterval < interval) {
            try await Task.sleep(nanoseconds: 25_000_000)
            setInterval = gossips.setInterval
        }

        logMessage("Time between last 2 messages sent until convergence: \(Double(setInterval) / 1_000_000_000)\n", to: .standardError)
        logMessage("Number of gossips sent until convergence: \(gossips.value)\n", to: .standardError)

        gossips.value = 0
    }

    private func dijkstraPathDictBFS(
        start: NodeId,
        dijkstraPathDict pathDict: [Int:WeightedEdge<Cost>]
    ) -> Set<NodeId> {
        var toVisit = [start]
        var seen = Set<NodeId>()
        repeat {
            let curr = toVisit.popLast()
            let neighbors = networkGraph.edgesForVertex(curr!)
            seen.insert(curr!)
            for neighborEdge in neighbors! {
                let neighbor = networkGraph.vertexAtIndex(neighborEdge.v)

                // edge not seen and edge is not a self-loop and edge
                //   is in the best path dictionary
                if !seen.contains(neighbor)
                    && curr != neighbor
                    && pathDict[neighborEdge.v] == neighborEdge
                {
                    toVisit.append(neighbor)
                }
            }
        } while (!toVisit.isEmpty)

        return seen
    }
}

final class DistanceVectorNetworkTests: XCTestCase {
    private typealias NodeID = String
    private typealias Cost = UInt32
    private typealias TestError = SimulatedNetwork<NodeID, Cost>.TestError
    internal typealias NumNodesT = UInt
    // number of capital ASCII leters in a node ID
    private let nodeIdLen = ceil(log2(Double(NumNodesT.max)) / log2(Double(26)))
    private var graph: WeightedGraph<NodeID, Cost>?

    override func setUp() {
        graph = WeightedGraph()
    }

    override func tearDown() {
        graph = nil
    }

    func addNodesToGraph(numNodes: NumNodesT) {
        let startCharIdx = 65
        let Z = String(UnicodeScalar(startCharIdx + 25)!)

        var currCharIdx = 0

        for i in 0..<numNodes {
            if i >= 26 {
                currCharIdx += 1
            }
            
            _ = graph?.addVertex(
                String(repeating: Z, count: currCharIdx)
                    + String(UnicodeScalar(startCharIdx + (Int(i) % 26))!)
            )
        }
    }

    func testBasic() async throws {
         /*
        A◄─8─►B◄─3─►C
        ▲     ▲
        │     │
        1     4
        │     │
        ▼     ▼
        D◄─1─►E
         */
        addNodesToGraph(numNodes: 5)
        graph!.addEdge(from: "A", to: "B", weight: 8, directed: false)
        graph!.addEdge(from: "B", to: "C", weight: 3, directed: false)
        graph!.addEdge(from: "B", to: "E", weight: 4, directed: false)
        graph!.addEdge(from: "D", to: "A", weight: 1, directed: false)
        graph!.addEdge(from: "D", to: "E", weight: 1, directed: false)
        logMessage("Graph \(self.testRun?.test.name ?? ""): \(graph!)\n", to: .standardError)

        let simNetwork = try await SimulatedNetwork(networkGraph: self.graph!)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            XCTFail(message)
        }

        try await simNetwork.updateLinkCost(source: "B", dest: "D", newCost: 1)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            XCTFail(message)
        }

        // link down
        try await simNetwork.updateLinkCost(source: "B", dest: "D", newCost: nil)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            XCTFail(message)
        }
    }

    func testBigLoop() async throws {
         /*
        A◄─1─►B◄─1─►C◄─1─►D
        ▲                 ▲
        │                 │
        2                 1
        │                 │
        ▼                 ▼
        H◄─1─►G◄─1─►F◄─1─►E
         */
        addNodesToGraph(numNodes: 8)
        graph!.addEdge(from: "A", to: "B", weight: 1, directed: false)
        graph!.addEdge(from: "B", to: "C", weight: 1, directed: false)
        graph!.addEdge(from: "C", to: "D", weight: 1, directed: false)
        graph!.addEdge(from: "D", to: "E", weight: 1, directed: false)
        graph!.addEdge(from: "E", to: "F", weight: 1, directed: false)
        graph!.addEdge(from: "F", to: "G", weight: 1, directed: false)
        graph!.addEdge(from: "G", to: "H", weight: 1, directed: false)
        graph!.addEdge(from: "H", to: "A", weight: 2, directed: false)
        logMessage("Graph init \(self.testRun?.test.name ?? ""):\n\(graph!)\n", to: .standardError)

        let simNetwork = try await SimulatedNetwork(networkGraph: self.graph!)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            XCTFail(message)
        }

        let updates: [(NodeID, NodeID, Optional<Cost>)] = [
            ("A", "B", nil),
            ("B", "C", nil),
            ("C", "D", nil),
            ("D", "E", nil),
            ("E", "F", nil),
            ("F", "G", nil),
            ("G", "H", nil),
            ("H", "A", nil),
            ("D", "E", 1),
            ("E", "F", 2),
            ("F", "G", 2),
            ("G", "H", 254),
            ("B", "A", 43),
            ("C", "B", 1),
            ("D", "C", 5),
            ("A", "H", 1)
        ]

        for (updateSrc, updateDst, updateCost) in updates {
            try await simNetwork.updateLinkCost(source: updateSrc, dest: updateDst, newCost: updateCost)

            logMessage("Graph \((updateSrc, updateDst, updateCost)):\n\(graph!)\n", to: .standardError)

            try await simNetwork.converge()

            do {
                try await simNetwork.verifyForwardingTables()
            } catch TestError.failure(let message, let expected, let actual) {
                logMessage("Update: \((updateSrc, updateDst, updateCost))", to: .standardError)
                logMessage("Expected: \(expected.dvstr)", to: .standardError)
                logMessage("Actual: \(actual.dvstr)", to: .standardError)
                for nid in simNetwork.dVNodes.keys.sorted() {
                    logMessage("Node \(nid) DV:\n\(await simNetwork.dVNodes[nid]!.distanceVector.dvstr)\n", to: .standardError)
                }
                XCTFail(message)
                break
            }
        }
    }

    func testEmpty() async throws {
        /*
        A◄─0─►B◄─0─►C
        ▲     ▲
        │     │
        0     0
        │     │
        ▼     ▼
        D◄─0─►E
         */
        addNodesToGraph(numNodes: 5)
        graph!.addEdge(from: "A", to: "B", weight: 8, directed: false)
        graph!.addEdge(from: "B", to: "C", weight: 3, directed: false)
        graph!.addEdge(from: "B", to: "E", weight: 4, directed: false)
        graph!.addEdge(from: "D", to: "A", weight: 1, directed: false)
        graph!.addEdge(from: "D", to: "E", weight: 1, directed: false)
        logMessage("Graph \(self.testRun?.test.name ?? ""): \(graph!)\n", to: .standardError)

        let simNetwork = try await SimulatedNetwork(networkGraph: self.graph!)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            XCTFail(message)
        }
    }

    func testLarge() async throws {
         /*
        ┌────2─────┐ ┌────3─────┐
        │          │ │          │
        ▼          ▼ ▼          ▼
        A◄──1►B◄─2─►C◄───►D◄──1►E◄─2─►F
        │     ▲       3 ▲ ▲ ▲         ▲
        │     │         │ │ │         │
        │     └────9────┘ │ └────5────┘
        │                 │
        └───────7─────────┘
        */
         /*
        ┌────2─────┐ ┌────3─────┐
        │          │ │          │
        ▼          ▼ ▼          ▼
        A     B◄─2─►C     D     E     F
        │     ▲         ▲ ▲ ▲         ▲
        │     │         │ │ │         │
        │     └────9────┘ │ └────5────┘
        │                 │
        └───────7─────────┘
        */
        addNodesToGraph(numNodes: 6)
        graph!.addEdge(from: "A", to: "B", weight: 1, directed: false)
        graph!.addEdge(from: "A", to: "C", weight: 2, directed: false)
        graph!.addEdge(from: "A", to: "D", weight: 7, directed: false)
        graph!.addEdge(from: "B", to: "C", weight: 2, directed: false)
        graph!.addEdge(from: "B", to: "D", weight: 9, directed: false)
        graph!.addEdge(from: "C", to: "D", weight: 3, directed: false)
        graph!.addEdge(from: "C", to: "E", weight: 3, directed: false)
        graph!.addEdge(from: "D", to: "E", weight: 1, directed: false)
        graph!.addEdge(from: "D", to: "F", weight: 5, directed: false)
        graph!.addEdge(from: "E", to: "F", weight: 2, directed: false)
        logMessage("Graph \(self.testRun?.test.name ?? ""): \(graph!)\n", to: .standardError)

        let simNetwork = try await SimulatedNetwork(networkGraph: self.graph!)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            XCTFail(message)
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            return
        }

        let updates: [(NodeID, NodeID, Optional<Cost>)] = [
            ("A", "B", nil),
            ("C", "D", nil),
            ("E", "F", nil),
            ("D", "E", nil),
            ("A", "D", simNetwork.maxCost! - 1),
            ("A", "B", simNetwork.maxCost! - 1),
            ("C", "D", simNetwork.maxCost! - 1),
            ("E", "F", 1),
            ("D", "E", 1)
        ]

        for (updateSrc, updateDst, updateCost) in updates {
            try await simNetwork.updateLinkCost(source: updateSrc, dest: updateDst, newCost: updateCost)

            try await simNetwork.converge()

            do {
                try await simNetwork.verifyForwardingTables()
            } catch TestError.failure(let message, let expected, let actual) {
                XCTFail(message)
                logMessage("Update: \((updateSrc, updateDst, updateCost))\n", to: .standardError)
                logMessage("Expected: \(expected.dvstr)", to: .standardError)
                logMessage("Actual: \(actual.dvstr)", to: .standardError)
                for nid in simNetwork.dVNodes.keys.sorted() {
                    logMessage("Node \(nid) DV:\n\(await simNetwork.dVNodes[nid]!.distanceVector.dvstr)\n", to: .standardError)
                }
                break
            }
        }
    }

    func testLargeLarge() async throws {
        /*
        ┌───────────5───────────────┐
        │                           │
        │             ┌─────3─────┐ │
        5             │           │ 5
        │       ┌──1──┼─────┐     │ │
        │       │     │     │     │ │
        └──5───►▼     ▼     ▼     ▼ │
                A◄─2─►B◄─2─►C◄─3─►D◄└───5────┐
           ┌───►            ▲     ▲          │
           │    ┌────1──────┘     │ ◄─────┐  │
           │    │                 │       │  │
           │    │ ┌───────1───────┘    254│  │
           │    ▼ ▼                       │  │
           │    E◄──2►F     G     H◄───┐  │  5
           │    │     ▲     ▲     ▲    │  │  │
           0    │     │     │  127│    │  │  │
           │    │     │  254│     │    │  │  │
           │  127     │     │     │    │  │  │
           │    │     │     └─────┼─254├──┘  │
           │    │     │           │    │     │
           │    │     └───5───────┼────┼─────┘
           │    │                 │    │
           │    └─────127─────────┘    0
           │                           │
           │                           │
           └───────────0───────────────┘
         */
        addNodesToGraph(numNodes: 8)
        graph!.addEdge(from: "A", to: "B", weight: 2, directed: false)
        graph!.addEdge(from: "A", to: "C", weight: 1, directed: false)
        graph!.addEdge(from: "B", to: "C", weight: 2, directed: false)
        graph!.addEdge(from: "B", to: "D", weight: 3, directed: false)
        graph!.addEdge(from: "C", to: "D", weight: 3, directed: false)
        graph!.addEdge(from: "C", to: "E", weight: 1, directed: false)
        graph!.addEdge(from: "D", to: "E", weight: 1, directed: false)
        graph!.addEdge(from: "D", to: "F", weight: 5, directed: false)
        graph!.addEdge(from: "E", to: "F", weight: 2, directed: false)
        graph!.addEdge(from: "A", to: "D", weight: 5, directed: false)
        graph!.addEdge(from: "D", to: "G", weight: 254, directed: false)
        graph!.addEdge(from: "E", to: "H", weight: 127, directed: false)
        graph!.addEdge(from: "H", to: "A", weight: 1, directed: false)
        logMessage("Graph \(self.testRun?.test.name ?? ""): \(graph!)\n", to: .standardError)

        let simNetwork = try await SimulatedNetwork(networkGraph: self.graph!)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            XCTFail(message)
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            return
        }

        let updates: [(NodeID, NodeID, Optional<Cost>)] = [
            ("A", "D", nil),
            ("A", "B", nil),
            ("C", "D", nil),
            ("E", "F", nil),
            ("D", "E", nil),
            ("A", "D", 254),
            ("A", "B", 127),
            ("C", "D", 65),
            ("E", "F", 2),
            ("D", "E", 1),
        ]

        for (updateSrc, updateDst, updateCost) in updates {
            try await simNetwork.updateLinkCost(source: updateSrc, dest: updateDst, newCost: updateCost)

            try await simNetwork.converge()

            do {
                try await simNetwork.verifyForwardingTables()
            } catch TestError.failure(let message, let expected, let actual) {
                XCTFail(message)
                logMessage("Update: \((updateSrc, updateDst, updateCost))\n", to: .standardError)
                logMessage("Expected: \(expected.dvstr)", to: .standardError)
                logMessage("Actual: \(actual.dvstr)", to: .standardError)
                for nid in simNetwork.dVNodes.keys.sorted() {
                    logMessage("Node \(nid) DV:\n\(await simNetwork.dVNodes[nid]!.distanceVector.dvstr)\n", to: .standardError)
                }
                break
            }
        }
    }


    func testMakeReachable() async throws {
        addNodesToGraph(numNodes: 5)
        graph!.addEdge(from: "A", to: "B", weight: 8, directed: false)
        graph!.addEdge(from: "B", to: "C", weight: 3, directed: false)
        graph!.addEdge(from: "B", to: "E", weight: 4, directed: false)
        graph!.addEdge(from: "D", to: "A", weight: 1, directed: false)
        graph!.addEdge(from: "D", to: "E", weight: 1, directed: false)
        logMessage("Graph \(self.testRun?.test.name ?? ""): \(graph!)\n", to: .standardError)

        let simNetwork = try await SimulatedNetwork(networkGraph: self.graph!)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            XCTFail(message)
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            return
        }

        let updates: [(NodeID, NodeID, Optional<Cost>)] = [
            ("A", "B", nil),
            ("B", "C", nil),
            ("B", "E", nil),
            ("D", "A", nil),
            ("D", "E", nil),
            ("A", "B", 1),
            ("B", "C", 1),
            ("C", "D", 1),
            ("D", "E", 1),
            ("E", "A", 1),
        ]

        for (updateSrc, updateDst, updateCost) in updates {
            try await simNetwork.updateLinkCost(source: updateSrc, dest: updateDst, newCost: updateCost)

            try await simNetwork.converge()

            do {
                try await simNetwork.verifyForwardingTables()
            } catch TestError.failure(let message, let expected, let actual) {
                XCTFail(message)
                logMessage("Update: \((updateSrc, updateDst, updateCost))\n", to: .standardError)
                logMessage("Expected: \(expected.dvstr)", to: .standardError)
                logMessage("Actual: \(actual.dvstr)", to: .standardError)
                for nid in simNetwork.dVNodes.keys.sorted() {
                    logMessage("Node \(nid) DV:\n\(await simNetwork.dVNodes[nid]!.distanceVector.dvstr)\n", to: .standardError)
                }
                break
            }
        }
    }

    func testMakeUnreachable() async throws {
        addNodesToGraph(numNodes: 5)
        graph!.addEdge(from: "A", to: "B", weight: 8, directed: false)
        graph!.addEdge(from: "B", to: "C", weight: 3, directed: false)
        graph!.addEdge(from: "B", to: "E", weight: 4, directed: false)
        graph!.addEdge(from: "D", to: "A", weight: 1, directed: false)
        graph!.addEdge(from: "D", to: "E", weight: 1, directed: false)
        logMessage("Graph \(self.testRun?.test.name ?? ""): \(graph!)\n", to: .standardError)

        let simNetwork = try await SimulatedNetwork(networkGraph: self.graph!)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            XCTFail(message)
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            return
        }

        let updates: [(NodeID, NodeID, Optional<Cost>)] = [
            ("A", "B", nil),
            ("B", "C", nil),
            ("B", "E", nil),
            ("D", "A", nil),
            ("D", "E", nil),
        ]

        for (updateSrc, updateDst, updateCost) in updates {
            try await simNetwork.updateLinkCost(source: updateSrc, dest: updateDst, newCost: updateCost)

            try await simNetwork.converge()

            do {
                try await simNetwork.verifyForwardingTables()
            } catch TestError.failure(let message, let expected, let actual) {
                XCTFail(message)
                logMessage("Update: \((updateSrc, updateDst, updateCost))\n", to: .standardError)
                logMessage("Expected: \(expected.dvstr)", to: .standardError)
                logMessage("Actual: \(actual.dvstr)", to: .standardError)
                for nid in simNetwork.dVNodes.keys.sorted() {
                    logMessage("Node \(nid) DV:\n\(await simNetwork.dVNodes[nid]!.distanceVector.dvstr)\n", to: .standardError)
                }
                break
            }
        }
    }
}
