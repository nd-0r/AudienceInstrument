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
    private var peerId: Int
    internal var connectionManager: ConnectionManager?

    struct NodeMessage: Codable {
        let from: Int
        let message: String
    }

    init(peerId: Int, connectionManager: ConnectionManager? = nil) {
        self.peerId = peerId
        self.connectionManager = connectionManager
    }

    // Must be isolated to @MainActor
    func recvMessage(message: String) {
        self.messages.append(message)
    }

    func sendMessage(message: String) {
        guard connectionManager != nil else {
            return
        }

        Task {@MainActor in
            if (try? await connectionManager!.send(
                messageData: NodeMessage(from: peerId, message: message),
                toPeer: peerId,
                with: MCSessionSendDataMode.reliable
            )) != nil {
                self.messages.append(message)
            }
        }
    }
}
