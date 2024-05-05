//
//  Data.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 3/20/24.
//

import Foundation
import MultipeerConnectivity
import CoreBluetooth

let kServiceType = "andreworals-AIn"
let kDiscoveryApp = "AudienceInstrument"

struct BluetoothService {
    static let serviceUUID = CBUUID(string: "104F5F16-C192-4FD1-9892-EAB6E724DE39")
    static let characteristicUUID = CBUUID(string: "7E5B9510-2372-4760-8F49-2C3EE56EFBBA")
    typealias LengthPrefixType = UInt8
    static let lengthPrefixSize = BluetoothService.LengthPrefixType(
        MemoryLayout<LengthPrefixType>.stride
    )
    static let rssiDiscoveryThresh = -80
    // TODO: update?
    static let spokeTimeout: DispatchTimeInterval = .seconds(60)
}

@MainActor final class ConnectionManagerModel: ConnectionManagerModelProtocol {
    @Published var sessionPeers: [MCPeerID : MCSessionState]
    @Published var allNodes: [ConnectionManager.PeerId : NodeMessageManager]
    @Published var estimatedLatencyByPeerInNs: [DistanceManager.PeerID : UInt64]
    @Published var estimatedDistanceByPeerInM: [DistanceManager.PeerID : DistanceManager.PeerDist]
    @Published var sessionPeersByPeerID: [DistanceManager.PeerID:MCPeerID]
    private let connectionManager: ConnectionManager!
    @Published var ready: Bool = false
    private let debugUI: Bool

    init(
        sessionPeers: [MCPeerID : MCSessionState] = [:],
        allNodes: [ConnectionManager.PeerId : NodeMessageManager] = [:],
        estimatedLatencyByPeerInNs: [DistanceManager.PeerID : UInt64] = [:],
        estimatedDistanceByPeerInM: [DistanceManager.PeerID : DistanceManager.PeerDist] = [:],
        debugUI: Bool = false
    ) {
        self.sessionPeers = sessionPeers
        self.allNodes = allNodes
        self.estimatedLatencyByPeerInNs = estimatedLatencyByPeerInNs
        self.estimatedDistanceByPeerInM = estimatedDistanceByPeerInM
        self.sessionPeersByPeerID = Dictionary(
            uniqueKeysWithValues: sessionPeers.map({
                (k, _) in (k.id, k)
            })
        )

        self.debugUI = debugUI
        guard debugUI == false else {
            connectionManager = nil
            return
        }

        let distanceNeighborApp = DistanceManagerNetworkModule()

        let randomIDString = generatePeerIDString()

        self.connectionManager = ConnectionManager(
            displayName: randomIDString,
            neighborApps: [distanceNeighborApp]
        )

        distanceNeighborApp.connectionManagerModel = self

        Task { @MainActor in
            let speakTimerCentral = SpeakTimerCentral(
                selfID: await connectionManager.selfId.id
            )
            let spokePeripheral = SpokePeripheral(
                selfID: await connectionManager.selfId.id
            )
            let distanceCalculator = DistanceCalculator(
                peerLatencyCalculator: nil
            )

            DistanceManager.setup(
                speakTimerDelegate: speakTimerCentral,
                spokeDelegate: spokePeripheral,
                distanceCalculator: distanceCalculator
            )

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
    public func initiateDistanceCalculation(withNeighbors neighbors: [DistanceManager.PeerID]) {
        #if DEBUG
        print("Initiating distance calculation with neighbors: \(neighbors)")
        #endif
        // currently `withSpokeTimeout` is overridden by the bluetooth stuff
        DistanceManager.initiate(
            retries: 2,
            withInitTimeout: .seconds(60),
            withSpokeTimeout: .seconds(60),
            toPeers: neighbors
        )
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

    nonisolated func didUpdate(latenciesByPeer: [DistanceManager.PeerID : UInt64]) {
        Task { @MainActor in
            self.estimatedLatencyByPeerInNs = latenciesByPeer
        }
    }
}
