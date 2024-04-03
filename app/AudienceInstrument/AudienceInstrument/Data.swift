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

@MainActor final class ConnectionManagerModel: ConnectionManagerModelProtocol {
    @Published var sessionPeers: [MCPeerID : MCSessionState]
    @Published var allNodes: [PeerId : NodeMessageManager]
    @Published var estimatedLatencyByPeerInNs: [MCPeerID : Double]
    private let connectionManager: ConnectionManager?
    @Published var ready: Bool = false
    private let debugUI: Bool

    init(
        sessionPeers: [MCPeerID : MCSessionState] = [:],
        allNodes: [PeerId : NodeMessageManager] = [:],
        estimatedLatencyByPeerInNs: [MCPeerID : Double] = [:],
        debugUI: Bool = false
    ) {
        self.sessionPeers = sessionPeers
        self.allNodes = allNodes
        self.estimatedLatencyByPeerInNs = estimatedLatencyByPeerInNs

        self.debugUI = debugUI
        guard debugUI == false else {
            connectionManager = nil
            return
        }

        connectionManager = ConnectionManager(displayName: UIDevice.current.name)
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

    public func send(
        toPeer peerId: PeerId,
        message: String,
        with reliability: MCSessionSendDataMode
    ) async throws {
        guard debugUI == false else {
            return
        }

        try await connectionManager?.send(toPeer: peerId, message: message, with: reliability)
    }
}
