//
//  PeerConnectionView.swift
//  MeshNetworkTest
//
//  Created by Andrew Orals on 3/16/24.
//

import SwiftUI
import MultipeerConnectivity

struct PeerConnectionStatusView: View {
    var status: MCSessionState
    var clientName: String
    var didSelectCallback: () -> Void

    var body: some View {
        Button {
            didSelectCallback()
        } label: {
            HStack {
                Text(clientName)
                    .foregroundStyle(.blue)
                Spacer()
            }
            switch status {
            case MCSessionState.connected:
                Circle().foregroundStyle(.green).frame(width: 40, height: 40)
            case MCSessionState.notConnected:
                Circle().foregroundStyle(.red).frame(width: 40, height: 40)
            default:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaledToFit()
            }
        }
        .padding()
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

struct PeerConnectionView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State var connecting = true

    var body: some View {
        ScrollView {
            ForEach(
                Array(connectionManager.sessionPeers.keys),
                id: \.self
            ) { mcPeerId in
                PeerConnectionStatusView(
                    status: connectionManager.sessionPeers[mcPeerId]!,
                    clientName: mcPeerId.displayName,
                    didSelectCallback: { connectionManager.connect(toPeer: mcPeerId) }
                )
            }
        }
        .alert(isPresented: $connecting) {
            Alert(
                title: Text("Searching"),
                message: Text("Searching for peers to connect to"),
                dismissButton: Alert.Button.default(
                    Text("Stop Searching"),
                    action: {
                        connecting = false
                        connectionManager.stopBrowsingAndAdvertising()
                    }
                )
            )
        }
    }
}

struct PeerConnectionView_Previews: PreviewProvider {
    static var previews: some View {
        return PeerConnectionView()
            .environmentObject(createMockConnectionManager())
    }
}

