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
    var estimatedLatencyByPeerInNs: [DistanceManager.PeerID:UInt64] { get set }
    var sessionPeersByPeerID: [DistanceManager.PeerID:MCPeerID] { get set }
}

extension ForwardingEntry: ForwardingEntryProtocol {
    init(linkID: UInt64, cost: UInt64) {
        self.linkID = linkID
        self.cost = cost
    }
    
    var description: String {
        ""
    }
}

protocol NeighborMessageReceiver {
    func receiveMessage(
        message: NeighborAppMessage,
        from: ConnectionManager.PeerId,
        receivedAt: UInt64
    ) async throws
}

protocol NeighborMessageSendDelegate {
    // Same TODO: PeerID type should be somewhere else
    func send(toPeers: [ConnectionManager.PeerId], withMessages: [MessageWrapper], withReliability: MCSessionSendDataMode)
    func send(toPeers: [ConnectionManager.PeerId], withMessage: MessageWrapper, withReliability: MCSessionSendDataMode)
}

protocol NeighborMessageSender {
    func registerSendDelegate(delegate: any NeighborMessageSendDelegate, selfID: ConnectionManager.PeerId) async
    func addPeers(peers: [ConnectionManager.PeerId]) async
    func removePeers(peers: [ConnectionManager.PeerId]) async
}

/// Important to only set connection manager model once and to start advertising/browsing _after_ model is set
actor ConnectionManager:
    NSObject,
    MCSessionDelegate,
    MCNearbyServiceBrowserDelegate,
    MCNearbyServiceAdvertiserDelegate
{
    typealias PeerId = UInt64
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

    private let neighborApps: [any NeighborMessageSender & NeighborMessageReceiver]

    internal var browser: MCNearbyServiceBrowser?

    internal var advertiser: MCNearbyServiceAdvertiser?

    init(
        displayName: String,
        neighborApps: [any NeighborMessageSender & NeighborMessageReceiver] = [],
        debugUI: Bool = false
    ) {
        self.selfId = MCPeerID(displayName: displayName)

        #if DEBUG
        print("Self ID: \(displayName)")
        print("Self ID Number: \(self.selfId.id)")
        #endif

        self.neighborApps = neighborApps

        self.debugUI = debugUI
        guard debugUI == false else {
            super.init()
            return
        }

        let sendDelegate = DVNodeSendDelegate()
        let updateDelegate = NodeUpdateDelegate()
        routingNode = DistanceVectorRoutingNode(
            selfId: selfId.id,
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

        // `self` initialized now
        super.init()

        sendDelegate.owner = self
        updateDelegate.owner = self

        browser!.delegate = self
        advertiser!.delegate = self
        Task {
            for neighborApp in neighborApps {
                await neighborApp.registerSendDelegate(
                    delegate: sendDelegate,
                    selfID: ConnectionManager.PeerId(self.selfId.id)
                )
            }
        }
    }

    deinit {
        #if DEBUG
        print("Deinitializing ConnectionManager!")
        #endif

        guard debugUI == false else {
            return
        }

        advertiser!.stopAdvertisingPeer()
        for session in sessionsByPeer.values {
            session.disconnect()
        }
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
        self.peersByHash.removeValue(forKey: peer.id)

        DispatchQueue.main.async {
            model.allNodes.removeValue(forKey: peer.id)
            model.sessionPeers.removeValue(forKey: peer)
            model.sessionPeersByPeerID.removeValue(forKey: peer.id)
        }

        Task {
            try await self.routingNode!.updateLinkCost(linkId: peer.id, newCost: nil)
        }
    }

    // FIXME: Move messenger stuff out of connection manager
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
            $0.data = .meshAppMessage(MeshAppMessage.with {
                $0.data = .messengerMessage(MessengerMessage.with {
                    $0.from = selfId.id
                    $0.to = peerId
                    $0.message = message
                })
            })
        }.serializedData()

        try session.send(data, toPeers: [peerObj], with: reliability)
    }

/* //////////////////////////////////////////////////////////////////////// */
/* MARK: Session */
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
                try await self.routingNode!.updateLinkCost(linkId: ConnectionManager.PeerId(peerID.id), newCost: nil)
                for neighborApp in neighborApps {
                    await neighborApp.removePeers(peers: [ConnectionManager.PeerId(peerID.id)])
                }
            case .connecting:
                try await self.routingNode!.updateLinkCost(linkId: ConnectionManager.PeerId(peerID.id), newCost: nil)
            case .connected:
                await addPreviouslyConnectedPeer(peerID: peerID)
                for neighborApp in neighborApps {
                    await neighborApp.addPeers(peers: [ConnectionManager.PeerId(peerID.id)])
                }
                try await self.routingNode!.updateLinkCost(linkId: ConnectionManager.PeerId(peerID.id), newCost: 1 /* TODO */)
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
        let recvTime = getCurrentTimeInNs()
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
                    fromNeighbor: peerID.id,
                    withDistanceVector: networkMessage.distanceVector
                )
            case .neighborAppMessage(let appMessage):
                for neighborApp in neighborApps {
                    do {
                        try await neighborApp.receiveMessage(message: appMessage, from: ConnectionManager.PeerId(peerID.id), receivedAt: recvTime)
                    } catch {
                        print("Failed receiving message at neighbor app: \(error).")
                    }
                }
            case .meshAppMessage(let appMessage):
                switch appMessage.data {
                case .messengerMessage(let messengerMessage):
                    print("RECEIVING MESSAGE")
                    // Forward to message manager
                    DispatchQueue.main.async { Task { @MainActor in
                        if await messengerMessage.to == self.selfId.id {
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
                    fatalError("Unexpected mesh application message type in ConnectionManager.SessionDelegate.session")
                }
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
/* MARK: Browser */
/* //////////////////////////////////////////////////////////////////////// */

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        // TODO: handle errors
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
            print("\(peerID.id)")
            print("\(String(describing: info))")
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

            await updatePeersByHash(peerIDHash: peerID.id, peerID: peerID)

            DispatchQueue.main.async { @MainActor in
                model.sessionPeers[peerID] = MCSessionState.notConnected
                model.sessionPeersByPeerID[peerID.id] = peerID
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
/* MARK: Advertiser */
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

            await updatePeersByHash(peerIDHash: peerID.id, peerID: peerID)
            DispatchQueue.main.async {
                model.sessionPeersByPeerID[peerID.id] = peerID
            }
        }
    }

/* //////////////////////////////////////////////////////////////////////// */
/* MARK: DVNodeSendDelegate */
/* //////////////////////////////////////////////////////////////////////// */

    private class DVNodeSendDelegate: SendDelegate, NeighborMessageSendDelegate {
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

        // TODO: These functions are kind of stupid
        func send(toPeers peers: [ConnectionManager.PeerId], withMessages messages: [MessageWrapper], withReliability reliability: MCSessionSendDataMode) {
            guard messages.count == peers.count else {
                #if DEBUG
                fatalError("SendDelegate: Number of messages for multi-message send not equal to number of peers!")
                #endif
                return
            }

            for i in 0..<peers.count {
                self.send(toPeers: [peers[i]], withMessage: messages[i], withReliability: reliability)
            }
        }
        
        func send(toPeers peers: [ConnectionManager.PeerId], withMessage message: MessageWrapper, withReliability reliability: MCSessionSendDataMode) {
            // TODO: figure out the different sessions thing
            Task {
                for peer in peers {
                    guard let mcPeer = await self.owner!.peersByHash[peer] else {
                        fatalError("SendDelegate: TRIED TO SEND TO PEER NOT IN peersByHash")
                    }

                    guard let session = await self.owner!.sessionsByPeer[mcPeer] else {
                        fatalError("SendDelegate: TRIED TO SEND TO PEER WITHOUT SESSION")
                    }

                    do {
                        let dataOut = try message.serializedData()
                        try session.send(
                            dataOut,
                            toPeers: [mcPeer],
                            with: reliability
                        )
                    } catch {
                        #if DEBUG
                        print("SendDelegate: Failed to send message to peers with error: \(error)")
                        #endif
                    }
                }
            }
        }
    }

/* //////////////////////////////////////////////////////////////////////// */
/* MARK: NodeUpdateDelegate */
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
                        let ownerSelfId = await self.owner!.selfId.id
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

    private func updatePeersByHash(peerIDHash: UInt64, peerID: MCPeerID) async {
        // Because this has to be isolated for one of the delegate callbacks
        self.peersByHash[peerIDHash] = peerID
    }

    private func addPreviouslyConnectedPeer(peerID: MCPeerID) async {
        // Because this has to be isolated for one of the delegate callbacks
        self.previouslyConnectedPeers.insert(peerID)
    }
}
