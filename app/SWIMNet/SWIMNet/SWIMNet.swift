//
//  SWIMNet.swift
//  SWIMNet
//
//  Created by Andrew Orals on 2/8/24.
//

import Foundation
import MultipeerConnectivity

/// A wrapper around the underlying peer-to-peer communication implementation
/// Contains a subset of the functions in the MCSession class
protocol MPNPeerCommunicationDelegate {
    // The callbacks for receiving data
    var delegate: (any MCSessionDelegate)? { get set }

    func send(
        _ data: Data,
        toPeers peerIDs: [MCPeerID],
        with mode: MCSessionSendDataMode
    ) throws
 
    func startStream(
        withName streamName: String,
        toPeer peerID: MCPeerID
    ) throws -> OutputStream
}

/// A generic network interface, which allows sending data to and receiving data from
/// another host on the mesh network. The MultipeerNetwork achieves this through
/// implementing distance vector routing on top of the peer-to-peer connections.
struct MultipeerNetwork {
    class MultipeerNetworkMCSessionDelegate: NSObject, MCSessionDelegate  {
        @objc
        func session(
            _ session: MCSession,
            didReceive data: Data,
            fromPeer peerID: MCPeerID
        ) {

        }

        @objc
        func session(
            _ session: MCSession,
            didStartReceivingResourceWithName resourceName: String,
            fromPeer peerID: MCPeerID,
            with progress: Progress
        ) {

        }

        @objc
        func session(
            _ session: MCSession,
            didFinishReceivingResourceWithName resourceName: String,
            fromPeer peerID: MCPeerID,
            at localURL: URL?,
            withError error: (any Error)?
        ) {

        }

        @objc
        func session(
            _ session: MCSession,
            didReceive stream: InputStream,
            withName streamName: String,
            fromPeer peerID: MCPeerID
        ) {

        }

        @objc
        func session(
            _ session: MCSession,
            peer peerID: MCPeerID,
            didChange state: MCSessionState
        ) {

        }
    }

    public var peerCommunicationDelegate: (any MPNPeerCommunicationDelegate)? {
        didSet {
            peerCommunicationDelegate?.delegate = MultipeerNetworkMCSessionDelegate()
        }
    }
//    public var recvCallback: ((UUID, Data) async -> Void)? { // TODO
//        get {}
//        set {}
//    }

    init(thisUUID uuid: UUID){}

    public func send(to host: UUID, data: Data) async throws {

    }

    public func broadcast(data: Data) async throws {
 
    }
}
