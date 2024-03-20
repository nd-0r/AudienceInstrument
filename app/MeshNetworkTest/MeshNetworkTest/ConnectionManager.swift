//
//  ConnectionManager.swift
//  MeshNetworkTest
//
//  Created by Andrew Orals on 3/16/24.
//

import Foundation
import MultipeerConnectivity
import SWIMNet

class ConnectionManager: ObservableObject {
    @Published internal var sessionPeers: [MCPeerID:MCSessionState] = [:]
    @Published internal var discoveredPeers: [MCPeerID] = []
    @Published internal var allNodes: [Int:NodeMessageManager] = [:]

    internal var peersByHash: [Int:MCPeerID] = [:]
    private(set) var selfId: MCPeerID
    internal var routingNode: DistanceVectorRoutingNode<Int, UInt64, DVNodeSendDelegate>
    private var routingNodeUpdateDelegate: NodeUpdateDelegate

    internal var browser: MCNearbyServiceBrowser
    private var browserDelegate: NearbyServiceBrowserDelegate

    internal var advertiser: MCNearbyServiceAdvertiser
    private var advertiserDelegate: NearbyServiceAdvertiserDelegate

    internal var session: MCSession
    private var sessionDelegate: SessionDelegate

    private let kApplicationLevelMagic: UInt8 = 0x00
    private let kNetworkLevelMagic: UInt8 = 0xff
    private let kUnknownMagic: UInt8 = 0xaa

    private let jsonEncoder = JSONEncoder()

    init(displayName: String) {
        selfId = MCPeerID(displayName: displayName)

        let routingNodeSendDelegate = DVNodeSendDelegate()
        routingNode = DistanceVectorRoutingNode(
            selfId: selfId.hashValue,
            dvUpdateThreshold: 1,
            sendDelegate: routingNodeSendDelegate
        )
        routingNodeUpdateDelegate = NodeUpdateDelegate()

        browser = MCNearbyServiceBrowser(
            peer: selfId,
            serviceType: "" /* TODO */
        )
        browserDelegate = NearbyServiceBrowserDelegate()

        advertiser = MCNearbyServiceAdvertiser(
            peer: self.selfId,
            discoveryInfo: nil /* TODO */,
            serviceType: "" /* TODO */
        )
        advertiserDelegate = NearbyServiceAdvertiserDelegate()

        self.sessionDelegate = SessionDelegate()
        session = MCSession(peer: selfId)
        session.delegate = self.sessionDelegate

        routingNodeSendDelegate.owner = self
        self.routingNodeUpdateDelegate.owner = self
        browserDelegate.owner = self
        advertiserDelegate.owner = self
        sessionDelegate.owner = self

        browser.delegate = self.browserDelegate
        advertiser.delegate = self.advertiserDelegate

        browser.startBrowsingForPeers()
        advertiser.startAdvertisingPeer()
    }

    deinit {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
    }

    public func send(
        messageData: NodeMessageManager.NodeMessage,
        toPeer peerId: Int,
        with reliability: MCSessionSendDataMode
    ) async throws {
        guard let nextHop = await self.routingNode.getLinkForDest(dest: peerId) else {
            return
        }

        let data = try jsonEncoder.encode(messageData)

        try session.send(
            Data(repeating: kApplicationLevelMagic, count: 1)
                + data,
            toPeers: [self.peersByHash[nextHop.0]!],
            with: reliability
        )
    }

    internal class NodeUpdateDelegate: AvailableNodesUpdateDelegate {
        internal weak var owner: ConnectionManager?

        init(owner: ConnectionManager? = nil) {
            self.owner = owner
        }

        func availableNodesDidUpdate(newAvailableNodes: [any SWIMNet.PeerIdT]) {
            for node in newAvailableNodes {
                if owner?.allNodes[node as! Int] == nil {
                    owner!.allNodes[node as! Int] = NodeMessageManager(
                        peerId: node as! Int,
                        connectionManager: self.owner!
                    )
                }
            }
        }
    }

    internal class SessionDelegate: NSObject, MCSessionDelegate {
        internal weak var owner: ConnectionManager?

        init(owner: ConnectionManager? = nil) {
            self.owner = owner
        }

        func session(
            _ session: MCSession,
            peer peerID: MCPeerID,
            didChange state: MCSessionState
        ) {
            guard self.owner != nil &&
                  session === self.owner!.session else {
                return
            }

            self.owner!.sessionPeers[peerID] = state
            Task {
                switch state {
                case .notConnected:
                    try await self.owner!.routingNode.updateLinkCost(linkId: peerID.hashValue, newCost: nil)
                case .connecting:
                    try await self.owner!.routingNode.updateLinkCost(linkId: peerID.hashValue, newCost: nil)
                case .connected:
                    try await self.owner!.routingNode.updateLinkCost(linkId: peerID.hashValue, newCost: 1 /* TODO */)
                @unknown default:
                    fatalError("Unkonwn peer state in ConnectionManager.session")
                }
            }
        }
        
        func session(
            _ session: MCSession,
            didReceive data: Data,
            fromPeer peerID: MCPeerID
        ) {
            guard self.owner != nil &&
                  session === self.owner!.session else {
                return
            }

            let magic = data.first ?? self.owner!.kUnknownMagic

            switch magic {
            case self.owner!.kNetworkLevelMagic:
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

                    await self.owner!.routingNode.recvDistanceVector(
                        fromNeighbor: peerID.hashValue,
                        withDistanceVector: dv
                    )
                }
            case self.owner!.kApplicationLevelMagic:
                // Forward to message manager
                Task { @MainActor in
                    let decoder = JSONDecoder()
                    let nodeMessage = try decoder.decode(
                        NodeMessageManager.NodeMessage.self,
                        from: data.suffix(from: 1)
                    )

                    self.owner!.allNodes[nodeMessage.from]?
                        .recvMessage(message: nodeMessage.message)
                }
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
            guard self.owner != nil &&
                  session === self.owner!.session else {
                return
            }

            // TODO not used
//            owner!.clientSessionDelegate.session(
//                session,
//                didReceive: stream,
//                withName: streamName,
//                fromPeer: peerID
//            )
        }
        
        func session(
            _ session: MCSession,
            didStartReceivingResourceWithName resourceName: String,
            fromPeer peerID: MCPeerID,
            with progress: Progress
        ) {
            guard self.owner != nil &&
                  session === self.owner!.session else {
                return
            }

            // TODO not used
//            owner!.clientSessionDelegate.session(
//                session,
//                didStartReceivingResourceWithName: resourceName,
//                fromPeer: peerID,
//                with: progress
//            )
        }
        
        func session(
            _ session: MCSession,
            didFinishReceivingResourceWithName resourceName: String,
            fromPeer peerID: MCPeerID,
            at localURL: URL?,
            withError error: Error?
        ) {
            guard self.owner != nil &&
                  session === self.owner!.session else {
                return
            }

            // TODO not used
//            owner!.clientSessionDelegate.session(
//                session,
//                didFinishReceivingResourceWithName: resourceName,
//                fromPeer: peerID,
//                at: localURL,
//                withError: error
//            )
        }
    }

    internal class DVNodeSendDelegate: SendDelegate {
        internal weak var owner: ConnectionManager?
        private let jsonEncoder: JSONEncoder = JSONEncoder()

        func send(
            from: any SWIMNet.PeerIdT,
            sendTo peerId: any SWIMNet.PeerIdT,
            withDVDict dv: any Sendable & Codable
        ) async throws {
            guard owner != nil else {
                return
            }

            let jsonData = try jsonEncoder.encode(dv)
            try self.owner!.session.send(
                Data(repeating: owner!.kNetworkLevelMagic, count: 1) + jsonData,
                toPeers: [self.owner!.peersByHash[peerId as! Int]!],
                with: MCSessionSendDataMode.reliable
            )
        }

        init(owner: ConnectionManager? = nil) {
            self.owner = owner
        }
    }

    private class NearbyServiceBrowserDelegate: NSObject, MCNearbyServiceBrowserDelegate {
        internal weak var owner: ConnectionManager?

        init(owner: ConnectionManager? = nil) {
            self.owner = owner
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
            guard self.owner != nil &&
                  browser === self.owner!.browser else {
                return
            }

            // TODO use discovery info
            Task { @MainActor in
                self.owner!.discoveredPeers.append(peerID)
            }
        }
        
        func browser(
            _ browser: MCNearbyServiceBrowser,
            lostPeer peerID: MCPeerID
        ) {
            guard self.owner != nil &&
                  browser === self.owner!.browser else {
                return
            }

            Task { @MainActor in
                self.owner!.discoveredPeers.removeAll(where: { $0 == peerID })
            }
        }
    }

    private class NearbyServiceAdvertiserDelegate: NSObject, MCNearbyServiceAdvertiserDelegate {
        internal weak var owner: ConnectionManager?

        init(owner: ConnectionManager? = nil) {
            self.owner = owner
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
            guard self.owner != nil &&
                  advertiser === self.owner!.advertiser else {
                return
            }

            // TODO use context (untrusted!)

            invitationHandler(true, self.owner!.session)

            self.owner!.peersByHash[peerID.hashValue] = peerID

            Task { @MainActor in
                self.owner!.sessionPeers[peerID] = MCSessionState.connecting
            }
        }
    }
}
