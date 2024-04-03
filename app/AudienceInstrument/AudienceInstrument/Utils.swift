//
//  Utils.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 3/20/24.
//

import Foundation
import MultipeerConnectivity

@MainActor func createMockConnectionManagerModel() -> ConnectionManagerModel {
    let n = [ // Theoretically available nodes
        /* 0 */ MCPeerID(displayName: "Peer 1"), // connected peer
        /* 1 */ MCPeerID(displayName: "Peer 2"), // connecting peer
        /* 2 */ MCPeerID(displayName: "Peer 3"), // not connected peer
        /* 3 */ MCPeerID(displayName: "Peer 4"), // available in mesh network
        /* 4 */ MCPeerID(displayName: "Peer 5"), // available in mesh network
        /* 5 */ MCPeerID(displayName: "Peer 6"), // available in mesh network
        /* 6 */ MCPeerID(displayName: "Peer 10") // newly discovered peer
    ]


    let sessionPeers = [
        n[0]: MCSessionState.connected,
        n[1]: MCSessionState.connecting,
        n[2]: MCSessionState.notConnected,
        n[6]: MCSessionState.notConnected
    ]

    let allNodes = [
        Int64(n[0].hashValue):NodeMessageManager(peerId: Int64(n[0].hashValue)),
        Int64(n[1].hashValue):NodeMessageManager(peerId: Int64(n[1].hashValue)),
        Int64(n[2].hashValue):NodeMessageManager(peerId: Int64(n[2].hashValue)),
        Int64(n[3].hashValue):NodeMessageManager(peerId: Int64(n[3].hashValue)),
        Int64(n[4].hashValue):NodeMessageManager(peerId: Int64(n[4].hashValue)),
        Int64(n[5].hashValue):NodeMessageManager(peerId: Int64(n[5].hashValue))
    ]

    let estimatedLatencyByPeerInNs: [MCPeerID:Double] = [
        n[1]: 8_000_135,
        n[2]: 5_047_300,
        n[3]: 6_200_140,
        n[5]: 11_000_930,
        n[6]: 10_750_333
    ]

    let debugConnectionManagerModel = ConnectionManagerModel(
        sessionPeers: sessionPeers,
        allNodes: allNodes,
        estimatedLatencyByPeerInNs: estimatedLatencyByPeerInNs,
        debugUI: true
    )

    for (_, nodeMessageManager) in allNodes {
        nodeMessageManager.connectionManagerModel = debugConnectionManagerModel
    }

    let sampleMessages = [
        "Hi",
        "Would you like to talk?",
        "No",
        "Ok",
        "Bye"
    ]

    for messageManager in allNodes.values {
        messageManager.messages = sampleMessages
    }

    return debugConnectionManagerModel
}
