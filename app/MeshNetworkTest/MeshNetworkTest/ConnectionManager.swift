//
//  ConnectionManager.swift
//  MeshNetworkTest
//
//  Created by Andrew Orals on 3/16/24.
//

import Foundation
import MultipeerConnectivity
import SWIMNet
import Darwin.Mach

extension ForwardingEntry: ForwardingEntryProtocol {
    init(linkID: Int64, cost: UInt64) {
        self.linkID = linkID
        self.cost = cost
    }
    
    var description: String {
        ""
    }
}

class ConnectionManager:
    NSObject,
    ObservableObject,
    MCSessionDelegate,
    MCNearbyServiceBrowserDelegate,
    MCNearbyServiceAdvertiserDelegate
{
    internal typealias PeerId = Int64
    internal typealias Cost = UInt64

    @Published internal var sessionPeers: [MCPeerID:MCSessionState] = [:] // update unit
    @Published internal var allNodes: [PeerId:NodeMessageManager] = [:] // update unit

    private let debugUI: Bool

    internal var peersByHash: [PeerId:MCPeerID] = [:] // update unit
    private var previouslyConnectedPeers: Set<MCPeerID> = Set()

    private(set) var selfId: MCPeerID

//    internal struct ForwardingEntry: ForwardingEntryProtocol {
//        var linkId: ConnectionManager.PeerId
//        
//        var cost: ConnectionManager.Cost
//        
//        init(linkId: ConnectionManager.PeerId, cost: ConnectionManager.Cost) {
//            self.linkId = linkId
//            self.cost = cost
//        }
//        
//        typealias P = PeerId
//        typealias C = Cost
//
//        var description: String {
//            "LinkID: \(self.linkId), Cost: \(self.cost)"
//        }
//    }
    internal var routingNode: DistanceVectorRoutingNode<PeerId, Cost, DVNodeSendDelegate, ForwardingEntry>?

    internal var browser: MCNearbyServiceBrowser?

    internal var advertiser: MCNearbyServiceAdvertiser?

    internal var sessionsByPeer: [MCPeerID:MCSession] = [:] // update unit

    // sequence number for identifying latency messages
    private let kEWMAFactor: Double = 0.875
    @Published internal var estimatedLatencyByPeerInNs: [MCPeerID:Double?] = [:] // update unit
    private var pingTimer: Timer?
    private let kPingInterval: TimeInterval = 1.0
    private var pingStartTimeNs: UInt64?
    private var pingSeqNum: UInt32 = 0
    private let pingSemaphore: DispatchSemaphore = DispatchSemaphore(value: 1)
    private var expectedPingReplies: UInt = 0
    private var currPingReplies: UInt = 0

    init(
        displayName: String,
        debugSessionPeers: [MCPeerID:MCSessionState],
        debugAllNodes: [PeerId:NodeMessageManager]
    ) {
        debugUI = true
        selfId = MCPeerID(displayName: displayName)
        sessionPeers = debugSessionPeers
        allNodes = debugAllNodes
    }

    init(displayName: String) {
        debugUI = false
        selfId = MCPeerID(displayName: displayName)

        let sendDelegate = DVNodeSendDelegate()
        let updateDelegate = NodeUpdateDelegate()
        routingNode = DistanceVectorRoutingNode(
            selfId: Int64(selfId.hashValue),
            dvUpdateThreshold: 1,
            sendDelegate: sendDelegate,
            updateDelegate: updateDelegate
        )

        browser = MCNearbyServiceBrowser(
            peer: selfId,
            serviceType: kServiceType
        )

        advertiser = MCNearbyServiceAdvertiser(
            peer: selfId,
            discoveryInfo: ["app": "MeshNetworkTest"],
            serviceType: kServiceType
        )

        pingTimer = nil

        // `self` initialized now
        super.init()

        pingTimer = Timer.scheduledTimer(
            withTimeInterval: kPingInterval,
            repeats: true
        ) { _ in
            weak var weakTimerOwner = self
            if let owner = weakTimerOwner {
                Task {
                    owner.initiateLatencyTest()
                }
            }
        }


        sendDelegate.owner = self
        updateDelegate.owner = self

        browser!.delegate = self
        advertiser!.delegate = self

        advertiser!.startAdvertisingPeer()
    }

    deinit {
        guard debugUI == false else {
            return
        }

        pingTimer!.invalidate()
        advertiser!.stopAdvertisingPeer()
    }
    
    public func startBrowsingAndAdvertising() {
        guard debugUI == false else {
            return
        }

        browser!.startBrowsingForPeers()
    }

    public func stopBrowsingAndAdvertising() {
        guard debugUI == false else {
            return
        }

        browser!.stopBrowsingForPeers()
    }

    public func connect(toPeer peer: MCPeerID) {
        guard debugUI != nil else {
            return
        }

        // Make sure peer is discovered but not connected
        guard sessionPeers[peer] == MCSessionState.notConnected else {
            print("TRIED TO CONNECT TO PEER IN NOT NOT CONNECTED STATE.")
            return
        }

        print("INVITING OTHER PEER TO SESSION")

        var session = sessionsByPeer[peer]
        if session == nil {
            session = MCSession(peer: selfId)
            session!.delegate = self
            sessionsByPeer[peer] = session
        }

        browser!.invitePeer(
            peer,
            to: session!,
            withContext: nil /* TODO */,
            timeout: TimeInterval(30.0)
        )
    }

    public func disconnect(fromPeer peer: MCPeerID) {
        guard sessionPeers[peer] != nil else {
            print("TRIED TO DISCONNECT FROM PEER NOT DISCOVERED.")
            return
        }

        if let session = self.sessionsByPeer[peer] {
            session.disconnect()
            self.sessionsByPeer.removeValue(forKey: peer)
        }
        self.peersByHash.removeValue(forKey: Int64(peer.hashValue))

        DispatchQueue.main.async { @MainActor in
            self.allNodes.removeValue(forKey: Int64(peer.hashValue))
            self.sessionPeers.removeValue(forKey: peer)
        }

        Task {
            try await self.routingNode!.updateLinkCost(linkId: Int64(peer.hashValue), newCost: nil)
        }
    }

    public func send(
        toPeer peerId: PeerId,
        message: String,
        with reliability: MCSessionSendDataMode
    ) async throws {
        guard debugUI == false else {
            return
        }

        guard let (nextHop, _) = await self.routingNode!.getLinkForDest(dest: peerId) else {
            print("NEXT HOP DOES NOT EXIST FOR DESTINATION.")
            return
        }

        guard let peerObj = self.peersByHash[nextHop] else {
            fatalError("Connection manager is not aware of peer in the routing node.")
        }

        // Make sure that a session exists for the peer
        guard let session = self.sessionsByPeer[peerObj] else {
            print("TRIED TO SEND TO PEER WITHOUT A SESSION.")
            return
        }

        let data: Data = try MessageWrapper.with {
            $0.type = .messenger
            $0.data = .messengerMessage(MessengerMessage.with {
                $0.from = Int64(selfId.hashValue)
                $0.to = Int64(peerId)
                $0.message = message
            })
        }.serializedData()

        try session.send(data, toPeers: [peerObj], with: reliability)
    }

    func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        guard peersByHash.contains(where: { $0.value == peerID }) else {
            fatalError("Received session callback from peer which has not been discovered.")
        }

        guard sessionsByPeer[peerID] != nil else {
            fatalError("Session state changed for peer without a session.")
        }

        print("Session state changed for \(peerID.displayName) from \(self.sessionPeers[peerID]!) to \(state)")

        DispatchQueue.main.async { @MainActor in
            self.sessionPeers[peerID] = state
        }

        switch state {
        case .notConnected:
            Task {
                try await self.routingNode!.updateLinkCost(linkId: Int64(peerID.hashValue), newCost: nil)
            }
        case .connecting:
            Task {
                try await self.routingNode!.updateLinkCost(linkId: Int64(peerID.hashValue), newCost: nil)
            }
        case .connected:
            self.previouslyConnectedPeers.insert(peerID)
            Task {
                try await self.routingNode!.updateLinkCost(linkId: Int64(peerID.hashValue), newCost: 1 /* TODO */)
            }
        @unknown default:
            fatalError("Unkonwn peer state in ConnectionManager.session")
        }
    }
    
    func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        guard peersByHash.contains(where: { $0.value == peerID }) &&
              sessionPeers[peerID] != nil else {
            fatalError("Received session callback from peer which has not been discovered.")
        }

        guard let message = try? MessageWrapper(serializedData: data) else {
            fatalError("Received malformed data")
        }

        switch message.type {
        case MessageType.network:
            let networkMessage = message.networkMessage
            Task {
                print("RECEIVED DV \(networkMessage.distanceVector)")
                await self.routingNode!.recvDistanceVector(
                    fromNeighbor: Int64(peerID.hashValue),
                    withDistanceVector: networkMessage.distanceVector
                )
            }
        case MessageType.measurement:
            print("LATENCY REPLY")
            let measurementMessage = message.measurementMessage

            if measurementMessage.initiatingPeerID == self.selfId.hashValue {
                completeLatencyTest(fromPeer: peerID, withSeqNum: measurementMessage.sequenceNumber)
            } else {
                // reply to the ping
                try? session.send(data, toPeers: [peerID], with: .unreliable)
            }
        case MessageType.messenger:
            print("RECEIVING MESSAGE")
            // Forward to message manager
            let messengerMessage = message.messengerMessage
            DispatchQueue.main.async { Task { @MainActor in
                if messengerMessage.to == self.selfId.hashValue {
                    self.allNodes[messengerMessage.from]?
                        .recvMessage(message: messengerMessage.message)
                } else {
                    try await self.send(
                        toPeer: messengerMessage.to,
                        message: messengerMessage.message,
                        with: .reliable
                    )
                }
            }}
        default:
            fatalError("Unexpected message type in ConnectionManager.SessionDelegate.session")
            // Don't forward to user: Not tagged correctly
        }
    }
    
    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        fatalError("Session streams not implemented.")
    }
    
    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        fatalError("Session resources not implemented.")
    }
    
    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        fatalError("Session resources not implemented.")
    }

    func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        // TODO handle errors
    }

    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String : String]?
    ) {
        guard browser === self.browser else {
            return
        }

        print("FOUND PEER")
        print("\(peerID)")
        print("\(peerID.hashValue)")
        print("\(info)")
        print("")

        // Advertisement must be from an instance of this app
        guard info?["app"] == "MeshNetworkTest" else {
            return
        }

        // Connection state must be empty or not connected
        let state = self.sessionPeers[peerID]
        guard state == nil || state == MCSessionState.notConnected else {
            return
        }

        self.peersByHash[Int64(peerID.hashValue)] = peerID

        DispatchQueue.main.async { @MainActor in
            self.sessionPeers[peerID] = MCSessionState.notConnected
        }

        // Automatically reconnect if the peer was connected before
        if self.previouslyConnectedPeers.contains(peerID) {
            self.connect(toPeer: peerID)
        }
    }
    
    func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        guard browser === self.browser else {
            return
        }

        print("LOST PEER")

        self.disconnect(fromPeer: peerID)
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        // TODO handle errors
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard advertiser === self.advertiser else {
            return
        }

        // TODO use context (untrusted!)

        guard self.sessionsByPeer[peerID] == nil else {
            print("INVITED TO SESSION BUT ALREADY IN SESSION")
            return
        }

        guard self.sessionPeers[peerID] == MCSessionState.notConnected else {
            print("INVITED TO SESSION BUT ALREADY NOT NOT CONNECTED TO PEER")
            return
        }

        print("INVITED TO SESSION")

        let newSession = MCSession(peer: self.selfId)
        newSession.delegate = self
        self.sessionsByPeer[peerID] = newSession
        invitationHandler(true, newSession)

        self.peersByHash[Int64(peerID.hashValue)] = peerID
    }

    internal class DVNodeSendDelegate: SendDelegate {
        internal weak var owner: ConnectionManager?
        private let jsonEncoder: JSONEncoder = JSONEncoder()

        init(owner: ConnectionManager? = nil) {
            self.owner = owner
        }

        func send(
            from: any SWIMNet.PeerIdT,
            sendTo peerId: any SWIMNet.PeerIdT,
            withDVDict dv: any Sendable
        ) async throws {
            guard let peerId = self.owner!.peersByHash[peerId as! PeerId] else {
                fatalError("TRIED TO SEND DISTANCE VECTOR TO UNDISCOVERED PEER")
            }

            guard let session = self.owner!.sessionsByPeer[peerId] else {
                fatalError("TRIED TO SEND DISTANCE VECTOR TO PEER WITHOUT SESSION")
            }

            let data = try! MessageWrapper.with {
                $0.type = .network
                $0.data = .networkMessage(NetworkMessage.with {
                    $0.distanceVector = (dv as! DistanceVectorRoutingNode<PeerId, Cost, DVNodeSendDelegate, ForwardingEntry>.DistanceVector)
                })
            }.serializedData()

            try session.send(
                data,
                toPeers: [peerId],
                with: MCSessionSendDataMode.reliable
            )
        }
    }

    internal class NodeUpdateDelegate: AvailableNodesUpdateDelegate {
        internal weak var owner: ConnectionManager?

        init(owner: ConnectionManager? = nil) {
            self.owner = owner
        }

        func availableNodesDidUpdate(newAvailableNodes: [any SWIMNet.PeerIdT]) {
            print("AVAILABLE NODES UPDATED WITH \(newAvailableNodes)")
            DispatchQueue.main.async { @MainActor in
                for node in newAvailableNodes {
                    // Don't include self
                    guard (node as! PeerId) != self.owner!.selfId.hashValue else {
                        continue
                    }

                    if self.owner!.allNodes[node as! PeerId] == nil {
                        self.owner!.allNodes[node as! PeerId] = NodeMessageManager(
                            peerId: node as! PeerId,
                            connectionManager: self.owner!
                        )
                    }
                }

                for (_, nodeMessageManager) in self.owner!.allNodes {
                    if !newAvailableNodes.contains(where: { $0 as! PeerId == nodeMessageManager.peerId}) {
                        nodeMessageManager.available = false
                    }
                }
            }
        }
    }

    private func initiateLatencyTest() {
        // FIXME need to lock `sessionsByPeer` in this function

        // Make sure that `pingStartTimeNs` is valid for
        // `kPingInterval / 2` seconds, then continue anyway with a new sequence
        // number
        _ = pingSemaphore.wait(timeout: DispatchTime(uptimeNanoseconds: UInt64(1_000_000_000 * kPingInterval / 2.0)))
        pingSeqNum += 1
        expectedPingReplies = UInt(sessionsByPeer.count)

        var timeBaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timeBaseInfo)
        let timeUnits = mach_absolute_time()
        pingStartTimeNs = timeUnits * UInt64(timeBaseInfo.numer) / UInt64(timeBaseInfo.denom)

        let data = try! MessageWrapper.with {
            $0.type = .measurement
            $0.data = .measurementMessage(MeasurementMessage.with {
                $0.initiatingPeerID = Int64(selfId.hashValue)
                $0.sequenceNumber = pingSeqNum
            })
        }.serializedData()

        Task {
            try! await withThrowingTaskGroup(of: Void.self) { group in
                for (neighborId, neighborSession) in sessionsByPeer {
                    group.addTask {
                        try neighborSession.send(
                            data,
                            toPeers: [neighborId],
                            with: .unreliable
                        )
                    }
                }

                try await group.waitForAll()
            }
        }
    }

    private func completeLatencyTest(fromPeer: MCPeerID, withSeqNum seqNum: UInt32) {
        // FIXME need to lock `sessionsByPeer` in this function

        guard seqNum == pingSeqNum else {
            return
        }

        guard let currPingStartTimeNs = pingStartTimeNs else {
            // received uninitiated latency message with correct sequence number
            return
        }

        // Must be still connected to the peer to record latency
        guard sessionsByPeer.contains(where: { $0.key == fromPeer }) else {
            return
        }

        var timeBaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timeBaseInfo)
        let timeUnits = mach_absolute_time()
        let currPingEndTimeNs = timeUnits * UInt64(timeBaseInfo.numer) / UInt64(timeBaseInfo.denom)
        let currLatency = Double(currPingEndTimeNs - currPingStartTimeNs) / 2.0

        if let lastLatency = estimatedLatencyByPeerInNs[fromPeer] {
            estimatedLatencyByPeerInNs[fromPeer] =
                (kEWMAFactor * lastLatency!) + ((1.0 - kEWMAFactor) * currLatency)
        } else {
            estimatedLatencyByPeerInNs[fromPeer] = currLatency
        }

        currPingReplies += 1
        if currPingReplies == expectedPingReplies {
            currPingReplies = 0
            pingSemaphore.signal()
        }
    }
}
