//
//  Utils.swift
//  MeshNetworkTest
//
//  Created by Andrew Orals on 3/20/24.
//

import Foundation
import MultipeerConnectivity

func createMockConnectionManager() -> ConnectionManager {
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
        n[0].hashValue:NodeMessageManager(peerId: n[0].hashValue),
        n[1].hashValue:NodeMessageManager(peerId: n[1].hashValue),
        n[2].hashValue:NodeMessageManager(peerId: n[2].hashValue),
        n[3].hashValue:NodeMessageManager(peerId: n[3].hashValue),
        n[4].hashValue:NodeMessageManager(peerId: n[4].hashValue),
        n[5].hashValue:NodeMessageManager(peerId: n[5].hashValue)
    ]

    let debugUIConnectionManager = ConnectionManager(
        displayName: "Peer 0",
        debugSessionPeers: sessionPeers,
        debugAllNodes: allNodes
    )

    for (_, nodeMessageManager) in allNodes {
        nodeMessageManager.connectionManager = debugUIConnectionManager
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

    return debugUIConnectionManager
}
