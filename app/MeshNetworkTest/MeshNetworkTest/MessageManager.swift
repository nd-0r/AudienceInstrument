//
//  MesageReceiver.swift
//  MeshNetworkTest
//
//  Created by Andrew Orals on 3/16/24.
//

import Foundation
import MultipeerConnectivity

class NodeMessageManager: ObservableObject {
    @Published internal var messages: [String] = []
    @Published internal var available: Bool = true
    internal let peerId: Int
    internal var connectionManager: ConnectionManager?

    struct NodeMessage: Codable {
        let from: Int
        let to: Int
        let message: String
    }

    init(peerId: Int, connectionManager: ConnectionManager? = nil) {
        self.peerId = peerId
        self.connectionManager = connectionManager
    }

    // Must be isolated to @MainActor and run on the main dispatch queue
    func recvMessage(message: String) {
        self.messages.append(message)
    }

    func sendMessage(message: String) {
        guard connectionManager != nil else {
            return
        }

        DispatchQueue.main.async { [self] in Task {@MainActor in
            if (try? await connectionManager!.send(
                messageData: NodeMessage(from: connectionManager!.selfId.hashValue, to: peerId, message: message),
                toPeer: peerId,
                with: MCSessionSendDataMode.reliable
            )) != nil {
                self.messages.append(message)
            }
        }}
    }
}
