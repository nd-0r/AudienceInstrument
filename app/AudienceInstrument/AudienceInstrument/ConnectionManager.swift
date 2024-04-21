//
//  ConnectionManager.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 3/16/24.
//

import Foundation
import MultipeerConnectivity
import SWIMNet
import Darwin.Mach

@MainActor
protocol ConnectionManagerModelProtocol: ObservableObject {
    var sessionPeers: [MCPeerID:MCSessionState] { get set }
    var allNodes: [ConnectionManager.PeerId:NodeMessageManager] { get set }
    var estimatedLatencyByPeerInNs: [MCPeerID:Double] { get set }
}

extension ForwardingEntry: ForwardingEntryProtocol {
    init(linkID: Int64, cost: UInt64) {
        self.linkID = linkID
        self.cost = cost
    }
    
    var description: String {
        ""
    }
}

/// Important to only set connection manager model once and to start advertising/browsing _after_ model is set
actor ConnectionManager:
    NSObject,
    MCSessionDelegate,
    MCNearbyServiceBrowserDelegate,
    MCNearbyServiceAdvertiserDelegate
{
    typealias PeerId = Int64
    typealias Cost = UInt64

    private var _connectionManagerModel: (any ConnectionManagerModelProtocol)? = nil
    var connectionManagerModel: (any ConnectionManagerModelProtocol)? {
        set {
            if _connectionManagerModel == nil {
                _connectionManagerModel = newValue
            } else {
                fatalError("Connection manager model must only be set once.")
            }
        } get {
            return _connectionManagerModel
        }
    }
    /// For use from main actor isolation
    func setConnectionManagerModel(newModel: (any ConnectionManagerModelProtocol)?) {
        connectionManagerModel = newModel
    }

    // Peer properties
    internal var sessionsByPeer: [MCPeerID:MCSession] = [:]
    internal var peersByHash: [PeerId:MCPeerID] = [:]
    private var previouslyConnectedPeers: Set<MCPeerID> = Set()
    // End peer properties

    nonisolated private let debugUI: Bool
    private(set) var selfId: MCPeerID

    private var routingNode: DistanceVectorRoutingNode<PeerId, Cost, DVNodeSendDelegate, ForwardingEntry>?

    internal var browser: MCNearbyServiceBrowser?

    internal var advertiser: MCNearbyServiceAdvertiser?

    // Latency properties
    nonisolated private let pingTimer: Timer?
    nonisolated private let pingSemaphore: DispatchSemaphore = DispatchSemaphore(value: 1)
    nonisolated private let kEWMAFactor: Double = 0.875
    nonisolated private let kPingInterval: TimeInterval = 1.0

    private var pingStartTimeNs: UInt64? = nil
    private var pingSeqNum: UInt32 = 0
    private var expectedPingReplies: UInt = 0
    private var currPingReplies: UInt = 0
    // End latency properties

    init(
        displayName: String,
        debugUI: Bool = false
    ) {
        selfId = MCPeerID(displayName: displayName)

        self.debugUI = debugUI
        guard debugUI == false else {
            pingTimer = nil
            super.init()
            return
        }

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
            discoveryInfo: ["app": kDiscoveryApp],
            serviceType: kServiceType
        )

        class TimerClosure { // lol
            weak var owner: ConnectionManager? = nil

            func callAsFunction() -> Void {
                if let owner = self.owner {
                    owner.initiateLatencyTestHelper()
                }
            }
        }

        let timerClosure = TimerClosure()
        pingTimer = Timer.scheduledTimer(
            withTimeInterval: kPingInterval,
            repeats: true
        ) { _ in timerClosure() }

        // `self` initialized now
        super.init()

        RunLoop.current.add(pingTimer!, forMode: .common)

        sendDelegate.owner = self
        updateDelegate.owner = self
        timerClosure.owner = self

        browser!.delegate = self
        advertiser!.delegate = self
    }

    deinit {
        guard debugUI == false else {
            return
        }

        pingTimer!.invalidate()
        advertiser!.stopAdvertisingPeer()
    }

    public func startAdvertising() async {
        guard debugUI == false else {
            return
        }

        advertiser!.startAdvertisingPeer()
        print("STARTED ADVERTISING")
    }
    
    public func startBrowsing() async {
        guard debugUI == false else {
            return
        }

        browser!.startBrowsingForPeers()
        print("STARTED BROWSING")
    }

    public func stopBrowsing() async {
        guard debugUI == false else {
            return
        }

        browser!.stopBrowsingForPeers()
        print("STOPPED BROWSING")
    }

    public func connect(toPeer peer: MCPeerID) async {
        guard let model = connectionManagerModel else {
            print("MODEL DEINITIALIZED")
            return
        }

        // Make sure peer is discovered but not connected
        guard await model.sessionPeers[peer] == MCSessionState.notConnected else {
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

    public func disconnect(fromPeer peer: MCPeerID) async {
        guard let model = connectionManagerModel else {
            print("MODEL DEINITIALIZED")
            return
        }

        guard await model.sessionPeers[peer] != nil else {
            print("TRIED TO DISCONNECT FROM PEER NOT DISCOVERED.")
            return
        }

        if let session = self.sessionsByPeer[peer] {
            session.disconnect()
            self.sessionsByPeer.removeValue(forKey: peer)
        }
        self.peersByHash.removeValue(forKey: Int64(peer.hashValue))

        DispatchQueue.main.async {
            model.allNodes.removeValue(forKey: Int64(peer.hashValue))
            model.sessionPeers.removeValue(forKey: peer)
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
            $0.data = .messengerMessage(MessengerMessage.with {
                $0.from = Int64(selfId.hashValue)
                $0.to = Int64(peerId)
                $0.message = message
            })
        }.serializedData()

        try session.send(data, toPeers: [peerObj], with: reliability)
    }

/* //////////////////////////////////////////////////////////////////////// */
/* Session */
/* //////////////////////////////////////////////////////////////////////// */

    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        Task {
            guard let model = await connectionManagerModel else {
                print("MODEL DEINITIALIZED")
                return
            }

            guard await peersByHash.contains(where: { $0.value == peerID }) else {
                fatalError("Received session callback from peer which has not been discovered.")
            }

            guard await sessionsByPeer[peerID] != nil else {
                fatalError("Session state changed for peer without a session.")
            }

            print("Session state changed for \(peerID.displayName) from \(await model.sessionPeers[peerID]!) to \(state)")

            DispatchQueue.main.async { @MainActor in
                model.sessionPeers[peerID] = state
            }

            switch state {
            case .notConnected:
                try await self.routingNode!.updateLinkCost(linkId: Int64(peerID.hashValue), newCost: nil)
            case .connecting:
                try await self.routingNode!.updateLinkCost(linkId: Int64(peerID.hashValue), newCost: nil)
            case .connected:
                await addPreviouslyConnectedPeer(peerID: peerID)
                try await self.routingNode!.updateLinkCost(linkId: Int64(peerID.hashValue), newCost: 1 /* TODO */)
            @unknown default:
                fatalError("Unkonwn peer state in ConnectionManager.session")
            }
        }
    }
    
    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        Task { @MainActor in
            guard let model = await connectionManagerModel else {
                print("MODEL DEINITIALIZED")
                return
            }

            guard await peersByHash.contains(where: { $0.value == peerID }) &&
                  model.sessionPeers[peerID] != nil else {
                fatalError("Received session callback from peer which has not been discovered.")
            }

            guard let message = try? MessageWrapper(serializedData: data) else {
                fatalError("Received malformed data")
            }

            switch message.data! {
            case .networkMessage(let networkMessage):
                print("RECEIVED DV \(networkMessage.distanceVector)")
                await self.routingNode!.recvDistanceVector(
                    fromNeighbor: Int64(peerID.hashValue),
                    withDistanceVector: networkMessage.distanceVector
                )
            case .measurementMessage(var measurementMessage):
//                print("LATENCY REPLY")
                let recvTimeInNs = getCurrentTimeInNs()

                if await measurementMessage.initiatingPeerID == self.selfId.hashValue {
                    await completeLatencyTest(
                        fromPeer: peerID,
                        withSeqNum: measurementMessage.sequenceNumber,
                        withReplyDelay: measurementMessage.delayInNs
                    )
                } else {
                    // reply to the ping
                    measurementMessage.delayInNs = getCurrentTimeInNs() - recvTimeInNs
                    let outData = try! message.serializedData()

                    do {
                        try session.send(outData, toPeers: [peerID], with: .unreliable)
                    } catch {
                        print("Failed to reply to ping from \(peerID) with error: \(error)")
                    }
                }
            case .messengerMessage(let messengerMessage):
                print("RECEIVING MESSAGE")
                // Forward to message manager
                DispatchQueue.main.async { Task { @MainActor in
                    if await messengerMessage.to == self.selfId.hashValue {
                        model.allNodes[messengerMessage.from]?
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
    }
    
    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        fatalError("Session streams not implemented.")
    }
    
    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        fatalError("Session resources not implemented.")
    }
    
    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        fatalError("Session resources not implemented.")
    }

/* //////////////////////////////////////////////////////////////////////// */
/* Browser */
/* //////////////////////////////////////////////////////////////////////// */

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        // TODO handle errors
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String : String]?
    ) {
        Task {
            guard await browser === self.browser else {
                return
            }

            guard let model = await connectionManagerModel else {
                print("MODEL DEINITIALIZED")
                return
            }

            print("FOUND PEER")
            print("\(peerID)")
            print("\(peerID.hashValue)")
            print("\(info)")
            print("")

            // Advertisement must be from an instance of this app
            guard info?["app"] == kDiscoveryApp else {
                return
            }

            // Connection state must be empty or not connected
            let state = await model.sessionPeers[peerID]
            guard state == nil || state == MCSessionState.notConnected else {
                return
            }

            await updatePeersByHash(peerIDHash: Int64(peerID.hashValue), peerID: peerID)

            DispatchQueue.main.async { @MainActor in
                model.sessionPeers[peerID] = MCSessionState.notConnected
            }

            // Automatically reconnect if the peer was connected before
            if await self.previouslyConnectedPeers.contains(peerID) {
                await self.connect(toPeer: peerID)
            }
        }
    }
    
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        Task {
            guard await browser === self.browser else {
                return
            }

            print("LOST PEER")

            // TODO if this happens while the model is nil things could get messed up
            await self.disconnect(fromPeer: peerID)
        }
    }

/* //////////////////////////////////////////////////////////////////////// */
/* Advertiser */
/* //////////////////////////////////////////////////////////////////////// */

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        // TODO handle errors
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task {
            guard await advertiser === self.advertiser else {
                return
            }

            guard let model = await connectionManagerModel else {
                print("MODEL DEINITIALIZED")
                return
            }

            // TODO use context (untrusted!)

            guard await self.sessionsByPeer[peerID] == nil else {
                print("INVITED TO SESSION BUT ALREADY IN SESSION")
                return
            }

            guard await model.sessionPeers[peerID] == MCSessionState.notConnected else {
                print("INVITED TO SESSION BUT ALREADY NOT NOT CONNECTED TO PEER")
                return
            }

            print("INVITED TO SESSION")

            let newSession = await MCSession(peer: self.selfId)
            newSession.delegate = self
            await updateSessionsByPeer(peerID: peerID, newSession: newSession)
            invitationHandler(true, newSession)

            await updatePeersByHash(peerIDHash: Int64(peerID.hashValue), peerID: peerID)
        }
    }

/* //////////////////////////////////////////////////////////////////////// */
/* DVNodeSendDelegate */
/* //////////////////////////////////////////////////////////////////////// */

    private class DVNodeSendDelegate: SendDelegate {
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
            guard let peerId = await self.owner!.peersByHash[peerId as! PeerId] else {
                fatalError("TRIED TO SEND DISTANCE VECTOR TO UNDISCOVERED PEER")
            }

            guard let session = await self.owner!.sessionsByPeer[peerId] else {
                fatalError("TRIED TO SEND DISTANCE VECTOR TO PEER WITHOUT SESSION")
            }

            let data = try! MessageWrapper.with {
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

/* //////////////////////////////////////////////////////////////////////// */
/* NodeUpdateDelegate */
/* //////////////////////////////////////////////////////////////////////// */

    private class NodeUpdateDelegate: AvailableNodesUpdateDelegate {
        internal weak var owner: ConnectionManager?

        init(owner: ConnectionManager? = nil) {
            self.owner = owner
        }

        func availableNodesDidUpdate(newAvailableNodes: [any SWIMNet.PeerIdT]) {
            print("AVAILABLE NODES UPDATED WITH \(newAvailableNodes)")
            DispatchQueue.main.async {
                Task { @MainActor in
                    guard let model = await self.owner!.connectionManagerModel else {
                        print("MODEL DEINITIALIZED")
                        return
                    }

                    for node in newAvailableNodes {
                        // Don't include self
                        let ownerSelfId = await self.owner!.selfId.hashValue
                        guard (node as! PeerId) != ownerSelfId else {
                            continue
                        }

                        if model.allNodes[node as! PeerId] == nil {
                            model.allNodes[node as! PeerId] = NodeMessageManager(
                                peerId: node as! PeerId,
                                connectionManagerModel: await (self.owner!.connectionManagerModel! as? ConnectionManagerModel)
                            )
                        }
                    }

                    for (_, nodeMessageManager) in model.allNodes {
                        if !newAvailableNodes.contains(where: { $0 as! PeerId == nodeMessageManager.peerId}) {
                            nodeMessageManager.available = false
                        }
                    }
                }
            }
        }
    }

/* //////////////////////////////////////////////////////////////////////// */
/* Private interface */
/* //////////////////////////////////////////////////////////////////////// */
    private func updateSessionsByPeer(peerID: MCPeerID, newSession: MCSession) async {
        // Because this has to be isolated for one of the delegate callbacks
        self.sessionsByPeer[peerID] = newSession
    }

    private func updatePeersByHash(peerIDHash: Int64, peerID: MCPeerID) async {
        // Because this has to be isolated for one of the delegate callbacks
        self.peersByHash[peerIDHash] = peerID
    }

    private func addPreviouslyConnectedPeer(peerID: MCPeerID) async {
        // Because this has to be isolated for one of the delegate callbacks
        self.previouslyConnectedPeers.insert(peerID)
    }

    /// Synchronous because called from timer
    nonisolated private func initiateLatencyTestHelper() {
        // Make sure that `pingStartTimeNs` is valid for
        // `kPingInterval / 2` seconds, then continue anyway with a new sequence
        // number
        _ = pingSemaphore.wait(timeout: DispatchTime(uptimeNanoseconds: UInt64(1_000_000_000 * kPingInterval / 2.0)))
        Task {
            await self.initiateLatencyTest()
        }
    }

    private func initiateLatencyTest() async {
        pingSeqNum += 1
        expectedPingReplies = UInt(sessionsByPeer.count)
        pingStartTimeNs = getCurrentTimeInNs()

        let data = try! MessageWrapper.with {
            $0.data = .measurementMessage(MeasurementMessage.with {
                $0.initiatingPeerID = Int64(selfId.hashValue)
                $0.sequenceNumber = pingSeqNum
            })
        }.serializedData()

        await withTaskGroup(of: Void.self) { group in
            for (neighborId, neighborSession) in sessionsByPeer {
                guard neighborSession.connectedPeers.contains(where: { $0 == neighborId }) else {
                    continue
                }

                group.addTask {
                    do {
                        try neighborSession.send(
                            data,
                            toPeers: [neighborId],
                            with: .unreliable
                        )
                    } catch {
                        print("Failed to ping \(neighborId) with error: \(error)")
                    }
                }
            }

            await group.waitForAll()
        }
    }

    private func completeLatencyTest(
        fromPeer: MCPeerID,
        withSeqNum seqNum: UInt32,
        withReplyDelay replyDelay: UInt64
    ) async {
        guard seqNum == pingSeqNum else {
            // A message from a stray ping round shouldn't get past here
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

        guard let model = connectionManagerModel else {
            print("MODEL DEINITIALIZED")
            return
        }

        let currLatency = Double(getCurrentTimeInNs() - currPingStartTimeNs - replyDelay) / 2.0

        if let lastLatency = await model.estimatedLatencyByPeerInNs[fromPeer] {
            Task { @MainActor in
                model.estimatedLatencyByPeerInNs[fromPeer] =
                    (kEWMAFactor * lastLatency) + ((1.0 - kEWMAFactor) * currLatency)
            }
        } else {
            Task { @MainActor in
                model.estimatedLatencyByPeerInNs[fromPeer] = currLatency
            }
        }

        currPingReplies += 1
        if currPingReplies == expectedPingReplies {
            currPingReplies = 0
            pingSemaphore.signal()
        }
    }

}
