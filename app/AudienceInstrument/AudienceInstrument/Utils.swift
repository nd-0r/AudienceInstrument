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

    let estimatedLatencyByPeerInNs: [MCPeerID:UInt64] = [
        n[1]: 8_000_135,
        n[2]: 5_047_300,
        n[3]: 6_200_140,
        n[5]: 11_000_930,
        n[6]: 10_750_333
    ]

    let estimatedDistanceByPeerInM: [MCPeerID:DistanceManager.PeerDist] = [
        n[0]: .noneCalculated,
        n[1]: .someCalculated(4.21),
        n[2]: .someCalculated(1.2),
        n[3]: .someCalculated(6.13),
        n[4]: .noneCalculated,
        n[5]: .someCalculated(7.98),
        n[6]: .someCalculated(0.333)
    ]

    let debugConnectionManagerModel = ConnectionManagerModel(
        sessionPeers: sessionPeers,
        allNodes: allNodes,
        estimatedLatencyByPeerInNs: estimatedLatencyByPeerInNs,
        estimatedDistanceByPeerInM: estimatedDistanceByPeerInM,
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


@inline(__always)
func getCurrentTimeInNs() -> UInt64 {
    var timeBaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timeBaseInfo)
    let timeUnits = mach_absolute_time()

    return timeUnits * UInt64(timeBaseInfo.numer) / UInt64(timeBaseInfo.denom)
}

@inline(__always)
func binarySearch(lowerBound: Int, upperBound: Int, tooLowPredicate tlp: (Int) -> Bool) -> Int {
    var lb = lowerBound
    var ub = upperBound
    
    while lb != ub {
        let curr = lb + (ub - lb) / 2
        if tlp(curr) {
            lb = curr + 1
        } else {
            ub = curr
        }
    }

    return lb
}
