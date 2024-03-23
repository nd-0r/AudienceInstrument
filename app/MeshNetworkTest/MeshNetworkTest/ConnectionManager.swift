//
//  ConnectionManager.swift
//  MeshNetworkTest
//
//  Created by Andrew Orals on 3/16/24.
//

import Foundation
import MultipeerConnectivity
import SWIMNet

class ConnectionManager:
    NSObject,
    ObservableObject,
    MCSessionDelegate,
    MCNearbyServiceBrowserDelegate,
    MCNearbyServiceAdvertiserDelegate
{
    @Published internal var sessionPeers: [MCPeerID:MCSessionState] = [:]
    @Published internal var allNodes: [Int:NodeMessageManager] = [:]

    private let debugUI: Bool

    internal var peersByHash: [Int:MCPeerID] = [:]
    private var previouslyConnectedPeers: Set<MCPeerID> = Set()

    private(set) var selfId: MCPeerID
    internal var routingNode: DistanceVectorRoutingNode<Int, UInt64, DVNodeSendDelegate>?

    internal var browser: MCNearbyServiceBrowser?

    internal var advertiser: MCNearbyServiceAdvertiser?

    internal var sessionsByPeer: [MCPeerID:MCSession] = [:]

    private let kApplicationLevelMagic: UInt8 = 0x00
    private let kNetworkLevelMagic: UInt8 = 0xff
    private let kUnknownMagic: UInt8 = 0xaa

    private let jsonEncoder = JSONEncoder()

    init(
        displayName: String,
        debugSessionPeers: [MCPeerID:MCSessionState],
        debugAllNodes: [Int:NodeMessageManager]
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
            selfId: selfId.hashValue,
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

        // `self` initialized now
        super.init()

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
        guard debugUI != nil else {
            return
        }

        guard sessionPeers[peer] != nil else {
            print("TRIED TO DISCONNECT FROM PEER NOT DISCOVERED.")
            return
        }

        if let session = self.sessionsByPeer[peer] {
            session.disconnect()
            self.sessionsByPeer.removeValue(forKey: peer)
        }
        self.peersByHash.removeValue(forKey: peer.hashValue)

        DispatchQueue.main.async { @MainActor in
            self.allNodes.removeValue(forKey: peer.hashValue)
            self.sessionPeers.removeValue(forKey: peer)
        }

        Task {
            try await self.routingNode!.updateLinkCost(linkId: peer.hashValue, newCost: nil)
        }
    }

    public func send(
        messageData: NodeMessageManager.NodeMessage,
        toPeer peerId: Int,
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

        let data = try jsonEncoder.encode(messageData)

        try session.send(
            Data(repeating: kApplicationLevelMagic, count: 1) + data,
            toPeers: [peerObj],
            with: reliability
        )
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
                try await self.routingNode!.updateLinkCost(linkId: peerID.hashValue, newCost: nil)
            }
        case .connecting:
            Task {
                try await self.routingNode!.updateLinkCost(linkId: peerID.hashValue, newCost: nil)
            }
        case .connected:
            self.previouslyConnectedPeers.insert(peerID)
            Task {
                try await self.routingNode!.updateLinkCost(linkId: peerID.hashValue, newCost: 1 /* TODO */)
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

        let magic = data.first ?? self.kUnknownMagic

        switch magic {
        case self.kNetworkLevelMagic:
            print("RECEIVING DV")
            Task {
                let decoder = JSONDecoder()
                let dv = try decoder.decode(
                    DistanceVectorRoutingNode<
                        Int,
                        UInt64,
                        ConnectionManager.DVNodeSendDelegate
                    >.DistanceVector.self,
                    from: data.suffix(from: 1)
                )

                print("RECEIVED DV \(dv)")

                await self.routingNode!.recvDistanceVector(
                    fromNeighbor: peerID.hashValue,
                    withDistanceVector: dv
                )
            }
        case self.kApplicationLevelMagic:
            print("RECEIVING MESSAGE")
            // Forward to message manager
            DispatchQueue.main.async { Task { @MainActor in
                let decoder = JSONDecoder()
                let nodeMessage = try decoder.decode(
                    NodeMessageManager.NodeMessage.self,
                    from: data.suffix(from: 1)
                )

                if nodeMessage.to == self.selfId.hashValue {
                    print("RECEIVED MESSAGE \(nodeMessage)")
                    self.allNodes[nodeMessage.from]?
                        .recvMessage(message: nodeMessage.message)
                } else {
                    print("FORWARDED MESSAGE \(nodeMessage)")
                    try await self.send(
                        messageData: nodeMessage,
                        toPeer: nodeMessage.to,
                        with: MCSessionSendDataMode.reliable
                    )
                }

            }}
        default:
            fatalError("Unexpected magic byte in data ConnectionManager.SessionDelegate.session")
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

        self.peersByHash[peerID.hashValue] = peerID

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

        self.peersByHash[peerID.hashValue] = peerID
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
            withDVDict dv: any Sendable & Codable
        ) async throws {
            guard let peerId = self.owner!.peersByHash[peerId as! Int] else {
                fatalError("TRIED TO SEND DISTANCE VECTOR TO UNDISCOVERED PEER")
            }

            guard let session = self.owner!.sessionsByPeer[peerId] else {
                fatalError("TRIED TO SEND DISTANCE VECTOR TO PEER WITHOUT SESSION")
            }

            let jsonData = try jsonEncoder.encode(dv)
            try session.send(
                Data(repeating: self.owner!.kNetworkLevelMagic, count: 1) + jsonData,
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
                    guard (node as! Int) != self.owner!.selfId.hashValue else {
                        continue
                    }

                    if self.owner!.allNodes[node as! Int] == nil {
                        self.owner!.allNodes[node as! Int] = NodeMessageManager(
                            peerId: node as! Int,
                            connectionManager: self.owner!
                        )
                    }
                }

                for (_, nodeMessageManager) in self.owner!.allNodes {
                    if !newAvailableNodes.contains(where: { $0 as! Int == nodeMessageManager.peerId}) {
                        nodeMessageManager.available = false
                    }
                }
            }
        }
    }
}
