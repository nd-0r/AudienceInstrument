//
//  MesageReceiver.swift
//  AudienceInstrument
//
//  Created by Andrew Orals on 3/16/24.
//

import Foundation
import MultipeerConnectivity

class NodeMessageManager: ObservableObject {
    @Published internal var messages: [String] = []
    @Published internal var available: Bool = true
    internal let peerId: ConnectionManager.PeerId
    internal var connectionManagerModel: ConnectionManagerModel?

    init(peerId: ConnectionManager.PeerId, connectionManagerModel: ConnectionManagerModel? = nil) {
        self.peerId = peerId
        self.connectionManagerModel = connectionManagerModel
    }

    // Must be isolated to @MainActor and run on the main dispatch queue
    func recvMessage(message: String) {
        self.messages.append(message)
    }

    func sendMessage(message: String) {
        guard connectionManagerModel != nil else {
            return
        }

        DispatchQueue.main.async { [self] in Task {@MainActor in
            if (try? await connectionManagerModel!.send(
                toPeer: peerId,
                message: message,
                with: MCSessionSendDataMode.reliable
            )) != nil {
                self.messages.append(message)
            }
        }}
    }
}
