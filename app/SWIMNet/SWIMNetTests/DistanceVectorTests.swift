//
//  SWIMNetTests.swift
//  SWIMNetTests
//
//  Created by Andrew Orals on 2/6/24.
//

import Mockingbird
import SwiftGraph
import XCTest
@testable import SWIMNet

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


final class DistanceVectorNodeTests: XCTestCase {
    private typealias NodeID = String
    private typealias DVDict = Dictionary<NodeID, ForwardingEntry<NodeID, Cost>>
    typealias Cost = UInt8
    let mockSendDelegate = mock(SendDelegate.self)
    var dVNode: DistanceVectorRoutingNode<String, Cost, SendDelegateMock>?

    override func setUpWithError() throws {
        dVNode = DistanceVectorRoutingNode<NodeID, Cost, SendDelegateMock>.init(
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
        await dVNode!.updateLinkCost(linkId: "B", newCost: 8)
        let (linkToB, _) = await dVNode!.getLinkForDest(dest: "B")!
        XCTAssertEqual(linkToB, "B")
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
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)
    }
 
    // updating link costs updates distance vector if lower cost
    func testUpdateLinkCostLower() async throws {
        await dVNode!.updateLinkCost(linkId: "B", newCost: 8)
        var (linkToB, _) = await dVNode!.getLinkForDest(dest: "B")!
        XCTAssertEqual(linkToB, "B")

        await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        (linkToB, _) = await dVNode!.getLinkForDest(dest: "B")!
        XCTAssertEqual(linkToB, "B")
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
        await dVNode!.updateLinkCost(linkId: "B", newCost: 8)
        var (linkToB, _) = await dVNode!.getLinkForDest(dest: "B")!
        XCTAssertEqual(linkToB, "B")
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
            from: any(NodeID.self, of: "A"),
            sendTo: any(NodeID.self, of: "B"),
            withDVDict: any(DVDict.self, of: expectedDVTo_B)
        )).wasCalled(1)

        await dVNode!.updateLinkCost(linkId: "B", newCost: 9)
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

        await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        await dVNode!.updateLinkCost(linkId: "D", newCost: 3)
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
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0)
        ]
        let dVFrom_D: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 3),
            "D": ForwardingEntry(linkId: "D", cost: 0)
        ]

        await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        await dVNode!.updateLinkCost(linkId: "D", newCost: 3)
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
        await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        await dVNode!.updateLinkCost(linkId: "C", newCost: 13)
        await dVNode!.updateLinkCost(linkId: "D", newCost: 3)

        let dVFrom_B1: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: 7)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B1
        )

        let dVFrom_B2: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: Cost.max)
        ]
        await dVNode!.recvDistanceVector(
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
        await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        await dVNode!.updateLinkCost(linkId: "D", newCost: 3)

        let dVFrom_B1: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: 7)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B1
        )

        let dVFrom_B2: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: Cost.max)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B2
        )

        let expectedDVTo_Neighbors: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 0),
            "B": ForwardingEntry(linkId: "B", cost: 5),
            "D": ForwardingEntry(linkId: "D", cost: 3)
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
        await dVNode!.updateLinkCost(linkId: "B", newCost: 5)
        await dVNode!.updateLinkCost(linkId: "D", newCost: 3)

        let dVFrom_B: DVDict = [
            "A": ForwardingEntry(linkId: "A", cost: 5),
            "B": ForwardingEntry(linkId: "B", cost: 0),
            "C": ForwardingEntry(linkId: "C", cost: 7)
        ]
        await dVNode!.recvDistanceVector(
            fromNeighbor: "B",
            withDistanceVector: dVFrom_B
        )

        await dVNode!.updateLinkCost(linkId: "B", newCost: nil)

        // receive distance vector from unknown host
        let dVFrom_E: DVDict = [
            "F": ForwardingEntry(linkId: "F", cost: 37),
            "G": ForwardingEntry(linkId: "G", cost: 41),
            "H": ForwardingEntry(linkId: "H", cost: 43)
        ]
        await dVNode!.recvDistanceVector(
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

    enum TestError: Error {
        case failure(String, DVNode.DistanceVector, DVNode.DistanceVector)
    }

    var networkGraph: WeightedGraph<NodeId, Cost>
    typealias DVNode = DistanceVectorRoutingNode<NodeId, Cost, SendDelegateMock>
    var dVNodes: [NodeId:DVNode] = [:]
    var sendDelegateMock: SendDelegateMock
    private var gossips = AtomicTimedInteger(value: 0)
    private var magicNumGossips = 0


    init(networkGraph: WeightedGraph<NodeId, Cost>) async {
        self.networkGraph = networkGraph

        sendDelegateMock = SendDelegateMock()
        sendDelegateMock.owner = self
        let n = networkGraph.vertices.count
        let c = 3
        // Prof. Gupta CS425 L5 FA22
        magicNumGossips = n * c * Int(ceil(log2(Double(n))))
 
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
                await dVNodes[uVertex]!.updateLinkCost(linkId: vVertex, newCost: edge.weight)
            } else {
                await dVNodes[uVertex]!.updateLinkCost(linkId: vVertex, newCost: edge.weight)
                await dVNodes[vVertex]!.updateLinkCost(linkId: uVertex, newCost: edge.weight)
            }
        }
    }

    func updateLinkCost(source: NodeId, dest: NodeId, newCost: Cost?) async {
        guard networkGraph.edgeExists(from: source, to: dest) else {
            return
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
            networkGraph.edges[sourceId][destId].weight = newCost!
        }

        if currEdge.directed {
            await dVNodes[source]!.updateLinkCost(linkId: dest, newCost: newCost)
        } else {
            await dVNodes[source]!.updateLinkCost(linkId: dest, newCost: newCost)
            await dVNodes[dest]!.updateLinkCost(linkId: source, newCost: newCost)
        }
    }

    func verifyForwardingTables() async throws {
        var shortestPaths: [NodeId:([Cost?], [Int:WeightedEdge<Cost>])] = [:]
        for vertex in networkGraph.vertices {
            shortestPaths[vertex] = networkGraph.dijkstra(root: vertex, startDistance: 0)
        }

        for vertex in networkGraph.vertices {
            let vertexId = networkGraph.indexOfVertex(vertex)
            let (_, pathDict) = shortestPaths[vertex]!
            let neighbors = networkGraph.edgesForVertex(vertex)!
                .filter({ neighborEdge in
                    guard neighborEdge.u != neighborEdge.v else {
                        return false
                    }

                    var shortestPathLastEdge = pathDict[neighborEdge.v]
                    if shortestPathLastEdge == nil {
                        // because I'm not sure if the edge always has the vertex as the destination
                        shortestPathLastEdge = pathDict[neighborEdge.u]!
                        return shortestPathLastEdge!.v == vertexId
                    }
                    return shortestPathLastEdge!.u == vertexId
                }).compactMap({neighborEdge in
                    (
                        networkGraph.vertexAtIndex(neighborEdge.v),
                        ForwardingEntry(
                            linkId: networkGraph.vertexAtIndex(neighborEdge.v),
                            cost: neighborEdge.weight
                        )
                    )
                })

            var expectedFTableEntryList: [NodeId:ForwardingEntry<NodeId, Cost>] = [:]
            for (neighborVertex, _) in neighbors {
                for nodeIdOnNeighborPath in dijkstraPathDictBFS(start: neighborVertex, dijkstraPathDict: shortestPaths[vertex]!.1) {
                    expectedFTableEntryList[nodeIdOnNeighborPath] = ForwardingEntry(
                        linkId: neighborVertex,
                        cost: shortestPaths[vertex]!.0[networkGraph.indexOfVertex(nodeIdOnNeighborPath)!]!
                    )
                }
            }
            expectedFTableEntryList[vertex] = ForwardingEntry(linkId: vertex, cost: 0)

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

            for (dest, entry) in expectedFTableEntryList {
                if let (actualLink, actualCost) = await dVNodes[vertex]!.getLinkForDest(dest: dest) {
                    guard entry.linkId == actualLink && entry.cost == actualCost else {
                        throw TestError.failure(
                            """
                            Entry mismatch for node \(vertex) and destination \(dest): \
                            Expected entry with link \(entry.linkId) and cost \
                            \(entry.cost) but got entry with link \
                            \(actualLink) and cost \(actualCost)
                            """,
                            expectedFTableEntryList,
                            await dVNodes[vertex]!.distanceVector
                        )
                    }
                }
            }
        }
    }

    func converge() async throws {
//        await withTaskGroup(of: Void.self, body: { group in
//            for nodeId in networkGraph.vertices {
//                group.addTask(operation: {
//                    await self.dVNodes[nodeId]!.sendDistanceVectorToPeers()
//                })
//            }
//        })

        // sorry... I couldn't figure out a better way.
        var setInterval = gossips.setInterval
        while (setInterval < 100_000_000) {
            try await Task.sleep(nanoseconds: 500_000_000)
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
    private typealias Cost = UInt8
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

        let simNetwork = await SimulatedNetwork(networkGraph: self.graph!)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            XCTFail(message)
        }

        await simNetwork.updateLinkCost(source: "B", dest: "D", newCost: 1)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            XCTFail(message)
        }

        // link down
        await simNetwork.updateLinkCost(source: "B", dest: "D", newCost: Cost.max)

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
        logMessage("Graph \(self.testRun?.test.name ?? ""): \(graph!)\n", to: .standardError)

        let simNetwork = await SimulatedNetwork(networkGraph: self.graph!)

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
            ("D", "E", 2),
            ("F", "G", 2),
            ("G", "H", 254),
            ("B", "A", 43),
            ("C", "B", 1),
            ("D", "C", 5),
            ("A", "H", 1)
        ]

        for (updateSrc, updateDst, updateCost) in updates {
            await simNetwork.updateLinkCost(source: updateSrc, dest: updateDst, newCost: updateCost)

            try await simNetwork.converge()

            do {
                try await simNetwork.verifyForwardingTables()
            } catch TestError.failure(let message, let expected, let actual) {
                logMessage("Update: \((updateSrc, updateDst, updateCost))", to: .standardError)
                logMessage("Expected: \(expected.dvstr)", to: .standardError)
                logMessage("Actual: \(actual.dvstr)", to: .standardError)
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

        let simNetwork = await SimulatedNetwork(networkGraph: self.graph!)

        try await simNetwork.converge()

        do {
            try await simNetwork.verifyForwardingTables()
        } catch TestError.failure(let message, let expected, let actual) {
            logMessage("Expected: \(expected.dvstr)", to: .standardError)
            logMessage("Actual: \(actual.dvstr)", to: .standardError)
            XCTFail(message)
        }
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
