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
        n[0].id:NodeMessageManager(peerId: n[0].id),
        n[1].id:NodeMessageManager(peerId: n[1].id),
        n[2].id:NodeMessageManager(peerId: n[2].id),
        n[3].id:NodeMessageManager(peerId: n[3].id),
        n[4].id:NodeMessageManager(peerId: n[4].id),
        n[5].id:NodeMessageManager(peerId: n[5].id)
    ]

    let estimatedLatencyByPeerInNs: [ConnectionManager.PeerId:UInt64] = [
        n[1].id: 8_000_135,
        n[2].id: 5_047_300,
        n[3].id: 6_200_140,
        n[5].id: 11_000_930,
        n[6].id: 10_750_333
    ]

    let estimatedDistanceByPeerInM: [ConnectionManager.PeerId:DistanceManager.PeerDist] = [
        n[0].id: .noneCalculated,
        n[1].id: .someCalculated(4.21),
        n[2].id: .someCalculated(1.2),
        n[3].id: .someCalculated(6.13),
        n[4].id: .noneCalculated,
        n[5].id: .someCalculated(7.98),
        n[6].id: .someCalculated(0.333)
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
func convertHostTimeToNanos(_ hostTime: UInt64) -> UInt64 {
    var timeBaseInfo = mach_timebase_info_data_t()
    mach_timebase_info(&timeBaseInfo)
    return hostTime * UInt64(timeBaseInfo.numer) / UInt64(timeBaseInfo.denom)
}

@inline(__always)
func getCurrentTimeInNs() -> UInt64 {
    let timeUnits = mach_absolute_time()
    return convertHostTimeToNanos(timeUnits)
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

@inline(__always)
func generateRandom64BitInteger() -> UInt64 {
    let upper32 = UInt64(arc4random_uniform(UInt32.max))
    let lower32 = UInt64(arc4random_uniform(UInt32.max))

    return (upper32 << 32) | lower32
}

extension BluetoothService {
    private static let kEWMAFactor: Double = 0.875

    static func serializeLength(_ len: BluetoothService.LengthPrefixType, toBuffer buf: inout Data) {
        withUnsafeBytes(of: len) { rawBufPtr in
            #if DEBUG
            assert(rawBufPtr.count == BluetoothService.lengthPrefixSize)
            #endif
            buf = Data(bytes: rawBufPtr.baseAddress!, count: rawBufPtr.count)
        }
        #if DEBUG
        print("\(#function): Serialized \(buf.count) bytes")
        #endif
    }

    static func serializeMeasurementMessage(_ message: MeasurementMessage, toBuffer buf: inout Data) {
        buf = try! message.serializedData()
        #if DEBUG
        print("\(#function): Serialized \(buf.count) bytes")
        #endif
    }

    static func serializeProtocolMessage(_ message: DistanceProtocolWrapper, toBuffer buf: inout Data) {
        buf = try! message.serializedData()
        #if DEBUG
        print("\(#function): Serialized \(buf.count) bytes")
        #endif
    }

    /// It took me hours of debugging to realize that a "slice" or "subrange" or whatever
    /// they want to call it of data has the same indices as the original data. I guess it's to prevent memory
    /// leaks and make the language more "safe." But it's confusing as hell. No more "safe" languages.
    static func deserializeLength(fromBuffer: Data) -> BluetoothService.LengthPrefixType {
        var len: BluetoothService.LengthPrefixType = 0
        let buf = Data(fromBuffer)
        withUnsafeMutablePointer(to: &len) { ptr in
            buf.copyBytes(to: ptr, count: Int(BluetoothService.lengthPrefixSize))
        }
        #if DEBUG
        print("\(#function): Deserialized \(fromBuffer.count) bytes")
        #endif
        return len
    }

    static func deserializeMeasurementMessage(fromBuffer: Data) -> MeasurementMessage {
        #if DEBUG
        print("\(#function): Deserialized \(fromBuffer.count) bytes")
        #endif
        let buf = Data(fromBuffer)
        return try! MeasurementMessage(serializedData: buf)
    }

    static func deserializeProtocolMessage(fromBuffer: Data) -> DistanceProtocolWrapper {
        #if DEBUG
        print("\(#function): Deserialized \(fromBuffer.count) bytes")
        #endif
        let buf = Data(fromBuffer)
        return try! DistanceProtocolWrapper(serializedData: buf)
    }

    // TODO: function can be optimized
    static func calcLatency(
        lastLatency: UInt64?,
        lastPingRecvTimeInNS lastRecvTime: UInt64,
        pingRecvTimeInNS recvTime: UInt64,
        delayAtPeripheralInNS delay: UInt64
    ) -> UInt64 {
        let estOneWayLatency = ((recvTime - lastRecvTime) - delay)
        return UInt64(
            Self.kEWMAFactor * Double(lastLatency ?? estOneWayLatency)
        ) + UInt64((1.0 - Self.kEWMAFactor) * Double(estOneWayLatency))
    }
}

// Encode a 64-bit integer as a hexadecimal string
func encodeToHex(_ value: UInt64) -> String {
    let hexString = String(value, radix: 16, uppercase: true)
    let paddingLength = max(16 - hexString.count, 0)
    let paddedHexString = String(repeating: "0", count: paddingLength) + hexString
    return paddedHexString
}

// Decode a hexadecimal string back to a 64-bit integer
func decodeFromHex(_ hexString: String) -> UInt64? {
    return UInt64(hexString, radix: 16)
}

/// `MCPeerID` offers no good way to get an integer ID. `MCPeerID`'s hash value is not stable
/// over time, as `MCPeerID` is a reference type. So instead, the peer ID is generated and stored in
/// the `displayName` of the `MCPeerID`. The `displayName` cannot have some special characters
/// (probably something to do with Bonjour) so a 64-bit integer is encoded to a hexadecimal string.
func generatePeerIDString() -> String {
    return encodeToHex(generateRandom64BitInteger())
}

extension MCPeerID {
    var id: UInt64 {
        get {
            #if DEBUG
            assert(self.displayName.count == 16) // number of characters in a 64-bit hex string
            #endif

            guard let iDNumber = decodeFromHex(self.displayName) else {
                fatalError("\(#function): Cannot decode displayName as base64 peerID")
            }

            return iDNumber
        }
    }
}
