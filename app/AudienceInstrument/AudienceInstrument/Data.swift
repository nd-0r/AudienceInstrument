//
//  Data.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 3/20/24.
//

import Foundation
import MultipeerConnectivity

let kServiceType = "andreworals-AIn"
let kDiscoveryApp = "AudienceInstrument"

@MainActor final class ConnectionManagerModel: ConnectionManagerModelProtocol, PingManagerUpdateDelegate {
    @Published var sessionPeers: [MCPeerID : MCSessionState]
    @Published var allNodes: [ConnectionManager.PeerId : NodeMessageManager]
    @Published var estimatedLatencyByPeerInNs: [MCPeerID : UInt64]
    @Published var estimatedDistanceByPeerInM: [MCPeerID : DistanceManager.PeerDist]
    private let connectionManager: ConnectionManager!
    @Published var ready: Bool = false
    private let debugUI: Bool

    init(
        sessionPeers: [MCPeerID : MCSessionState] = [:],
        allNodes: [ConnectionManager.PeerId : NodeMessageManager] = [:],
        estimatedLatencyByPeerInNs: [MCPeerID : UInt64] = [:],
        estimatedDistanceByPeerInM: [MCPeerID : DistanceManager.PeerDist] = [:],
        debugUI: Bool = false
    ) {
        self.sessionPeers = sessionPeers
        self.allNodes = allNodes
        self.estimatedLatencyByPeerInNs = estimatedLatencyByPeerInNs
        self.estimatedDistanceByPeerInM = estimatedDistanceByPeerInM

        self.debugUI = debugUI
        guard debugUI == false else {
            connectionManager = nil
            return
        }

        let latencyNeighborApp = PingManager()
        let distanceNeighborApp = DistanceManagerNetworkModule()
        distanceNeighborApp.speakerInitTimeout = .seconds(2)
        distanceNeighborApp.speakerSpeakTimeout = .seconds(2)

        self.connectionManager = ConnectionManager(
            displayName: UIDevice.current.name,
            neighborApps: [latencyNeighborApp, distanceNeighborApp]
        )

        let distanceCalculator = DistanceCalculator(
            peerLatencyCalculator: latencyNeighborApp
        )
        DistanceManager.setup(distanceCalculator: distanceCalculator)

        Task {
            await latencyNeighborApp.registerUpdateDelegate(delegate: self)
            distanceNeighborApp.connectionManagerModel = self
        }

        Task { @MainActor in
            await connectionManager!.setConnectionManagerModel(newModel: self)
            await connectionManager!.startAdvertising()
            ready = true
        }
    }

    public func startAdvertising() {
        guard debugUI == false else {
            return
        }

        ready = false
        Task { @MainActor in
            await connectionManager?.startAdvertising()
            ready = true
        }
    }
    
    public func startBrowsing() {
        guard debugUI == false else {
            return
        }

        ready = false
        Task { @MainActor in
            await connectionManager?.startBrowsing()
            ready = true
        }
    }

    public func stopBrowsing() {
        guard debugUI == false else {
            return
        }

        ready = false
        Task { @MainActor in
            await connectionManager?.stopBrowsing()
            ready = true
        }
    }

    public func connect(toPeer peer: MCPeerID) {
        guard debugUI == false else {
            return
        }

        ready = false
        Task { @MainActor in
            await connectionManager?.connect(toPeer: peer)
            ready = true
        }
    }

    public func disconnect(fromPeer peer: MCPeerID) {
        guard debugUI == false else {
            return
        }

        ready = false
        Task { @MainActor in
            await connectionManager?.disconnect(fromPeer: peer)
            ready = true
        }
    }

// MARK: Distance functions

    // TODO: Make throwing
    public func initiateDistanceCalculation(withNeighbors neighbors: [MCPeerID]) {
        #if DEBUG
        print("Initiating distance calculation with neighbors: \(neighbors)")
        #endif
        DistanceManager.initiate(retries: 2, withInitTimeout: .seconds(10), withSpokeTimeout: .seconds(10), toPeers: neighbors)
    }

// MARK: Messaging functions

    public func send(
        toPeer peerId: ConnectionManager.PeerId,
        message: String,
        with reliability: MCSessionSendDataMode
    ) async throws {
        guard debugUI == false else {
            return
        }

        try await connectionManager?.send(toPeer: peerId, message: message, with: reliability)
    }

    nonisolated func didUpdate(latenciesByPeer: [MCPeerID : UInt64]) {
        Task { @MainActor in
            self.estimatedLatencyByPeerInNs = latenciesByPeer
        }
    }
}
