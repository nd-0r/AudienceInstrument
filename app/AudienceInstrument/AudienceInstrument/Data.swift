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
    // Allocate each buffer to be the maximum size of a message plus the size of
    //   the length prefix padded to a multiple of 16 bytes
    static let bufSize =
    Int((
        1 + ((
            BluetoothService.LengthPrefixType(
                MemoryLayout<DistanceProtocolWrapper>.stride
            ) + BluetoothService.lengthPrefixSize
        ) >> 4)
    ) << 4)
    static let rssiDiscoveryThresh = -80
    // TODO: update?
    static let spokeTimeout: DispatchTimeInterval = .seconds(60)
}

@MainActor final class ConnectionManagerModel: ConnectionManagerModelProtocol {
    @Published var sessionPeers: [DistanceManager.PeerID]
    @Published var sessionPeersState: [DistanceManager.PeerID : MCSessionState]
    @Published var allNodes: [DistanceManager.PeerID : NodeMessageManager]
    @Published var estimatedLatencyByPeerInNs: [DistanceManager.PeerID : UInt64]
    @Published var estimatedDistanceByPeerInM: [DistanceManager.PeerID : DistanceManager.PeerDist]
    private let connectionManager: ConnectionManager!
    @Published var ready: Bool = false
    private let debugUI: Bool
    private var speakTimerCentral: SpeakTimerCentral! = nil
    private var spokePeripheral: SpokePeripheral! = nil
    private var distanceCalculator: DistanceCalculator! = nil
    private var distanceNeighborApp: DistanceManagerNetworkModule! = nil

    init(
        sessionPeers: [DistanceManager.PeerID : MCSessionState] = [:],
        allNodes: [DistanceManager.PeerID : NodeMessageManager] = [:],
        estimatedLatencyByPeerInNs: [DistanceManager.PeerID : UInt64] = [:],
        estimatedDistanceByPeerInM: [DistanceManager.PeerID : DistanceManager.PeerDist] = [:],
        debugUI: Bool = false
    ) {
        self.sessionPeersState = sessionPeers
        self.sessionPeers = Array(sessionPeers.keys)
        self.allNodes = allNodes
        self.estimatedLatencyByPeerInNs = estimatedLatencyByPeerInNs
        self.estimatedDistanceByPeerInM = estimatedDistanceByPeerInM

        self.debugUI = debugUI
        guard debugUI == false && isUnitTest == false else {
            connectionManager = nil
            return
        }

        self.distanceNeighborApp = DistanceManagerNetworkModule()

        let randomIDString = generatePeerIDString()

        self.connectionManager = ConnectionManager(
            displayName: randomIDString,
            neighborApps: [distanceNeighborApp]
        )

        distanceNeighborApp.connectionManagerModel = self

        Task { @MainActor in
            self.speakTimerCentral = SpeakTimerCentral(
                selfID: await connectionManager.selfID
            )
            self.spokePeripheral = SpokePeripheral(
                selfID: await connectionManager.selfID
            )
            self.distanceCalculator = DistanceCalculator(
                peerLatencyCalculator: nil
            )

            DistanceManager.setup(
                speakTimerDelegate: speakTimerCentral,
                spokeDelegate: spokePeripheral,
                distanceCalculator: distanceCalculator
            )

            await connectionManager!.setConnectionManagerModel(newModel: self)
            await connectionManager!.startAdvertising()
            self.ready = true
        }
    }

    deinit {
        #if DEBUG
        print("Deinitialized ConnectionManagerModel!")
        #endif
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

    public func connect(toPeer peer: DistanceManager.PeerID) {
        guard debugUI == false else {
            return
        }

        ready = false
        Task { @MainActor in
            await connectionManager?.connect(toPeer: peer)
            ready = true
        }
    }

    public func disconnect(fromPeer peer: DistanceManager.PeerID) {
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
        toPeer peerId: DistanceManager.PeerID,
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
